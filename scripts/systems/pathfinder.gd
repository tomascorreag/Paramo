class_name Pathfinder
extends Node

# ============================================================================
# Pathfinder
# ============================================================================
#
# Scene-level pathfinding service for an isometric tile world. Runs a custom
# A* over the 4-neighbor grid exposed by TileGrid, and exposes cell/world
# coord helpers plus click-to-cell resolution for painted iso layers.
#
# Search state is (cell, incoming_direction) so a small per-turn penalty can
# be applied: among all shortest paths, the one with the fewest direction
# changes wins.
#
# Two additional per-step costs layer on top of the base 1.0 + turn epsilon:
#   - RAMP PENALTY: each half-step of elevation change when stepping onto a
#     ramp (SLOPE_*, STAIR_*, HALF_*) adds _RAMP_PENALTY_PER_STEP. Sub-step
#     so ramps remain traversable — they only lose to flat routes of equal
#     or near-equal length.
#   - OBJECT PENALTY: a per-cell float registry (_cell_penalties) that
#     placers write into via set_cell_penalty/clear_cell_penalty. Unbounded:
#     a small value nudges, a value above ~1.0 forces detours. Pathfinder
#     stays agnostic of what the penalty represents (plant, boulder, sign).
#
# Setup in the editor:
#   1. Add a Pathfinder node as a child of the scene root.
#   2. Drag every walkable-relevant TileMapLayer into `tile_map_layers`.
#      Paint order matters for click resolution: later entries are "on top"
#      (checked first by resolve_click).
#   3. Call `rebuild()` if you change tile data after scene ready.
#
# The Pathfinder joins group "pathfinder" on _enter_tree() so other nodes (the
# player, threats, UI) can locate it without exported refs:
#
#     var pf := get_tree().get_first_node_in_group("pathfinder") as Pathfinder
#
# This class has NO dependency on the concept of "a player." Any agent can
# query it. Input handling lives in ClickToMoveController, not here.
#
# ============================================================================


const GROUP_NAME: StringName = &"pathfinder"

# Half-step pixel height. One half-step = 8 px, two half-steps = 16 px = one
# FULL_CUBE.
const HALF_STEP_PX: float = 8.0

# Tiebreaker weight applied once per direction change along a path. Must be
# small enough that the total turn penalty on any realistic path is strictly
# less than 1 (the cost of a single step), so step-count stays the primary
# sort key. With 1e-4 we're safe up to 10000-step paths — far beyond any map
# this game will ever use.
const _TURN_EPSILON: float = 1e-4

# Extra cost charged per half-step of elevation change when stepping onto a
# ramp cell. Full stairs/slopes (ramp_size 2) cost 2x this; half variants
# (ramp_size 1) cost 1x. Kept sub-step so ramps never force a detour when
# they're strictly on the shortest route — only tie-breaking flat-vs-ramp
# cases flip.
const _RAMP_PENALTY_PER_STEP: float = 0.15

# Constant pixel offset from a cell's `map_to_local()` origin to the visual
# center of its walkable top surface at altitude 0. This compensates for the
# difference between where Godot considers a tile's "origin" and where the
# painted art actually shows the walkable ground. Calibrated empirically in
# Phase 2 after running the test scene with the debug overlay.
const VISUAL_SURFACE_OFFSET: Vector2 = Vector2(0, 0)

# Return value for resolve_click when nothing walkable is under the cursor.
const NO_CELL: Vector2i = Vector2i(0x7FFFFFFF, 0x7FFFFFFF)


@export var tile_map_layers: Array[TileMapLayer] = []
@export var debug_logging: bool = false


const _NEIGHBOR_DIRS: Array[Vector2i] = [
	Vector2i( 1,  0),
	Vector2i(-1,  0),
	Vector2i( 0,  1),
	Vector2i( 0, -1),
]

var _grid: TileGrid

# Per-cell additional enter cost contributed by objects (plants, structures).
# Cleared only via clear_cell_penalty — rebuild() intentionally leaves it
# intact because the objects that registered entries still exist in the world.
var _cell_penalties: Dictionary[Vector2i, float] = {}

# Traversal edges registered by Ladder (and future traversals) that bypass the
# shape-based altitude check in TileGrid.can_transition. Stored here (not on
# the grid) only so rebuild() can re-apply them to the freshly-built TileGrid.
# Runtime lookups delegate to TileGrid.has_traversal_edge (dict-of-dicts, O(1)).
# Keyed by a normalized (low, high) pair StringName so add/remove/has are
# order-independent.
var _traversal_edges: Dictionary[StringName, Array] = {}


func _enter_tree() -> void:
	# Join the group in _enter_tree (runs top-down before sibling _readys) so
	# any sibling that looks us up by group during _ready succeeds regardless
	# of sibling order in the scene. The graph itself is still built in
	# _ready — callers that need it must defer their first query.
	add_to_group(GROUP_NAME)


