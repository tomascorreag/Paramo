@tool
extends SceneTree

# ============================================================================
# benchmark_sim_world.gd — Increment-0 spike for the balance simulator.
# ============================================================================
#
# Times every phase a headless Monte Carlo run would pay, so the simulator's
# architecture is chosen from measurements instead of guesses:
#
#   generate   TerrainGenerator.generate per seed (pure, no scene API)
#   paint      TerrainPainter.paint into a real headless TileMapLayer stack
#              (the stack is built ONCE and clear()ed between seeds — the
#              reuse strategy the simulator plans to use)
#   rebuild    Pathfinder.rebuild (TileGrid from painted layers)
#   objects    ObjectPainter.assign_object_kinds + paint (rock scenes into a
#              detached Node2D world) — viability + cost of full-fidelity
#              occupants
#   ticks      23,040 iterations (0.25 s x 960/day x 24 days) of the cheap
#              per-tick math: dryness step + water gain + a synthetic
#              20-burning-cell FireDynamics load. This is the loop floor,
#              NOT the full sim (no signals, no bot).
#
# Go/no-go: the plan targets >=100 runs/min (<=600 ms per run). If paint
# dominates past ~1 s, the simulator must reuse terrain across policy sweeps.
#
# Usage (headless is fine — nothing renders):
#   Godot --path . --headless --script res://scripts/tools/sim/benchmark_sim_world.gd -- --seeds 5
# ============================================================================

const TILE_SET_PATH: String = "res://resources/tiles/base_tileset.tres"

# ClimateController / WaterCycle reference autoload identifiers (SeasonManager,
# TimeManager) at compile time, and autoloads are NOT registered under
# --script. Naming them as compile-time identifiers here would fail the whole
# dependency chain — so they are load()ed at runtime, AFTER the autoload stack
# is hand-installed (profile_scene.gd pattern).
const _AUTOLOADS: Array = [
	["DisplayManager", "res://scripts/systems/display_manager.gd"],
	["TimeManager", "res://scripts/systems/time_manager.gd"],
	["Debug", "res://scripts/systems/debug.gd"],
	["FireManager", "res://scripts/systems/fire_manager.gd"],
	["ResourceLedger", "res://scripts/systems/resource_ledger.gd"],
	["SeasonManager", "res://scripts/systems/season_manager.gd"],
]
const DEFAULT_SEEDS: int = 5
# Mirrors procedural_base.tscn: Ground0..Ground16 at altitudes 0..32 (even),
# cliff skirt at -2..-8. The painter warns per missing altitude otherwise.
const GROUND_ALTITUDES_MAX: int = 32
const CLIFF_ALTITUDES: Array[int] = [-2, -4, -6, -8]

const TICKS_PER_RUN: int = 23_040
const SYNTHETIC_BURNING_CELLS: int = 20


# All work happens in _process (first call), NOT _init: autoload global
# identifiers (SeasonManager, Debug, ...) are not yet registered with the
# GDScript compiler while the SceneTree is still constructing, so any load()
# of a system script from _init fails to compile. One frame later they resolve
# (same reason profile_scene.gd runs from _initialize/_process).
var _ran: bool = false


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_run()
	return true


