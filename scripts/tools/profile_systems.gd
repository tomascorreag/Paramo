extends SceneTree
## Ranks the per-frame and one-shot costs of every live system on a LOADED map,
## so "what should we optimise or cut" is answered with numbers.
##
## profile_scene.gd reports a whole-frame median on an idle map and concludes
## "no system is above the noise floor" — true, and useless, because the costs
## that matter here are (a) one-shot spikes that never land in a median and
## (b) steady-state work that only exists once the map is BUSY. So this loads
## level1, lights fires, spawns a crowd, wears the ground, and then times each
## system's own entry point.
##
## Two tables:
##
##   per frame   each system's tick at the load stated, averaged over many
##               calls. Read against a 16.7 ms frame.
##
##   one shot    the spikes: a structure placement's graph rebuild, the
##               reachable-set flood fill, the day-boundary pass. These are what
##               a player feels as a hitch, and none of them appear in a median.
##
## Needs a rendering context — do NOT pass --headless (the map paints tiles and
## the fire VFX are real nodes).
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/profile_systems.gd
##
## Args:
##   --scene <res>   map (default: level1)
##   --fires <n>     fires alight before measuring (default 80, the shipped
##                   FireManager.MAX_CONCURRENT_BURNING)
##   --visitors <n>  crowd (default 8, the shipped max_concurrent)
##   --damage <n>    cells worn before measuring, for the regrowth ledger
##                   (default 300)

const DEFAULT_SCENE := "res://scenes/maps/level1.tscn"
const WINDOW_SIZE := Vector2i(960, 540)
const GRID_STABLE_FRAMES: int = 90
const MIN_SETTLE_FRAMES: int = 60
const DT: float = 1.0 / 60.0

var _scene_path: String = DEFAULT_SCENE
var _fires: int = 80
var _visitors: int = 8
var _damage: int = 300

var _map: Node = null
var _pathfinder: Pathfinder = null
var _spawner: Node = null
var _frames: int = 0
var _walk_until: int = -1
var _grid_stamp: int = 0
var _stable_since: int = 0
## Set by ProceduralWorld.generation_finished. Grid-identity stability is NOT a
## substitute and this tool proved it: the pathfinder's graph settles while the
## painter is still laying tiles across frames, so a sample taken then finds
## CellData whose layer has no tile under it yet — reading as "no grass on the
## map", i.e. fire and trampling silently doing nothing.
var _painted: bool = false

var _rows: Array = []


func _initialize() -> void:
	var argv := OS.get_cmdline_user_args()
	var i: int = 0
	while i < argv.size():
		match argv[i]:
			"--scene": _scene_path = argv[i + 1]; i += 1
			"--fires": _fires = int(argv[i + 1]); i += 1
			"--visitors": _visitors = int(argv[i + 1]); i += 1
			"--damage": _damage = int(argv[i + 1]); i += 1
		i += 1


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		if current_scene != null:
			current_scene.queue_free()
		DisplayServer.window_set_size(WINDOW_SIZE)
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
		_map = load(_scene_path).instantiate()
		root.add_child(_map)
		return false

	if _walk_until < 0:
		if not _settled():
			if _frames > 3000:
				push_error("profile_systems: the grid never settled.")
				quit(1)
				return true
			return false
		_load_the_map()
		# Let the crowd spread and the fires reach a range of ages — a field of
		# freshly-lit fires all tick the same branch.
		_walk_until = _frames + 600
		return false
	if _frames < _walk_until:
		return false

	_light_fires()
	_report()
	quit(0)
	return true


# ----------------------------------------------------------------------------
# Load
# ----------------------------------------------------------------------------

