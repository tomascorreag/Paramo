extends SceneTree
## Attributes the DAY-BOUNDARY hitch to a system, instead of guessing.
##
## Four listeners fire inside one frame at midnight (SeasonManager,
## RegrowthManager, VisitorFlow, RunCalendar), VisitorFlow banks the day's
## arrivals into VisitorSpawner, and at closing the whole crowd re-routes home.
## Any of those could be the stutter, and they are all invisible to
## profile_scene.gd, which reports a MEDIAN over frames where no boundary
## happened.
##
## Two phases:
##
##   frames      Runs the map for real, forcing the clock across midnight every
##               `--every` frames, recording EVERY frame's wall time. Prints the
##               worst frames with what happened on them (day boundary, a spawn,
##               the closing sweep). This is the evidence — everything else is a
##               breakdown of it.
##
##   handlers    Calls each day_completed listener directly, once, timing each,
##               then prices the two visitor-side operations the boundary can
##               trigger: one spawn (up to 3 A* + standing reservations) and the
##               closing send_home sweep (that, times the crowd).
##
## Needs a rendering context — do NOT pass --headless (the map paints tiles, and
## the repaints RegrowthManager does are part of what is being measured).
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/profile_day_boundary.gd
##
## Args:
##   --scene <res>   map to run on (default: level1)
##   --count <n>     crowd requested up front (default 8)
##   --frames <n>    frames of walking before measuring (default 600)
##   --measure <n>   frames to record (default 900)
##   --day-secs <n>  seconds per game day while measuring (default 20; the game
##                   ships 240, which is minutes of wall clock per boundary)
##   --damage <n>    cells bared before measuring, so RegrowthManager's daily
##                   pass has a realistic scar to walk (default 300)

const DEFAULT_SCENE := "res://scenes/maps/level1.tscn"
const WINDOW_SIZE := Vector2i(960, 540)
const GRID_STABLE_FRAMES: int = 90
const MIN_SETTLE_FRAMES: int = 60

var _scene_path: String = DEFAULT_SCENE
var _count: int = 8
var _walk_frames: int = 600
var _measure_frames: int = 900
var _day_secs: float = 20.0
var _damage: int = 300

var _map: Node = null
var _spawner: Node = null
var _pathfinder: Pathfinder = null
var _clock: Node = null

var _frames: int = 0
var _walk_until: int = -1
var _measure_from: int = -1
var _grid_stamp: int = 0
var _stable_since: int = 0

var _last_us: int = 0
var _times: PackedFloat32Array = PackedFloat32Array()
var _notes: Dictionary = {}     # measured frame index -> String
var _live_prev: int = 0
var _fires_prev: int = 0
var _open_prev: bool = true
var _fire: Node = null


func _initialize() -> void:
	_parse_args()


func _parse_args() -> void:
	var argv := OS.get_cmdline_user_args()
	var i: int = 0
	while i < argv.size():
		match argv[i]:
			"--scene": _scene_path = argv[i + 1]; i += 1
			"--count": _count = int(argv[i + 1]); i += 1
			"--frames": _walk_frames = int(argv[i + 1]); i += 1
			"--measure": _measure_frames = int(argv[i + 1]); i += 1
			"--day-secs": _day_secs = float(argv[i + 1]); i += 1
			"--damage": _damage = int(argv[i + 1]); i += 1
		i += 1


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		if current_scene != null:
			current_scene.queue_free()
		DisplayServer.window_set_size(WINDOW_SIZE)
		# Without this every frame reads as the refresh interval and nothing
		# under the frame budget is resolvable — the first run of this tool
		# reported a flat 13.34 ms median and learned nothing.
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
		_map = load(_scene_path).instantiate()
		root.add_child(_map)
		return false

	if _walk_until < 0:
		if not _grid_settled():
			if _frames > 3000:
				push_error("profile_day_boundary: the grid never settled.")
				quit(1)
				return true
			return false
		if not _start_crowd():
			quit(1)
			return true
		_walk_until = _frames + _walk_frames
		return false

	if _frames < _walk_until:
		return false

	if _measure_from < 0:
		_measure_from = _frames
		_last_us = Time.get_ticks_usec()
		_live_prev = int(_spawner.call(&"live_count"))
		_open_prev = bool(_spawner.call(&"is_open_now"))
		_clock.connect(&"day_completed", _on_day)
		_clock.connect(&"period_changed", _on_period)
		_fire = root.get_node_or_null(^"/root/FireManager")
		_pathfinder.graph_changed.connect(_on_graph)
		_clock.set(&"seconds_per_game_day", _day_secs)
		return false

	var idx: int = _frames - _measure_from
	var now := Time.get_ticks_usec()
	_times.append(float(now - _last_us) / 1000.0)
	_last_us = now

	if _fire != null:
		var fires: int = int(_fire.call(&"burning_count"))
		if fires != _fires_prev:
			_note(idx, "fires %d->%d" % [_fires_prev, fires])
			_fires_prev = fires

	var open: bool = bool(_spawner.call(&"is_open_now"))
	if open != _open_prev:
		_note(idx, "park %s" % ("OPENS" if open else "CLOSES"))
		_open_prev = open

	var live: int = int(_spawner.call(&"live_count"))
	if live != _live_prev:
		_note(idx, "live %d->%d" % [_live_prev, live])
		_live_prev = live

	if idx < _measure_frames:
		return false

	_report_frames()
	_report_handlers()
	quit(0)
	return true


