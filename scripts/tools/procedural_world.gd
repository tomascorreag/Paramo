@tool
class_name ProceduralWorld
extends Node

# ============================================================================
# ProceduralWorld
# ============================================================================
#
# Editor-iterable orchestrator that runs TerrainGenerator + TerrainPainter
# against the layer stack of an inherited gameplay scene. Live in the scene
# tree alongside the World node; click the "Regenerate" button in the
# inspector to re-bake the map without leaving the editor.
#
# At runtime, generates in `_ready()` if `auto_generate_on_ready` is set.
#
# ============================================================================


@export_group("Generation")
## Resource preset driving the generator. Edit the .tres in the inspector
## to tune values, swap `.tres` files to change biome / map style. If null
## at runtime, defaults are used (see TerrainGenerationParams).
@export var generation_params: TerrainGenerationParams
## Per-instance overrides for the most commonly-tweaked fields. Set to a
## non-default value to override the resource without forking it. The
## sentinel for "use the resource value as-is" is shown in the comments.
##
## seed_override = -1  → use generation_params.seed
@export var seed_override: int = -1

@export_group("Wiring")
## Ground TileMapLayers indexed by altitude. Drag the layers in low-to-high.
## Their `metadata/altitude` is used to bind cells to the correct layer.
@export var ground_layers: Array[TileMapLayer] = []
## Optional Pathfinder to rebuild after painting. Wire it on the procedural
## scene template; gameplay relies on it for click-to-move.
@export var pathfinder: Pathfinder
## Optional Player to reposition onto a walkable cell after generation.
## Without this, the player's authored position can land on a non-walkable
## or empty cell since terrain shape is random per seed.
@export var player: Node2D

@export_group("Runtime")
## When true, generates the map automatically on `_ready()` at game start.
@export var auto_generate_on_ready: bool = true
## Print a one-line "generated WxH, seed=N" summary on each regenerate.
## Default off; flip on when iterating on the generator.
@export var verbose_logs: bool = false

@export_tool_button("Regenerate") var regenerate_action := regenerate
@export_tool_button("Clear") var clear_action := clear


# ----------------------------------------------------------------------------
# Lifecycle
# ----------------------------------------------------------------------------

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if auto_generate_on_ready:
		regenerate()


# ----------------------------------------------------------------------------
# Public actions (wired to @export_tool_button)
# ----------------------------------------------------------------------------

func regenerate() -> void:
	if ground_layers.is_empty():
		push_error("ProceduralWorld: no ground_layers wired.")
		return
	var tile_set: TileSet = ground_layers[0].tile_set
	if tile_set == null:
		push_error("ProceduralWorld: ground_layers[0] has no TileSet.")
		return

	var params: TerrainGenerationParams = _resolve_params()

	# Validate layer ceiling: cells generated above the tallest layer's
	# altitude have no place to be painted and silently disappear (the
	# painter logs a per-cell warning, but by then the map is already
	# half-rendered). Surface this up-front so the author sees a single
	# clear message instead of N painter warnings.
	var layers_by_altitude: Dictionary = _build_layer_map()
	var max_layer_alt: int = -1
	for alt in layers_by_altitude.keys():
		if int(alt) > max_layer_alt:
			max_layer_alt = int(alt)
	if max_layer_alt >= 0 and params.top_altitude > max_layer_alt:
		push_warning(
			"ProceduralWorld: top_altitude=%d exceeds tallest TileMapLayer altitude=%d. "
			% [params.top_altitude, max_layer_alt]
			+ "Cells above %d will not be painted. " % max_layer_alt
			+ "Add Ground layers up to altitude %d, or lower top_altitude to %d."
			% [params.top_altitude, max_layer_alt]
		)

	var grid: TerrainGrid = TerrainGenerator.generate(params)
	TerrainPainter.paint(grid, layers_by_altitude, tile_set, params)

	# Pathfinder is not an @tool script — calling its methods from the editor
	# (e.g. via the Regenerate button) errors out with "Attempt to call a
	# method on a placeholder instance". Skip rebuild during editor edits;
	# at runtime _ready() runs in non-editor mode and pathfinder is real.
	if pathfinder != null and not Engine.is_editor_hint():
		pathfinder.rebuild()

	_place_player_on_walkable(grid)

	if verbose_logs:
		print(
			"ProceduralWorld: generated %dx%d, top altitude %d, seed %d."
			% [params.width, params.height, params.top_altitude, params.seed]
		)