func _load_the_map() -> void:
	var seasons := root.get_node_or_null(^"/root/SeasonManager")
	if seasons != null:
		seasons.set(&"phase", 1)  # ACTIVE
	var clock := root.get_node_or_null(^"/root/TimeManager")
	if clock != null:
		clock.set(&"paused", false)
		clock.set(&"time_of_day", 0.45)

	_spawner = _map.find_child("VisitorSpawner", true, false)
	if _spawner != null:
		_spawner.set(&"max_concurrent", maxi(_visitors, 1))
		_spawner.set(&"stagger_seconds", 0.2)
		_spawner.set(&"group_member_stagger_seconds", 0.1)
		_spawner.call(&"request_visitors", _visitors)

	var reach: Dictionary = _pathfinder.compute_reachable_set(_start_cell())
	var cells: Array = reach.keys()
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260810

	var regrowth := root.get_tree().get_first_node_in_group(&"regrowth")
	if regrowth != null:
		for i in mini(_damage, cells.size()):
			regrowth.call(&"trample", cells[rng.randi_range(0, cells.size() - 1)], 1.0)


## Lit LAST, immediately before measuring. Fires burn out in a couple of hundred
## frames, so igniting them before the crowd's walk leaves a third of the field
## alight and measures the wrong load.
func _light_fires() -> void:
	var fire := root.get_node_or_null(^"/root/FireManager")
	if fire == null:
		return
	var cells: Array = _pathfinder.compute_reachable_set(_start_cell()).keys()
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260810
	# ignite() refuses anything that isn't grass, so this asks far more often
	# than it needs to rather than filtering.
	var tries: int = 0
	while int(fire.call(&"burning_count")) < _fires and tries < 20000:
		tries += 1
		fire.call(&"ignite", cells[rng.randi_range(0, cells.size() - 1)])


func _start_cell() -> Vector2i:
	if _spawner != null:
		var c: Vector2i = _spawner.call(&"entry_cell")
		if c != Pathfinder.NO_CELL:
			return c
	var player := root.get_tree().get_first_node_in_group(&"player")
	if player != null and "current_cell" in player:
		return player.current_cell
	return Pathfinder.NO_CELL


# ----------------------------------------------------------------------------
# Measure
# ----------------------------------------------------------------------------

func _row(label: String, us: float, note: String = "") -> void:
	_rows.append([label, us, note])


## `fn` timed over `reps` calls, reported per call.
func _bench(label: String, reps: int, fn: Callable, note: String = "") -> void:
	var t := Time.get_ticks_usec()
	for i in reps:
		fn.call()
	_row(label, float(Time.get_ticks_usec() - t) / float(reps), note)