func _ready() -> void:
	rebuild()


# ----------------------------------------------------------------------------
# Build / rebuild
# ----------------------------------------------------------------------------

func rebuild() -> void:
	if tile_map_layers.is_empty():
		push_error("Pathfinder: tile_map_layers is empty; wire layers in the inspector.")
		return

	_grid = TileGrid.new()
	_grid.build(tile_map_layers)

	# Re-apply traversal edges that survived the rebuild (ladders, etc.).
	for pair in _traversal_edges.values():
		_grid.add_traversal_edge(pair[0], pair[1])

	if debug_logging:
		var walk_count := _grid.walkable_cells().size()
		print("Pathfinder: built grid with %d walkable cells." % walk_count)


# ----------------------------------------------------------------------------
# Public queries
# ----------------------------------------------------------------------------

# Custom A* over the 4-neighbor grid. State is (cell, incoming_direction): by
# embedding the incoming direction in the search state we can charge a tiny
# penalty whenever a step changes direction from the previous one, producing
# straightest-possible paths among all shortest paths. The penalty is strictly
# less than 1 per turn, so step count remains the primary cost.
func find_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	if _grid == null:
		return []
	if not _grid.is_walkable(from) or not _grid.is_walkable(to):
		return []
	if from == to:
		var same: Array[Vector2i] = [from]
		return same

	# State key encoding: Vector3i(cell.x, cell.y, dir + 1). dir = -1 for the
	# start (encoded as 0), neighbors encode 1..4. Vector3i is natively hashable
	# and avoids the per-expansion String allocation the old encoding paid for.
	var start_key := Vector3i(from.x, from.y, 0)
	var g_score: Dictionary[Vector3i, float] = { start_key: 0.0 }
	var came_from: Dictionary[Vector3i, Array] = {}  # key -> [prev_key, cell]

	# Open set entries: [f, tiebreak_counter, cell, dir, key]. Lower f first;
	# ties broken by insertion order so we behave deterministically. A linear
	# min-scan is fine at this map scale (hundreds of tiles).
	var open: Array = [[_heuristic(from, to), 0, from, -1, start_key]]
	var counter: int = 0

	while not open.is_empty():
		var best_idx: int = 0
		for i in range(1, open.size()):
			if open[i][0] < open[best_idx][0]:
				best_idx = i
		var cur: Array = open[best_idx]
		open.remove_at(best_idx)

		var cur_cell: Vector2i = cur[2]
		var cur_dir: int = cur[3]
		var cur_key: Vector3i = cur[4]

		if cur_cell == to:
			return _reconstruct_path(came_from, cur_key, from)

		var cur_g: float = g_score[cur_key]

		for dir_idx in _NEIGHBOR_DIRS.size():
			var d: Vector2i = _NEIGHBOR_DIRS[dir_idx]
			var nb: Vector2i = cur_cell + d
			if not _grid.is_walkable(nb):
				continue
			if not _grid.can_transition(cur_cell, nb):
				continue

			var turn_cost: float = 0.0 if cur_dir == -1 or cur_dir == dir_idx else _TURN_EPSILON
			# Ladder steps (traversal edges) cost one unit per half-step of
			# altitude climbed, so one full cube (2 half-steps) costs the same
			# as 2 horizontal tile steps. Normal steps stay at the flat 1.0.
			var step_cost: float = 1.0
			if _grid.has_traversal_edge(cur_cell, nb):
				var alt_delta: float = absf(
					_grid.altitude_center(nb) - _grid.altitude_center(cur_cell)
				)
				if alt_delta > step_cost:
					step_cost = alt_delta
			var tentative_g: float = cur_g + step_cost + turn_cost + _cell_enter_cost(nb)
			var nb_key := Vector3i(nb.x, nb.y, dir_idx + 1)
			if g_score.has(nb_key) and tentative_g >= g_score[nb_key]:
				continue
			g_score[nb_key] = tentative_g
			came_from[nb_key] = [cur_key, nb]
			counter += 1
			var f: float = tentative_g + _heuristic(nb, to)
			open.append([f, counter, nb, dir_idx, nb_key])

	return []


func is_walkable(cell: Vector2i) -> bool:
	if _grid == null:
		return false
	return _grid.is_walkable(cell)


func altitude_center(cell: Vector2i) -> float:
	if _grid == null:
		return 0.0
	return _grid.altitude_center(cell)


func get_tile(cell: Vector2i) -> CellData:
	if _grid == null:
		return null
	return _grid.get_tile(cell)


func roughness_at(cell: Vector2i) -> float:
	if _grid == null:
		return 0.0
	return _grid.roughness_at(cell)