# Builds the effective TerrainGenerationParams for this regenerate call.
# Resource is deep-duplicated (subresources=true) before override application
# so we never mutate the shared `.tres` — including the inner
# `Array[TerrainBiomeBand]`, whose elements are sub-resources. A shallow
# duplicate would leave the bands shared with the .tres and any future code
# that mutates a band (e.g. weight tweak per pass) would silently mutate the
# saved asset. If no resource is assigned, falls back to default values
# (defined on TerrainGenerationParams) and warns.
func _resolve_params() -> TerrainGenerationParams:
	var p: TerrainGenerationParams
	if generation_params != null:
		p = generation_params.duplicate(true) as TerrainGenerationParams
	else:
		push_warning(
			"ProceduralWorld: no generation_params assigned — using defaults. "
			+ "Assign a .tres under res://resources/terrain/ to tune."
		)
		p = TerrainGenerationParams.new()
	if seed_override >= 0:
		p.seed = seed_override
	p.top_altitude = _ensure_even(p.top_altitude)
	return p


func clear() -> void:
	for l in ground_layers:
		if l != null:
			l.clear()


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

func _build_layer_map() -> Dictionary:
	var out: Dictionary = {}
	for l in ground_layers:
		if l == null:
			continue
		if not l.has_meta("altitude"):
			push_warning(
				"ProceduralWorld: layer '%s' has no metadata/altitude — skipping in layer map."
				% l.name
			)
			continue
		var alt: int = int(l.get_meta("altitude"))
		out[alt] = l
	return out


func _ensure_even(v: int) -> int:
	return v if v % 2 == 0 else v - 1


# Finds a walkable cell — preferring low-altitude FLAT/FULL_CUBE GROUND tiles
# near the map centroid — and snaps the player onto it. Reads the abstract
# grid directly so it works in both editor and runtime (Pathfinder is not
# @tool and its methods are placeholders during editor edits).
func _place_player_on_walkable(grid: TerrainGrid) -> void:
	if player == null:
		return
	var cell: Vector2i = _find_starting_cell(grid)
	if cell.x < 0:
		push_warning("ProceduralWorld: no walkable cell found; leaving player at authored position.")
		return
	var world_pos: Vector2 = _cell_to_world(cell)
	# At runtime, Player._snap_to_starting_cell re-applies the altitude lift
	# on top of this position, so we just set the ground-level world position
	# here and the lift is handled per-frame by the Player script.
	player.global_position = world_pos