func _on_day(day: int) -> void:
	_note(_frames - _measure_from, "DAY BOUNDARY (day %d)" % day)


## Every other clock edge, so a spike sitting on one of THOSE is not read as the
## day boundary's. An earlier version of this tool forced midnight by teleporting
## time_of_day, which crossed several period thresholds in the same frame and
## charged their weather rolls to the boundary. The clock is COMPRESSED instead:
## the same edges, in the same order, just sooner.
func _on_period(new_period: StringName, _old: StringName) -> void:
	_note(_frames - _measure_from, "period -> %s" % new_period)


## The pathfinder rebuilding its graph — a placement, a regeneration. O(grid),
## and nothing to do with the clock, so it has to be distinguishable from one.
func _on_graph() -> void:
	_note(_frames - _measure_from, "graph_changed")


func _note(idx: int, text: String) -> void:
	var have: String = _notes.get(idx, "")
	_notes[idx] = text if have.is_empty() else have + " + " + text


# ----------------------------------------------------------------------------
# Phase 1 — where the spikes actually are
# ----------------------------------------------------------------------------

func _report_frames() -> void:
	print("\n=== profile_day_boundary: %s ===" % _scene_path)
	print("crowd %d, %d frames recorded, %.0f s per game day"
			% [int(_spawner.call(&"live_count")), _times.size(), _day_secs])

	var sorted := PackedFloat32Array(_times)
	sorted.sort()
	var n: int = sorted.size()
	print("\nframe time  median %.2f ms   p95 %.2f ms   p99 %.2f ms   worst %.2f ms"
			% [sorted[n / 2], sorted[int(n * 0.95)], sorted[int(n * 0.99)], sorted[n - 1]])

	# The signal fires inside TimeManager._process, which may sit either side of
	# this script's _process in the frame — so a boundary's cost can land on the
	# marked frame or the one after it. Both are printed.
	var order: Array = []
	for i in _times.size():
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool: return _times[a] > _times[b])
	print("\n20 worst frames:")
	for k in mini(20, order.size()):
		var i: int = order[k]
		var parts: Array[String] = []
		for d in range(-3, 4):
			var nt: String = _notes.get(i + d, "")
			if not nt.is_empty():
				parts.append("%+d %s" % [d, nt])
		print("  frame %5d   %8.2f ms   %s" % [i, _times[i], " | ".join(parts)])

	# What a marked frame costs against the ordinary one, which is the number
	# that says whether the boundary is the stutter at all.
	var day_ms: float = 0.0
	var day_n: int = 0
	for i: int in _notes.keys():
		if String(_notes[i]).contains("DAY BOUNDARY") and i < _times.size():
			day_ms += _times[i]
			day_n += 1
			if i + 1 < _times.size():
				day_ms += _times[i + 1]
	if day_n > 0:
		print("\nday-boundary frames (marked + next): %.2f ms mean over %d boundaries, "
				% [day_ms / float(day_n), day_n] + "median frame %.2f ms" % sorted[n / 2])


# ----------------------------------------------------------------------------
# Phase 2 — the breakdown
# ----------------------------------------------------------------------------