# Vector4 mask of which of the 4 iso-diamond neighbors of `cell` share the
# same walkable altitude as `cell` itself: (SE, NW, SW, NE) → (x, y, z, w),
# 1.0 for match, 0.0 otherwise. Empty / non-walkable neighbors return 0.0.
# Used by the shadow shader to discard shadow pixels that would land on
# ground at a different altitude than the one the entity stands on.
func neighbor_altitude_match(cell: Vector2i) -> Vector4:
	if _grid == null:
		return Vector4.ZERO
	var self_tile := _grid.get_tile(cell)
	if self_tile == null:
		return Vector4.ZERO
	var self_alt: float = self_tile.altitude_center
	return Vector4(
		_alt_match(cell + Vector2i(1, 0), self_alt),   # SE
		_alt_match(cell + Vector2i(-1, 0), self_alt),  # NW
		_alt_match(cell + Vector2i(0, 1), self_alt),   # SW
		_alt_match(cell + Vector2i(0, -1), self_alt),  # NE
	)


func _alt_match(c: Vector2i, self_alt: float) -> float:
	var tile := _grid.get_tile(c)
	if tile == null:
		return 0.0
	# Walls / EDGE_* / non-walkable cells have no ground surface to cast a
	# shadow on, even if their blocking altitude happens to match.
	if not tile.walkable:
		return 0.0
	# Match when the entity's altitude intersects the neighbor's altitude
	# RANGE. For flats low == high so this reduces to equality; for ramps
	# adjacency to either end (low OR high) is enough to keep the shadow
	# visible on the ramp. A tiny epsilon absorbs float round-off.
	if self_alt >= float(tile.altitude_low) - 0.01 and self_alt <= float(tile.altitude_high) + 0.01:
		return 1.0
	return 0.0


# Registers an additional enter-cost on a cell. Passing 0.0 clears the entry.
# Penalty is added to the base step cost every time a search considers moving
# INTO `cell`, so a large value (>1.0) forces detours, a small value nudges.
func set_cell_penalty(cell: Vector2i, penalty: float) -> void:
	if penalty == 0.0:
		_cell_penalties.erase(cell)
		return
	_cell_penalties[cell] = penalty


func clear_cell_penalty(cell: Vector2i) -> void:
	_cell_penalties.erase(cell)


func get_cell_penalty(cell: Vector2i) -> float:
	return _cell_penalties.get(cell, 0.0)


## Drop every registered cell penalty. Callers: scene teardown, world reload,
## or test setup. Not called by rebuild() — penalties track live world objects
## that outlive the grid, so rebuild intentionally preserves them.
func clear_all_cell_penalties() -> void:
	_cell_penalties.clear()


# Register a bidirectional traversal edge between two 4-connected cells that
# bypasses shape-based altitude checks. Ladders use this to let the player
# step between a floor at altitude A and a floor at altitude A+2k on the
# adjacent cell. Survives Pathfinder.rebuild(). The edge is live on the
# current grid immediately — no manual rebuild needed.
func add_traversal_edge(a: Vector2i, b: Vector2i) -> void:
	var key := _traversal_key(a, b)
	if _traversal_edges.has(key):
		return
	_traversal_edges[key] = [a, b]
	if _grid != null:
		_grid.add_traversal_edge(a, b)


## True iff a bidirectional traversal edge exists between `a` and `b`. Used by
## movers (Player) to detect ladder steps and adjust per-step timing. Delegates
## to TileGrid when a grid is built (O(1) dict lookup); falls back to the
## Pathfinder registry between rebuilds.
func has_traversal_edge(a: Vector2i, b: Vector2i) -> bool:
	if _grid != null:
		return _grid.has_traversal_edge(a, b)
	return _traversal_edges.has(_traversal_key(a, b))


func remove_traversal_edge(a: Vector2i, b: Vector2i) -> void:
	_traversal_edges.erase(_traversal_key(a, b))
	if _grid != null:
		_grid.remove_traversal_edge(a, b)


# Canonicalize a 2-cell pair to an order-independent StringName key so
# add/remove/has behave the same regardless of argument order.
static func _traversal_key(a: Vector2i, b: Vector2i) -> StringName:
	var lo: Vector2i = a
	var hi: Vector2i = b
	if b.y < a.y or (b.y == a.y and b.x < a.x):
		lo = b; hi = a
	return StringName("%d,%d|%d,%d" % [lo.x, lo.y, hi.x, hi.y])


func grid() -> TileGrid:
	return _grid


