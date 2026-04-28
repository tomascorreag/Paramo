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
@export var seed: int = 12345
@export_range(8, 200, 1) var width: int = 32
@export_range(8, 200, 1) var height: int = 48
@export_range(2, 32, 2) var top_altitude: int = 16
## Per-seed apex jitter as a fraction of max(width, height). The apex base is
## the visual N corner of the iso diamond; jitter slides along the NE / NW
## edges (visually horizontal at the top of the screen). 0 = locked to the
## corner; ~0.15 = visible per-seed variety. Always clamped to keep the lake
## disc fully on-grid.
@export_range(0.0, 0.5, 0.01) var apex_x_jitter_frac: float = 0.15
## Multiplier on the auto-fit cone slope. Auto-fit makes the cone reach
## altitude 0 at the far diagonal corner; >1 bottoms out earlier (wider flat
## skirt around the mountain); <1 keeps the entire map elevated.
@export_range(0.3, 2.0, 0.05) var cone_steepness: float = 1.0
## Additive weight given to a south-going river step (positive Y) when the
## walker has multiple downhill candidates. 0 = uniform random, higher = the
## river hugs the south direction more aggressively.
@export_range(0.0, 4.0, 0.05) var south_bias: float = 0.5
@export_range(0.0, 1.0, 0.05) var branch_chance: float = 0.25
@export_range(0.0, 1.0, 0.05) var slope_chance: float = 0.35

@export_group("Noise")
@export_range(0.005, 0.2, 0.005) var height_noise_frequency: float = 0.04
@export_range(0.0, 8.0, 0.1) var height_noise_amplitude: float = 3.0
@export_range(0.005, 0.2, 0.005) var biome_noise_frequency: float = 0.06
@export_range(0.0, 6.0, 0.1) var biome_noise_amplitude: float = 2.0

@export_group("Lake")
@export_range(0.5, 12.0, 0.1) var lake_radius: float = 2.6
## Strength of the noise that perturbs the lake's circular shape. 0 = perfect
## disc (still aspect-stretched per seed); higher = more irregular shoreline.
@export_range(0.0, 2.0, 0.05) var lake_jitter_strength: float = 0.5
## Per-seed random aspect-ratio range. Each generation picks aspect_x and
## aspect_y uniformly from [min, max], so the lake is round when both ~1,
## oblong when they diverge. Different seeds → different orientations.
@export_range(0.3, 1.0, 0.05) var lake_aspect_min: float = 0.7
@export_range(1.0, 2.5, 0.05) var lake_aspect_max: float = 1.4

@export_group("River")
## Cell width of the stream leaving the lake. May shrink at branch points
## (each side independently rolls keep / shrink-by-1, min 1).
@export_range(1, 6, 1) var initial_river_width: int = 2

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

	var params := TerrainGenerator.Params.new()
	params.seed = seed
	params.width = width
	params.height = height
	params.top_altitude = _ensure_even(top_altitude)
	params.apex_x_jitter_frac = apex_x_jitter_frac
	params.cone_steepness = cone_steepness
	params.south_bias = south_bias
	params.height_noise_frequency = height_noise_frequency
	params.height_noise_amplitude = height_noise_amplitude
	params.biome_noise_frequency = biome_noise_frequency
	params.biome_noise_amplitude = biome_noise_amplitude
	params.lake_radius = lake_radius
	params.lake_jitter_strength = lake_jitter_strength
	params.lake_aspect_min = lake_aspect_min
	params.lake_aspect_max = lake_aspect_max
	params.initial_river_width = initial_river_width
	params.branch_chance = branch_chance
	params.slope_chance = slope_chance

	var grid: TerrainGrid = TerrainGenerator.generate(params)
	var layers_by_altitude: Dictionary = _build_layer_map()
	TerrainPainter.paint(grid, layers_by_altitude, tile_set)

	# Pathfinder is not an @tool script — calling its methods from the editor
	# (e.g. via the Regenerate button) errors out with "Attempt to call a
	# method on a placeholder instance". Skip rebuild during editor edits;
	# at runtime _ready() runs in non-editor mode and pathfinder is real.
	if pathfinder != null and not Engine.is_editor_hint():
		pathfinder.rebuild()

	_place_player_on_walkable(grid)

	print(
		"ProceduralWorld: generated %dx%d, top altitude %d, seed %d."
		% [params.width, params.height, params.top_altitude, params.seed]
	)


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


# Scans the abstract grid for GROUND cells with FLAT/FULL_CUBE shape, picks
# the one with the lowest altitude (ties broken by distance to map center).
# Slopes are excluded so the player starts on a stable footing — slopes work
# fine to walk through but look odd as a starting pose.
func _find_starting_cell(grid: TerrainGrid) -> Vector2i:
	var center := Vector2(grid.width * 0.5, grid.height * 0.5)
	var best := Vector2i(-1, -1)
	var best_alt: int = 0x7FFFFFFF
	var best_dist_sq: float = INF
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
			if c.altitude < best_alt \
					or (c.altitude == best_alt and dist_sq < best_dist_sq):
				best = cell
				best_alt = c.altitude
				best_dist_sq = dist_sq
	return best


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
