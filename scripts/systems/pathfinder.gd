class_name Pathfinder
extends Node

# ============================================================================
# Pathfinder
# ============================================================================
#
# Scene-level pathfinding service for an isometric tile world. Wraps an
# AStar2D graph built from a TileGrid, and exposes cell/world coord helpers
# plus click-to-cell resolution for painted iso layers.
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

# AStar2D point-id encoding. Maps Vector2i cell to positive int:
#   id = (x + BIAS) * STRIDE + (y + BIAS)
# Safe for maps within +/- BIAS cells of origin.
const _ID_BIAS: int = 10000
const _ID_STRIDE: int = 100000

# Half-step pixel height. One half-step = 8 px, two half-steps = 16 px = one
# FULL_CUBE.
const HALF_STEP_PX: float = 8.0

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
var _astar: AStar2D


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

	_astar = AStar2D.new()
	_build_graph()

	if debug_logging:
		var walk_count := _grid.walkable_cells().size()
		print("Pathfinder: built graph with %d walkable cells." % walk_count)


func _build_graph() -> void:
	var walkable := _grid.walkable_cells()

	# First pass: add every walkable cell as a point. Position is the 2D cell
	# coord — used only for A*'s default heuristic.
	for cell in walkable:
		var id := _cell_to_id(cell)
		_astar.add_point(id, Vector2(cell.x, cell.y))

	# Second pass: connect neighbors along the 4 grid axes when the grid
	# allows the transition.
	for cell in walkable:
		var id := _cell_to_id(cell)
		for d in _NEIGHBOR_DIRS:
			var nb := cell + d
			if not _grid.is_walkable(nb):
				continue
			var nb_id := _cell_to_id(nb)
			if _astar.are_points_connected(id, nb_id):
				continue
			if _grid.can_transition(cell, nb):
				# Bidirectional only if the reverse is also valid. Ramps are
				# normally symmetric (walk up or down a stair), but checking
				# explicitly lets us support future one-way tiles cleanly.
				var reverse_ok := _grid.can_transition(nb, cell)
				_astar.connect_points(id, nb_id, reverse_ok)


# ----------------------------------------------------------------------------
# Public queries
# ----------------------------------------------------------------------------

func find_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	if _astar == null:
		return []
	if not _grid.is_walkable(from) or not _grid.is_walkable(to):
		return []
	var from_id := _cell_to_id(from)
	var to_id := _cell_to_id(to)
	if not _astar.has_point(from_id) or not _astar.has_point(to_id):
		return []

	var id_path := _astar.get_id_path(from_id, to_id)
	var result: Array[Vector2i] = []
	for pid in id_path:
		result.append(_id_to_cell(pid))
	return result


func is_walkable(cell: Vector2i) -> bool:
	if _grid == null:
		return false
	return _grid.is_walkable(cell)


func altitude_center(cell: Vector2i) -> float:
	if _grid == null:
		return 0.0
	return _grid.altitude_center(cell)


func cell_info(cell: Vector2i) -> Dictionary:
	if _grid == null:
		return {}
	return _grid.cell_info(cell)


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

	var ref := _reference_layer()
	if ref == null:
		return NO_CELL

	for alt in _grid.altitudes_desc():
		for i in range(tile_map_layers.size() - 1, -1, -1):
			var layer: TileMapLayer = tile_map_layers[i]
			if layer == null:
				continue
			if _grid.layer_altitude(layer) != alt:
				continue
			var local := layer.to_local(global_pos)
			# How much of the altitude lift is already baked into the
			# layer's position (undone by to_local)?
			var layer_y_offset := ref.global_position.y - layer.global_position.y
			var net_shift := float(alt) * HALF_STEP_PX - layer_y_offset
			var shifted := local + Vector2(0.0, net_shift) - VISUAL_SURFACE_OFFSET
			var cell := layer.local_to_map(shifted)
			if not _grid.is_walkable(cell):
				continue
			if _grid.layer_of(cell) != layer:
				continue
			return cell
	return NO_CELL


# World space (global) <-> cell conversion. Uses the first layer as the
# reference grid. Altitude is always applied separately by the caller — this
# function returns the altitude-0 world position of the cell origin, BEFORE
# VISUAL_SURFACE_OFFSET is added.
func cell_to_world(cell: Vector2i) -> Vector2:
	var ref := _reference_layer()
	if ref == null:
		return Vector2.ZERO
	return ref.to_global(ref.map_to_local(cell))


func world_to_cell(global_pos: Vector2) -> Vector2i:
	var ref := _reference_layer()
	if ref == null:
		return NO_CELL
	return ref.local_to_map(ref.to_local(global_pos))


# ----------------------------------------------------------------------------
# Internal helpers
# ----------------------------------------------------------------------------

static func _cell_to_id(cell: Vector2i) -> int:
	return (cell.x + _ID_BIAS) * _ID_STRIDE + (cell.y + _ID_BIAS)


static func _id_to_cell(id: int) -> Vector2i:
	var y := (id % _ID_STRIDE) - _ID_BIAS
	var x := (id / _ID_STRIDE) - _ID_BIAS
	return Vector2i(x, y)


func _reference_layer() -> TileMapLayer:
	# First configured layer is the reference grid. With the new architecture
	# layers are paint slots with no logical altitude meaning, so any layer
	# would do — we pick the first for determinism.
	for layer in tile_map_layers:
		if layer != null:
			return layer
	return null