# Resolves a global-space click position to the walkable cell visible under
# that pixel. Altitude-aware: tile art at altitude A is drawn A*HALF_STEP_PX
# pixels above the grid plane. The visual lift may come from:
#   (a) the layer's position offset (handled by to_local automatically), or
#   (b) tile art shifts (texture_origin), which to_local does NOT handle.
# We compute a net shift = total altitude lift minus what the layer's position
# already accounts for. This works regardless of how the designer chose to
# visually elevate the layer.
#
# Iterates layer altitudes descending (highest first) so that a plateau
# visually covering a ground cell beneath it wins the click.
#
# Returns NO_CELL if nothing walkable is under the cursor.
func resolve_click(global_pos: Vector2) -> Vector2i:
	if _grid == null:
		return NO_CELL

	for alt in _grid.altitudes_desc():
		for i in range(tile_map_layers.size() - 1, -1, -1):
			var layer: TileMapLayer = tile_map_layers[i]
			if layer == null:
				continue
			if _grid.layer_altitude(layer) != alt:
				continue
			var local := layer.to_local(global_pos)
			# Each layer is expected to be visually lifted to match its altitude
			# via layer.position.y = -alt * HALF_STEP_PX. When that holds,
			# net_shift resolves to 0 and clicks land on the correct cell. If a
			# layer instead bakes altitude into tile texture_origin with
			# position.y = 0, net_shift = alt * HALF_STEP_PX still compensates.
			# Independent of any "reference" layer, so it works regardless of
			# which altitudes exist or what order layers are wired in.
			var net_shift := float(alt) * HALF_STEP_PX + layer.position.y
			var shifted := local + Vector2(0.0, net_shift) - VISUAL_SURFACE_OFFSET
			var cell := layer.local_to_map(shifted)
			if not _grid.is_walkable(cell):
				continue
			if _grid.layer_of(cell) != layer:
				continue
			return cell
	return NO_CELL


# Projects a global-space point onto the iso plane at altitude `alt` and
# returns the cell whose visual footprint contains that point on that plane.
# Walkability-agnostic. Returns NO_CELL if no layers are configured.
#
# Primitive used by the UX overlay to iterate altitudes when classifying which
# face (top / SW / SE) of a cube the cursor is over.
func project_to_altitude(global_pos: Vector2, alt: int) -> Vector2i:
	if tile_map_layers.is_empty():
		return NO_CELL
	var ref: TileMapLayer = null
	for L in tile_map_layers:
		if L != null:
			ref = L
			break
	if ref == null:
		return NO_CELL
	var local := ref.to_local(global_pos)
	var net_shift := float(alt) * HALF_STEP_PX + ref.position.y
	var shifted := local + Vector2(0.0, net_shift) - VISUAL_SURFACE_OFFSET
	return ref.local_to_map(shifted)


# World space (global) <-> cell conversion. Uses the first layer as the
# reference grid. Altitude is always applied separately by the caller — this
# function returns the altitude-0 world position of the cell origin, BEFORE
# VISUAL_SURFACE_OFFSET is added.
#
# The ref layer's own visual altitude lift (layer.position.y = -alt * HALF_STEP_PX)
# is stripped out so the result stays in the altitude-0 frame regardless of
# which layer happens to be the reference.
func cell_to_world(cell: Vector2i) -> Vector2:
	var ref := _reference_layer()
	if ref == null:
		return Vector2.ZERO
	var p := ref.to_global(ref.map_to_local(cell))
	p.y -= ref.position.y
	return p


func world_to_cell(global_pos: Vector2) -> Vector2i:
	var ref := _reference_layer()
	if ref == null:
		return NO_CELL
	# Inverse of cell_to_world: the input is in the altitude-0 frame, so add
	# back the ref layer's lift before converting to its local cell grid.
	var adjusted := Vector2(global_pos.x, global_pos.y + ref.position.y)
	return ref.local_to_map(ref.to_local(adjusted))


# ----------------------------------------------------------------------------
# Internal helpers
# ----------------------------------------------------------------------------

func _cell_enter_cost(cell: Vector2i) -> float:
	var elevation_cost: float = float(_grid.ramp_size(cell)) * _RAMP_PENALTY_PER_STEP
	return elevation_cost + _cell_penalties.get(cell, 0.0)


static func _heuristic(a: Vector2i, b: Vector2i) -> float:
	return float(absi(a.x - b.x) + absi(a.y - b.y))


func _reconstruct_path(came_from: Dictionary, end_key: Vector3i, start: Vector2i) -> Array[Vector2i]:
	# came_from[key] = [prev_key, cell_of_key]. Walk back from the goal's key,
	# collecting destination cells; the start has no came_from entry and is
	# appended at the end.
	var reversed: Array[Vector2i] = []
	var k: Vector3i = end_key
	while came_from.has(k):
		var entry: Array = came_from[k]
		reversed.append(entry[1])
		k = entry[0]
	reversed.append(start)
	reversed.reverse()
	return reversed


func _reference_layer() -> TileMapLayer:
	# First configured layer is the reference grid. With the new architecture
	# layers are paint slots with no logical altitude meaning, so any layer
	# would do — we pick the first for determinism.
	for layer in tile_map_layers:
		if layer != null:
			return layer
	return null