func _report() -> void:
	var fire := root.get_node_or_null(^"/root/FireManager")
	var regrowth := root.get_tree().get_first_node_in_group(&"regrowth")
	var flow := root.get_tree().get_first_node_in_group(&"visitor_flow")
	var burning: int = int(fire.call(&"burning_count")) if fire != null else 0
	var crowd: int = int(_spawner.call(&"live_count")) if _spawner != null else 0
	var grid: TileGrid = _pathfinder.grid()

	print("\n=== profile_systems: %s ===" % _scene_path)
	print("%d cells walkable, %d fires burning, %d visitors, %d cells damaged"
			% [grid.walkable_cells().size(), burning, crowd,
			int(regrowth.call(&"bare_count")) if regrowth != null else 0])

	print("\n--- per frame, at that load (a frame is 16700 us) ---")
	if fire != null:
		_bench("FireManager.sim_tick", 300,
				func() -> void: fire.call(&"sim_tick", DT, 0.0),
				"%d fires" % burning)
	if _spawner != null:
		_bench("VisitorSpawner.tick", 300,
				func() -> void: _spawner.call(&"tick", DT), "%d visitors" % crowd)
	if regrowth != null:
		_bench("RegrowthManager.tick", 300, func() -> void: regrowth.call(&"tick", DT))
	if flow != null:
		_bench("VisitorFlow.tick", 300, func() -> void: flow.call(&"tick", DT))
	_print_rows()

	_rows.clear()
	print("\n--- inside FireManager.sim_tick, %d fires ---" % burning)
	if fire != null:
		_bench("_advance_burns (burn + spread)", 200,
				func() -> void: fire.call(&"_advance_burns", DT, 0.0))
		_bench("_roll_ignitions", 200, func() -> void: fire.call(&"_roll_ignitions"),
				"%d samples, every %.2fs" % [4, 0.25])
		# What the burn loop spends on driving the shader, isolated: every live
		# fire is pushed a state every frame whether or not it changed.
		var vfx: Array = root.get_tree().get_nodes_in_group(&"fire_vfx")
		if not vfx.is_empty():
			_bench("  of which BurningCellVFX.set_state", 200, func() -> void:
				for v in vfx:
					if is_instance_valid(v):
						v.call(&"set_state", 0.6, 0.5),
				"%d live VFX nodes" % vfx.size())
	_print_rows()

	_rows.clear()
	print("\n--- one shot: the spikes a median never sees ---")
	_bench("Pathfinder.rebuild", 5, func() -> void: _pathfinder.rebuild(),
			"EVERY structure placement")
	var anchor := _start_cell()
	_bench("compute_reachable_set", 10,
			func() -> void: _pathfinder.compute_reachable_set(anchor),
			"per player step (UXOverlay), per graph change (spawner)")
	if regrowth != null:
		var t := Time.get_ticks_usec()
		regrowth.call(&"_on_day_completed", 1)
		_row("RegrowthManager day pass", float(Time.get_ticks_usec() - t),
				"walks the damaged-cell ledger")
	_print_rows()

	_rows.clear()
	print("\n--- the primitives those are built out of ---")
	var cells: Array = grid.walkable_cells()
	var probe: Vector2i = cells[cells.size() / 2]
	_bench("TileGrid.can_transition", 20000,
			func() -> void: grid.can_transition(probe, probe + Vector2i(1, 0)),
			"allocates 2 Array[int] per call (_edge_altitudes)")
	_bench("TileGrid.is_walkable", 20000, func() -> void: grid.is_walkable(probe))
	_bench("TileGrid.classify_step", 20000,
			func() -> void: grid.classify_step(probe, probe + Vector2i(1, 0)))
	# Two legs, because the interesting one is the FAILURE: A* with no route to
	# find has no goal to stop at, so it expands the entire connected component
	# before returning []. Visitors hit this whenever a goal is cut off.
	var far: Vector2i = cells[cells.size() / 3]
	var reachable_target: bool = not _pathfinder.find_path(anchor, far).is_empty()
	_bench("find_path, %s target" % ("reachable" if reachable_target else "UNREACHABLE"),
			50, func() -> void: _pathfinder.find_path(anchor, far),
			"%d steps" % _pathfinder.find_path(anchor, far).size())
	var near: Vector2i = _pathfinder.compute_reachable_set(anchor).keys()[-1]
	_bench("find_path, reachable target", 50,
			func() -> void: _pathfinder.find_path(anchor, near),
			"%d steps" % _pathfinder.find_path(anchor, near).size())
	_print_rows()


func _print_rows() -> void:
	_rows.sort_custom(func(a: Array, b: Array) -> bool: return a[1] > b[1])
	for r in _rows:
		print("  %-32s %10.1f us   %s" % [r[0], r[1], r[2]])


func _settled() -> bool:
	_pathfinder = root.get_tree().get_first_node_in_group(&"pathfinder") as Pathfinder
	if _pathfinder == null:
		return false
	var pw := root.get_tree().get_first_node_in_group(&"procedural_world")
	if pw != null:
		if not _painted:
			if not pw.is_connected(&"generation_finished", _on_painted):
				pw.connect(&"generation_finished", _on_painted)
			return false
	var grid: Object = _pathfinder.grid()
	var stamp: int = grid.get_instance_id() if grid != null else 0
	if stamp == 0:
		return false
	if stamp != _grid_stamp:
		_grid_stamp = stamp
		_stable_since = _frames
		return false
	return _frames >= MIN_SETTLE_FRAMES and (_frames - _stable_since) >= GRID_STABLE_FRAMES


func _on_painted() -> void:
	_painted = true