## Each listener called ONCE, by hand. Once because they mutate: RegrowthManager
## heals the whole ledger, VisitorFlow banks a day's arrivals, SeasonManager can
## roll the season. A repeated call would measure a drained ledger.
func _report_handlers() -> void:
	print("\nday_completed listeners, one call each")
	var regrowth := _group_node(&"regrowth")
	if regrowth != null:
		var tracked: int = int(regrowth.call(&"bare_count"))
		var t := Time.get_ticks_usec()
		regrowth.call(&"_on_day_completed", 1)
		print("  RegrowthManager  %8.1f us   (%d bare cells, %.1f cells of deficit)"
				% [float(Time.get_ticks_usec() - t), tracked,
				float(regrowth.call(&"vegetation_deficit"))])

	var flow := _group_node(&"visitor_flow")
	if flow != null:
		var t := Time.get_ticks_usec()
		flow.call(&"_on_day_completed", 1)
		print("  VisitorFlow      %8.1f us   (queued %d arrivals)"
				% [float(Time.get_ticks_usec() - t), int(_spawner.call(&"pending_count"))])

	var seasons := root.get_node_or_null(^"/root/SeasonManager")
	if seasons != null:
		var t := Time.get_ticks_usec()
		seasons.call(&"_on_day_completed", 1)
		print("  SeasonManager    %8.1f us" % float(Time.get_ticks_usec() - t))

	# The visitor-side work the boundary CAUSES, which is spread over the
	# following frames rather than paid at midnight — one spawn per
	# group_member_stagger_seconds, and the whole crowd at closing.
	print("\nwhat the arrivals then cost")
	_spawner.set(&"stagger_seconds", 0.0)
	_spawner.set(&"group_member_stagger_seconds", 0.0)
	_spawner.set(&"max_concurrent", 999)
	_spawner.call(&"request_visitors", 4)
	for i in 4:
		var t := Time.get_ticks_usec()
		_spawner.call(&"tick", 1.0 / 60.0)
		print("  spawner.tick (spawns one) %8.1f us" % float(Time.get_ticks_usec() - t))

	# The A* itself, per visitor, both legs. send_home / a spawn is up to three of
	# these plus reservations, and a FAILED search is the expensive case: A* with
	# no goal to find expands the whole component before returning [].
	var entry: Vector2i = _spawner.call(&"entry_cell")
	for v in _live_visitors():
		var here: Vector2i = v.get(&"current_cell")
		var goal: Vector2i = v.get(&"goal_cell")
		var t0 := Time.get_ticks_usec()
		var to_entry: Array = _pathfinder.find_path(here, entry)
		var us0 := float(Time.get_ticks_usec() - t0)
		var t1 := Time.get_ticks_usec()
		var to_goal: Array = _pathfinder.find_path(here, goal)
		var us1 := float(Time.get_ticks_usec() - t1)
		print("  find_path %s->entry %8.1f us (%d steps) | ->goal %8.1f us (%d steps)"
				% [here, us0, to_entry.size(), us1, to_goal.size()])

	var crowd := _live_visitors()
	if not crowd.is_empty():
		var t := Time.get_ticks_usec()
		for v in crowd:
			v.call(&"send_home")
		var us := float(Time.get_ticks_usec() - t)
		print("  closing send_home sweep   %8.1f us  (%d visitors, %.1f us each)"
				% [us, crowd.size(), us / float(crowd.size())])


# ----------------------------------------------------------------------------
# Setup
# ----------------------------------------------------------------------------

func _group_node(g: StringName) -> Node:
	return root.get_tree().get_first_node_in_group(g)


func _grid_settled() -> bool:
	_pathfinder = _group_node(&"pathfinder") as Pathfinder
	if _pathfinder == null:
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


func _start_crowd() -> bool:
	_spawner = _map.find_child("VisitorSpawner", true, false)
	if _spawner == null:
		push_error("profile_day_boundary: no VisitorSpawner in %s." % _scene_path)
		return false
	var seasons := root.get_node_or_null(^"/root/SeasonManager")
	if seasons != null:
		seasons.set(&"phase", 1)  # SeasonManager.Phase.ACTIVE
	_clock = root.get_node_or_null(^"/root/TimeManager")
	if _clock == null:
		push_error("profile_day_boundary: no TimeManager autoload.")
		return false
	_clock.set(&"paused", false)
	_clock.set(&"time_of_day", 0.5)  # midday, inside opening hours
	_spawner.call(&"request_visitors", _count)
	_seed_damage()
	return true


## Bare `--damage` cells before measuring. RegrowthManager's daily pass is a loop
## over DAMAGED cells only, so its cost is proportional to the scar — and a
## 30-second tool run accumulates neither fire nor footfall, which is why the
## first runs of this tool timed the pass over an EMPTY ledger and read 9 us.
## A real mid-run mountain carries several hundred.
func _seed_damage() -> void:
	if _damage <= 0:
		return
	var regrowth := _group_node(&"regrowth")
	if regrowth == null:
		return
	var reach: Dictionary = _pathfinder.compute_reachable_set(
			_spawner.call(&"entry_cell"))
	var cells: Array = reach.keys()
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	for i in mini(_damage, cells.size()):
		regrowth.call(&"trample", cells[rng.randi_range(0, cells.size() - 1)], 1.0)


## Visitors are deliberately NOT in a group — found by type, like
## benchmark_visitors.gd does it.
func _live_visitors() -> Array:
	var out: Array = []
	for n in _map.find_children("*", "Node2D", true, false):
		if n is Visitor:
			out.append(n)
	return out