# Scans the abstract grid for GROUND cells with FLAT/FULL_CUBE shape AND at
# least one walkable face neighbor (so the player isn't stranded on an
# isolated 1x1 island), picks the one with the lowest altitude (ties broken
# by distance to map center). Slopes are excluded as a starting pose because
# the player anchor looks odd half-way up a tapered tile.
func _find_starting_cell(grid: TerrainGrid) -> Vector2i:
	var center := Vector2(grid.width * 0.5, grid.height * 0.5)
	var best := Vector2i(-1, -1)
	var best_alt: int = 0x7FFFFFFF
	var best_dist_sq: float = INF
	# Fallback: best cell ignoring the neighbor-walkability requirement, in
	# case generation produces a degenerate seed where every flat cell is
	# isolated. Prefer a real spawn over a warning, but still warn.
	var fallback := Vector2i(-1, -1)
	var fallback_alt: int = 0x7FFFFFFF
	var fallback_dist_sq: float = INF
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.GROUND:
				continue
			if c.ground_shape != TerrainCell.GroundShape.FULL_CUBE \
					and c.ground_shape != TerrainCell.GroundShape.FLAT:
				continue
			var cell := Vector2i(x, y)
			var d := Vector2(x, y) - center
			var dist_sq: float = d.x * d.x + d.y * d.y
			if c.altitude < fallback_alt \
					or (c.altitude == fallback_alt and dist_sq < fallback_dist_sq):
				fallback = cell
				fallback_alt = c.altitude
				fallback_dist_sq = dist_sq
			if not _has_walkable_neighbor(grid, cell, c.altitude):
				continue
			if c.altitude < best_alt \
					or (c.altitude == best_alt and dist_sq < best_dist_sq):
				best = cell
				best_alt = c.altitude
				best_dist_sq = dist_sq
	if best.x < 0 and fallback.x >= 0:
		push_warning(
			"ProceduralWorld: no walkable cell with a walkable neighbor; "
			+ "falling back to isolated cell %s (player may be stuck)." % fallback
		)
		return fallback
	return best


# A face neighbor is "walkable" if it's GROUND at the same altitude and
# either flat or full-cube (so the player can step laterally), or if it's
# a slope connecting this cell to its high end (alt+2). This is a coarse
# proxy for the Pathfinder's walkability rules — sufficient to reject
# truly isolated 1x1 islands, but doesn't substitute for a runtime path
# check from the player anchor.
func _has_walkable_neighbor(grid: TerrainGrid, cell: Vector2i, alt: int) -> bool:
	var dirs: Array[Vector2i] = [
		TerrainCell.DIR_NE,
		TerrainCell.DIR_NW,
		TerrainCell.DIR_SE,
		TerrainCell.DIR_SW,
	]
	for d in dirs:
		var n: Vector2i = cell + d
		var nc: TerrainCell = grid.at_or_null(n.x, n.y)
		if nc == null or nc.kind != TerrainCell.Kind.GROUND:
			continue
		# Same-altitude flat / full cube → walk laterally.
		if nc.altitude == alt and (
				nc.ground_shape == TerrainCell.GroundShape.FULL_CUBE
				or nc.ground_shape == TerrainCell.GroundShape.FLAT):
			return true
		# Slope on the same tier rising AWAY from us (so the slope's low
		# end touches us) is walkable up. Slope altitude = LOW end.
		if nc.altitude == alt and _slope_rises_in(nc.ground_shape, -d):
			return true
		# Slope at one tier below rising TOWARD us (so its high end sits at
		# our altitude) is walkable down.
		if nc.altitude == alt - 2 and _slope_rises_in(nc.ground_shape, d):
			return true
	return false


# True iff the slope's rise direction matches `dir`. Returns false for
# non-slope shapes.
func _slope_rises_in(shape: int, dir: Vector2i) -> bool:
	match shape:
		TerrainCell.GroundShape.SLOPE_NE: return dir == TerrainCell.DIR_NE
		TerrainCell.GroundShape.SLOPE_NW: return dir == TerrainCell.DIR_NW
		TerrainCell.GroundShape.SLOPE_SE: return dir == TerrainCell.DIR_SE
		TerrainCell.GroundShape.SLOPE_SW: return dir == TerrainCell.DIR_SW
	return false


# Editor-safe cell→world conversion. Mirrors Pathfinder.cell_to_world: uses
# the first wired ground layer's `map_to_local` and strips its altitude lift
# so the result is in the altitude-0 frame. Avoids calling Pathfinder
# (placeholder in editor; not @tool).
func _cell_to_world(cell: Vector2i) -> Vector2:
	for layer in ground_layers:
		if layer == null:
			continue
		var p: Vector2 = layer.to_global(layer.map_to_local(cell))
		p.y -= layer.position.y
		return p
	return Vector2.ZERO
