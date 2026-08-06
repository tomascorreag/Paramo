class_name SimWorld
extends Node

## The balance simulator's headless world: real TerrainGenerator output
## painted into a REAL TileMapLayer stack (fire's fuel set only exists on
## painted layers — biome fallback + cliff/skirt overpaint aren't in the raw
## TerrainGrid), walked by a real Pathfinder, populated by ObjectPainter.
## Mirrors ProceduralWorld.regenerate() minus player/visuals/async.
##
## A Node (not RefCounted) so the layer stack, pathfinder and object parent
## are owned children — freeing the SimWorld frees the world. Built once per
## process; regenerate() clears and repaints per run (the expensive part is
## the paint, not node churn — measured in benchmark_sim_world.gd).
##
## Determinism note: ObjectPainter.paint() is NOT used — its begin_spawn
## re-rolls assign_object_kinds with a randomize()d rng (documented known
## non-determinism in the game). regenerate() instead assigns kinds with the
## run-derived seed and drives spawn_step directly, so rock placement is
## reproducible per seed.

const TILE_SET_PATH: String = "res://resources/tiles/base_tileset.tres"
# Mirrors procedural_base.tscn: Ground0..Ground16 (altitudes 0..32) walkable,
# cliff skirt at -2..-8 paint-only (absent from pathfinder wiring).
const GROUND_TOP_ALTITUDE: int = 32
const CLIFF_ALTITUDES: Array[int] = [-2, -4, -6, -8]
# Existing derived-seed constant from verify_terrain_invariants.gd — kept
# identical so object layouts match that harness at the same seed.
const OBJECT_SEED_XOR: int = 0xC8FAB0CC

var ground_layers: Array[TileMapLayer] = []
var layers_by_altitude: Dictionary = {}
var pathfinder: Pathfinder = null
## Parent for ObjectPainter-spawned occupants (rocks).
var object_parent: Node2D = null
var tile_set: TileSet = null
## The abstract grid of the last regenerate (biomes, water, altitude).
var grid: TerrainGrid = null
## The player-spawn cell the game would have picked for this seed.
var spawn_cell: Vector2i = Vector2i(-1, -1)

# Bare ProceduralWorld instance used ONLY for its spawn-pick logic
# (_find_starting_cell and helpers are instance-pure over the grid — verified;
# reusing the instance keeps one source of truth without a static refactor).
var _spawn_picker: Node = null


func _ready() -> void:
	tile_set = load(TILE_SET_PATH)
	for alt in range(0, GROUND_TOP_ALTITUDE + 1, 2):
		var l := _make_layer(alt)
		ground_layers.append(l)
		layers_by_altitude[alt] = l
	for alt in CLIFF_ALTITUDES:
		layers_by_altitude[alt] = _make_layer(alt)

	object_parent = Node2D.new()
	object_parent.name = "Objects"
	add_child(object_parent)

	pathfinder = Pathfinder.new()
	pathfinder.name = "SimPathfinder"
	pathfinder.tile_map_layers = ground_layers
	# _ready runs rebuild on the still-empty layers (harmless error print is
	# suppressed by giving it layers first; bounds set per run).
	add_child(pathfinder)

	_spawn_picker = load("res://scripts/tools/procedural_world.gd").new()


func _exit_tree() -> void:
	if _spawn_picker != null:
		_spawn_picker.free()
		_spawn_picker = null


## Generate + paint + rebuild + populate for `params` (seed already set by the
## caller). Deterministic per params.seed, including object placement.
func regenerate(params: TerrainGenerationParams) -> void:
	for alt_key in layers_by_altitude:
		(layers_by_altitude[alt_key] as TileMapLayer).clear()

	grid = TerrainGenerator.generate(params)
	TerrainPainter.paint(grid, layers_by_altitude, tile_set, params)

	# Clip the walkable grid to the playable disc — the south-cliff skirt
	# paints synthetic coords into the same ground layers past the edge.
	pathfinder.bounds_clip = Rect2i(0, 0, params.width, params.height)
	pathfinder.rebuild()

	# Deterministic object pass (see class comment). Runs AFTER rebuild so the
	# fresh TileGrid exists for occupant registration, like the game.
	var obj_rng := RandomNumberGenerator.new()
	obj_rng.seed = params.seed ^ OBJECT_SEED_XOR
	ObjectPainter.assign_object_kinds(grid, obj_rng)
	ObjectPainter._clear_existing(object_parent)
	var ctx: Dictionary = {
		"grid": grid,
		"world": object_parent,
		"pathfinder": pathfinder,
		"rng": obj_rng,
		"y": 0,
	}
	while not ObjectPainter.spawn_step(ctx, 0x7FFFFFFF):
		pass

	spawn_cell = _spawn_picker._find_starting_cell(grid)


## Per-source painted-cell census inside the playable bounds — the simulator's
## ground truth for "how much grass exists" and the parity probe against the
## game's paint path. {source_id: count}.
func cell_census() -> Dictionary:
	var out: Dictionary = {}
	var bounds := Rect2i(0, 0, grid.width, grid.height)
	for l in ground_layers:
		for cell: Vector2i in l.get_used_cells():
			if not bounds.has_point(cell):
				continue
			var src: int = l.get_cell_source_id(cell)
			out[src] = int(out.get(src, 0)) + 1
	return out


func _make_layer(alt: int) -> TileMapLayer:
	var l := TileMapLayer.new()
	l.name = "SimGround_%s" % str(alt).replace("-", "n")
	l.tile_set = tile_set
	l.set_meta("altitude", alt)
	add_child(l)
	return l
