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


## Every node the engine is actually calling _process on, grouped by script and
## SUMMED ACROSS INSTANCES.
##
## The hand-picked table above times the four systems someone thought to look
## at. This one asks the tree instead, which is the only way to catch the costs
## that live in a hundred small nodes rather than in one big system — and there
## is no reason to expect the biggest per-frame script cost to be a singleton.
##
## Two things it deliberately does:
##   - `is_processing()` filters the list, so a node whose _process the game
##     switched off is not counted. Every Visitor is in that state (the spawner
##     drives its crowd itself), and counting them would invent work the game
##     does not do.
##   - it calls _process directly, which ADVANCES that node's state — ages
##     fires, ticks timers. Fine for a measurement run that quits afterwards;
##     it does mean the numbers come from a map that has been driven a few
##     hundred extra frames by the end of the census.
##
## Read a cheap row with suspicion rather than relief: a system whose _process
## early-outs on a state flag (paused clock, hidden overlay, no hover) is cheap
## RIGHT NOW, not cheap in general. The instance count is the other half of the
## story — 1 x 300 us and 300 x 1 us want completely different fixes.
func _census() -> void:
	var by_script: Dictionary = {}
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n.get_script() == null or not n.is_processing():
			continue
		if not n.has_method(&"_process"):
			continue
		var path: String = (n.get_script() as Script).resource_path
		if not by_script.has(path):
			by_script[path] = []
		(by_script[path] as Array).append(n)

	print("\n--- every processing node, by script, summed over instances ---")
	_rows.clear()
	var total: float = 0.0
	for path: String in by_script:
		var nodes: Array = by_script[path]
		var reps: int = 60
		var t := Time.get_ticks_usec()
		for r in reps:
			for n: Node in nodes:
				if is_instance_valid(n):
					n.call(&"_process", DT)
		var us: float = float(Time.get_ticks_usec() - t) / float(reps)
		total += us
		_row(path.get_file().get_basename(), us, "x%d" % nodes.size())
	_print_rows()
	print("  %-32s %10.1f us   %.1f%% of a 60 fps frame"
			% ["TOTAL script _process", total, total / 16700.0 * 100.0])


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

	# Is the traversable graph UNDIRECTED? Anything that caches "the set
	# reachable from X" and then reuses it for every OTHER cell in that set is
	# only correct if it is. benchmark_visitors.gd's cost-field code asserts the
	# opposite ("ladder/ramp transitions are not symmetric"), so it is settled
	# here by exhaustive check rather than by reading either comment.
	var asym: int = 0
	var probe_dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(0, 1)]
	for c: Vector2i in grid.walkable_cells():
		for d in probe_dirs:
			if grid.can_transition(c, c + d) != grid.can_transition(c + d, c):
				asym += 1
	print("\ncan_transition asymmetric edges: %d (0 means the graph is undirected)" % asym)

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

	_census()

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
	# RegrowthManager USED to appear here: one pass over the whole damaged-cell
	# ledger at every midnight, 0.4-0.7 ms at 170 cells and scaling with the
	# scar. Recovery is continuous now (a slice of the ledger per frame, each
	# cell integrating its own elapsed time), so there is no day-boundary spike
	# left to measure — the cost moved into the per-frame table above, at a few
	# microseconds a frame.
	_print_rows()

	_rows.clear()
	print("\n--- the primitives those are built out of ---")
	# Inlined rather than run through _bench: a Callable invocation costs about a
	# microsecond in GDScript, which is most of what these calls cost. Timed
	# through fn.call() they all collapse toward the same number — an earlier run
	# of this tool reported can_transition unchanged at 5.0 us AFTER its two array
	# allocations had been removed, because it was measuring the harness.
	var cells: Array = grid.walkable_cells()
	var probe: Vector2i = cells[cells.size() / 2]
	var east := Vector2i(1, 0)
	var reps: int = 200000

	var t0 := Time.get_ticks_usec()
	for i in reps:
		grid.is_walkable(probe)
	_row("TileGrid.is_walkable", float(Time.get_ticks_usec() - t0) / float(reps))

	var t1 := Time.get_ticks_usec()
	for i in reps:
		grid.can_transition(probe, probe + east)
	_row("TileGrid.can_transition", float(Time.get_ticks_usec() - t1) / float(reps),
			"was two Array[int] allocations per call")

	var t2 := Time.get_ticks_usec()
	for i in reps:
		grid.classify_step(probe, probe + east)
	_row("TileGrid.classify_step", float(Time.get_ticks_usec() - t2) / float(reps))

	# What Player._tick_shadow_cutoff USED to do every frame, and the reason the
	# Player node measured ~170 us against a Visitor's 4.4 us for the same
	# GridWalker movement core. It is now recomputed only when current_cell or
	# the shadow direction changes (and on graph_changed), which took the Player
	# row to ~3.5 us. Kept here because the call itself is still this expensive —
	# anything that starts running it per frame again will show up as the same
	# 170 us.
	var t5 := Time.get_ticks_usec()
	for i in reps:
		_pathfinder.shadow_altitude_deltas(probe, 1)
	_row("  Pathfinder.shadow_altitude_deltas",
			float(Time.get_ticks_usec() - t5) / float(reps),
			"per frame, but its inputs change per STEP")

	var mat := ShaderMaterial.new()
	mat.shader = load("res://assets/shaders/burn_dissolve.gdshader")
	var t6 := Time.get_ticks_usec()
	for i in reps:
		mat.get_shader_parameter(&"burn_amount")
	_row("  ShaderMaterial.get_shader_parameter",
			float(Time.get_ticks_usec() - t6) / float(reps),
			"a READ-BACK, polled per frame for a pushed value")

	# The edge-match rule, both ways, isolated from everything else
	# can_transition does. can_transition itself barely moved when the array
	# version was replaced, and "barely moved" is a claim that needs the two
	# forms timed side by side rather than inferred from a whole-function delta.
	var t3 := Time.get_ticks_usec()
	for i in reps:
		grid._edges_share_altitude(probe, east, probe + east)
	_row("  edge match: integer form",
			float(Time.get_ticks_usec() - t3) / float(reps))

	var t4 := Time.get_ticks_usec()
	for i in reps:
		var ex: Array[int] = grid._edge_altitudes(probe, east)
		var en: Array[int] = grid._edge_altitudes(probe + east, -east)
		var hit: bool = false
		for a in ex:
			if a in en:
				hit = true
				break
	_row("  edge match: two-Array form",
			float(Time.get_ticks_usec() - t4) / float(reps), "what it replaced")
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