func _run() -> void:
	var seeds: int = DEFAULT_SEEDS
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var i: int = 0
	while i < args.size():
		if args[i] == "--seeds":
			i += 1
			seeds = maxi(1, int(args[i]))
		i += 1

	print("=== benchmark_sim_world: %d seed(s) ===" % seeds)

	_install_autoloads()
	var climate: GDScript = load("res://scripts/systems/climate_controller.gd")
	var water: GDScript = load("res://scripts/systems/water_cycle.gd")
	if climate == null or water == null:
		push_error("benchmark_sim_world: failed to load system scripts.")
		quit(1)
		return

	var tile_set: TileSet = load(TILE_SET_PATH)
	if tile_set == null:
		push_error("benchmark_sim_world: cannot load %s" % TILE_SET_PATH)
		quit(1)
		return

	# --- build the reusable world scaffolding (once per process) -------------
	var t0: int = Time.get_ticks_usec()
	var ground_layers: Array[TileMapLayer] = []
	var layers_by_altitude: Dictionary = {}
	for alt in range(0, GROUND_ALTITUDES_MAX + 1, 2):
		var l := _make_layer(alt, tile_set)
		ground_layers.append(l)
		layers_by_altitude[alt] = l
	for alt in CLIFF_ALTITUDES:
		layers_by_altitude[alt] = _make_layer(alt, tile_set)

	var pathfinder := Pathfinder.new()
	pathfinder.tile_map_layers = ground_layers
	root.add_child(pathfinder)  # _ready runs rebuild on the still-empty layers

	var world := Node2D.new()
	world.name = "SimWorldObjects"
	root.add_child(world)
	var setup_ms: float = (Time.get_ticks_usec() - t0) / 1000.0
	print("scaffold (once per process): %.1f ms" % setup_ms)

	# --- per-seed phases -----------------------------------------------------
	var gen_ms: Array = []
	var paint_ms: Array = []
	var rebuild_ms: Array = []
	var objects_ms: Array = []
	var object_counts: Array = []

	for s in seeds:
		var params := TerrainGenerationParams.new()
		params.seed = s + 1

		var t := Time.get_ticks_usec()
		var grid: TerrainGrid = TerrainGenerator.generate(params)
		gen_ms.append((Time.get_ticks_usec() - t) / 1000.0)

		t = Time.get_ticks_usec()
		for alt_key in layers_by_altitude:
			(layers_by_altitude[alt_key] as TileMapLayer).clear()
		TerrainPainter.paint(grid, layers_by_altitude, tile_set, params)
		paint_ms.append((Time.get_ticks_usec() - t) / 1000.0)

		t = Time.get_ticks_usec()
		pathfinder.bounds_clip = Rect2i(0, 0, params.width, params.height)
		pathfinder.rebuild()
		rebuild_ms.append((Time.get_ticks_usec() - t) / 1000.0)

		t = Time.get_ticks_usec()
		var obj_rng := RandomNumberGenerator.new()
		obj_rng.seed = (s + 1) ^ 0xC8FAB0CC
		ObjectPainter.assign_object_kinds(grid, obj_rng)
		ObjectPainter.paint(grid, world, pathfinder)
		objects_ms.append((Time.get_ticks_usec() - t) / 1000.0)
		object_counts.append(world.get_child_count())

	# --- synthetic tick loop (once — seed-independent math) ------------------
	var t1: int = Time.get_ticks_usec()
	var dryness: float = 0.5
	var water_total: float = 0.0
	var burn_sink: float = 0.0
	var game_day_delta: float = 0.25 / 240.0
	for _tick in TICKS_PER_RUN:
		dryness = climate.dryness_step(
				dryness, 0.75, 0.3, game_day_delta, 0.35, 1.2)
		water_total += water.gain_for(game_day_delta, 0.3, 2.0, 30.0)
		for c in SYNTHETIC_BURNING_CELLS:
			var intensity := FireDynamics.intensity(5.0, 0.6, 0.9)
			burn_sink += FireDynamics.fuel_consumed(intensity, 0.25)
			burn_sink += FireDynamics.spread_probability(intensity, 0.25, 1.0)
	var ticks_ms: float = (Time.get_ticks_usec() - t1) / 1000.0

	# --- report --------------------------------------------------------------
	print("")
	_report("generate", gen_ms)
	_report("paint   ", paint_ms)
	_report("rebuild ", rebuild_ms)
	_report("objects ", objects_ms)
	print("objects spawned per seed: %s" % [object_counts])
	print("ticks    (23,040 x %d-cell burn math): %.1f ms" % [
			SYNTHETIC_BURNING_CELLS, ticks_ms])

	var per_run: float = _mean(gen_ms) + _mean(paint_ms) + _mean(rebuild_ms) \
			+ _mean(objects_ms) + ticks_ms
	print("")
	print("estimated per-run floor: %.0f ms  (~%.0f runs/min single process)" % [
			per_run, 60_000.0 / maxf(per_run, 0.001)])
	print("target: >=100 runs/min (<=600 ms/run). sink=%f" % burn_sink)
	quit(0)


# Autoloads are not installed under --script; systems compiled after this runs
# resolve them from the root children (project.godot order preserved).
func _install_autoloads() -> void:
	for entry in _AUTOLOADS:
		if root.has_node(NodePath(entry[0])):
			continue
		var scr := load(entry[1]) as Script
		if scr == null:
			push_error("benchmark_sim_world: missing autoload script %s" % entry[1])
			continue
		var node := Node.new()
		node.set_script(scr)
		node.name = entry[0]
		root.add_child(node)


func _make_layer(alt: int, tile_set: TileSet) -> TileMapLayer:
	var l := TileMapLayer.new()
	l.name = "SimGround_%d" % alt
	l.tile_set = tile_set
	l.set_meta("altitude", alt)
	root.add_child(l)
	return l


static func _mean(samples: Array) -> float:
	if samples.is_empty():
		return 0.0
	var sum: float = 0.0
	for v in samples:
		sum += v
	return sum / samples.size()


func _report(label: String, samples: Array) -> void:
	var lo: float = INF
	var hi: float = 0.0
	for v in samples:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	print("%s mean %.1f ms  (min %.1f / max %.1f)" % [label, _mean(samples), lo, hi])
