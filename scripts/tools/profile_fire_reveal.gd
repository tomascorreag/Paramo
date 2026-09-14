extends SceneTree
## Attributes the "fire comes on screen" stutter, instead of guessing at it.
##
## The complaint is a hitch the moment a burning cell enters the view, NOT when
## it ignites. That distinction is the point of this tool: a canvas item outside
## the camera rect is CULLED, so its material never draws, so under
## gl_compatibility its shader is never compiled — a compile would then be paid
## on the first frame the fire is actually visible, on the main thread.
##
## ONE continuous recording, with scripted events noted on the frame they
## happened, because a phase-chopped version of this tool mis-attributed a spike
## that landed 37 frames after the camera moved. Everything is read off the
## worst-frames list against the notes beside it.
##
## The timeline:
##
##   ignite    fire lit OFF screen                        (is ignition the cost?)
##   reveal    camera snapped onto it                     (the suspect frame)
##   hide      camera snapped back off it
##   re-reveal camera snapped onto the SAME fire again    (one-time, or every time?)
##
## re-reveal cheap => a ONE-TIME cost (shader compilation), and a warm-up fixes
## it. re-reveal as dear as reveal => recurring per-reveal work, and it does not.
##
## Needs a rendering context — do NOT pass --headless (there is nothing to
## measure without a GPU to compile for).
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/profile_fire_reveal.gd
##
## Args:
##   --scene <res>    map to run on (default: level1)
##   --fires <n>      cells lit (default 6)
##   --record <n>     frames recorded (default 600)
##   --settle <n>     frames of warm-up before recording (default 240)
##   --offscreen <n>  world px a cell must sit from the camera to be off screen
##   --cluster <n>    world px radius the lit cells are packed into (default 100)
##   --sprite-flames  run the legacy sprite flame path instead of blobs
##   --cold           force a REAL compile of the fire shaders (see _make_cold)
##   --no-warmup      suppress FireShaderWarmup, i.e. measure the OLD behaviour
##   --compile-only   skip the map entirely and price the fire-shader COMPILE on
##                    its own, by timing a FireShaderWarmup's first draws. Pair
##                    it with --cold; the difference between the two is the bill
##                    the reveal frame used to pay. Frame-time noise on a fast
##                    desktop GPU swamps this when it is measured through a
##                    whole map, which is why it gets its own mode.

const DEFAULT_SCENE := "res://scenes/maps/level1.tscn"
const WINDOW_SIZE := Vector2i(960, 540)
const GRID_STABLE_FRAMES: int = 90
const MIN_SETTLE_FRAMES: int = 60

# Scripted events, as record-relative frame indices.
const AT_IGNITE: int = 60
const AT_REVEAL: int = 180
const AT_HIDE: int = 330
const AT_REREVEAL: int = 420

var _scene_path: String = DEFAULT_SCENE
var _fires: int = 6
var _record: int = 600
var _settle: int = 240
## World-pixel distance from the camera at which a cell counts as off screen.
## The logical viewport at WINDOW_SIZE is at most 240x135 px (integer upscale,
## see DisplayManager), so its half-diagonal is ~138 px; 300 is comfortably out
## while still fitting inside a level1-sized mountain.
var _offscreen_px: float = 300.0
## Radius the lit cells are packed into. Must stay inside one screen of the seed
## or "hide" leaves stragglers in view — but a realistic front is wider than six
## cells, so it is a knob.
var _cluster_px: float = 100.0
var _sprite_flames: bool = false
var _cold: bool = false
var _no_warmup: bool = false
var _compile_only: bool = false

var _map: Node = null
var _pathfinder: Pathfinder = null
var _fire: Node = null
var _cam: Camera2D = null

var _frames: int = 0
var _grid_stamp: int = 0
var _stable_since: int = 0
var _armed_at: int = -1
var _record_from: int = -1

var _times: PackedFloat32Array = PackedFloat32Array()
var _last_us: int = 0
var _notes: Dictionary = {}
var _burning_prev: int = 0

var _cluster: Array[Vector2i] = []
var _home: Vector2 = Vector2.ZERO
var _away: Vector2 = Vector2.ZERO


func _initialize() -> void:
	_parse_args()
	# Before ANY scene or autoload exists. FireShaderWarmup runs from
	# FireManager._ready, so a --cold applied later would invalidate exactly the
	# warm-up this tool is here to A/B.
	if _cold:
		_make_cold()
	if _no_warmup:
		Engine.set_meta(&"skip_fire_shader_warmup", true)


func _parse_args() -> void:
	var argv := OS.get_cmdline_user_args()
	var i: int = 0
	while i < argv.size():
		match argv[i]:
			"--scene": _scene_path = argv[i + 1]; i += 1
			"--fires": _fires = int(argv[i + 1]); i += 1
			"--record": _record = int(argv[i + 1]); i += 1
			"--settle": _settle = int(argv[i + 1]); i += 1
			"--offscreen": _offscreen_px = float(argv[i + 1]); i += 1
			"--cluster": _cluster_px = float(argv[i + 1]); i += 1
			"--sprite-flames": _sprite_flames = true
			"--cold": _cold = true
			"--no-warmup": _no_warmup = true
			"--compile-only": _compile_only = true
		i += 1


func _process(_delta: float) -> bool:
	_frames += 1
	if _compile_only:
		return _compile_only_step()
	if _frames == 1:
		if current_scene != null:
			current_scene.queue_free()
		DisplayServer.window_set_size(WINDOW_SIZE)
		# Without this every frame reads as the refresh interval and a 10 ms
		# hitch hides completely inside a 16.6 ms vsync slot.
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
		_map = load(_scene_path).instantiate()
		root.add_child(_map)
		return false

	if _armed_at < 0:
		if not _grid_settled():
			if _frames > 3000:
				push_error("profile_fire_reveal: the grid never settled.")
				quit(1)
				return true
			return false
		if not _arm():
			quit(1)
			return true
		_armed_at = _frames
		return false

	# Warm-up: let the world's own shaders (water, post-process, ambient) compile
	# and the driver clock ramp, so the only cold shaders left are the fire's.
	# Without this the recording opens with the world's own compile spikes in it.
	if _frames < _armed_at + _settle:
		return false

	if _record_from < 0:
		_record_from = _frames
		_last_us = Time.get_ticks_usec()
		# Placeholder so _times[k] is frame k for every k — the events are keyed
		# by frame index, and an array that started at 1 put every spike one row
		# away from the note that explained it. Index 0 is never measured and is
		# excluded from the stats below.
		_times.append(0.0)
		return false

	var idx: int = _frames - _record_from
	var now := Time.get_ticks_usec()
	_times.append(float(now - _last_us) / 1000.0)
	_last_us = now

	_run_script(idx)

	var burning: int = int(_fire.call(&"burning_count"))
	if burning != _burning_prev:
		_note(idx, "burning %d->%d" % [_burning_prev, burning])
		_burning_prev = burning

	if idx < _record:
		return false

	_report()
	quit(0)
	return true


# ----------------------------------------------------------------------------
# --compile-only
# ----------------------------------------------------------------------------

## Frames of empty window before the warm-up is spawned. Process start-up is
## noisy and would otherwise be charged to the compile.
const COMPILE_SETTLE: int = 60
## Frames timed after it is spawned. WARM_FRAMES of drawing plus room to see the
## frame time drop back to idle afterwards.
const COMPILE_RECORD: int = 20

var _compile_times: PackedFloat32Array = PackedFloat32Array()


func _compile_only_step() -> bool:
	if _frames == 1:
		if current_scene != null:
			current_scene.queue_free()
		DisplayServer.window_set_size(WINDOW_SIZE)
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
		return false
	if _frames < COMPILE_SETTLE:
		return false
	if _frames == COMPILE_SETTLE:
		root.add_child(FireShaderWarmup.new())
		_last_us = Time.get_ticks_usec()
		return false

	var now := Time.get_ticks_usec()
	_compile_times.append(float(now - _last_us) / 1000.0)
	_last_us = now
	if _compile_times.size() < COMPILE_RECORD:
		return false

	# The idle floor is the tail, after the warm-up has freed itself.
	var tail := _compile_times.slice(_compile_times.size() - 6)
	tail.sort()
	var floor_ms: float = tail[tail.size() / 2]
	var worst: float = 0.0
	for t: float in _compile_times:
		worst = maxf(worst, t)
	print("
=== profile_fire_reveal --compile-only (%s) ==="
			% ("COLD, real compile" if _cold else "warm, cached programs"))
	print("frames after the warm-up spawned, ms:")
	var row: Array[String] = []
	for t: float in _compile_times:
		row.append("%.2f" % t)
	print("  " + " ".join(row))
	print("idle floor %.2f ms, worst %.2f ms, excess %.2f ms"
			% [floor_ms, worst, worst - floor_ms])
	quit(0)
	return true


## The scripted events. Each runs AFTER this frame's time was banked, so its cost
## lands on frame idx+1 — which is why the report scans a window forward from
## each note rather than the noted frame itself.
func _run_script(idx: int) -> void:
	match idx:
		AT_IGNITE:
			var lit: int = 0
			for c: Vector2i in _cluster:
				if bool(_fire.call(&"ignite", c)):
					lit += 1
			_note(idx, "IGNITE off screen (%d/%d lit)" % [lit, _cluster.size()])
		AT_REVEAL:
			_cam.global_position = _home
			_note(idx, "REVEAL (camera onto fire)")
		AT_HIDE:
			_cam.global_position = _away
			_note(idx, "HIDE (camera off fire)")
		AT_REREVEAL:
			_cam.global_position = _home
			_note(idx, "RE-REVEAL (same fire, second time)")


## Guarantees the fire shaders compile FOR REAL on the reveal frame.
##
## Deleting .godot/shader_cache is not enough: the NVIDIA driver keeps its own
## program cache keyed by source, so a second run of this tool re-linked from
## that instead of compiling and the 17 ms spike vanished — measuring the warm
## path while claiming to measure the cold one. Appending a unique comment
## changes the source hash, which misses BOTH caches, so every --cold run pays
## what a player pays the first time they ever see fire.
##
## Mutates the shared preloaded Shader resources — fine in a throwaway tool
## process, never do this in game code.
func _make_cold() -> void:
	var stamp: int = Time.get_ticks_usec()
	var n: int = 0
	for path: String in [
		"res://assets/shaders/fire_blobs.gdshader",
		"res://assets/shaders/burn_dissolve.gdshader",
		"res://assets/shaders/burn_char.gdshader",
		"res://assets/shaders/fire.gdshader",
		"res://assets/shaders/fire_aura.gdshader",
	]:
		var sh := load(path) as Shader
		if sh == null:
			continue
		sh.code += "
// cold %d
" % (stamp + n)
		n += 1
	print("  --cold: %d fire shaders made unique, so neither Godot's cache nor" % n
			+ " the driver's can answer for them")


func _note(idx: int, text: String) -> void:
	var have: String = _notes.get(idx, "")
	_notes[idx] = text if have.is_empty() else have + " + " + text


# ----------------------------------------------------------------------------
# Setup
# ----------------------------------------------------------------------------

func _grid_settled() -> bool:
	_pathfinder = root.get_tree().get_first_node_in_group(&"pathfinder") as Pathfinder
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


func _arm() -> bool:
	_fire = root.get_node_or_null(^"/root/FireManager")
	if _fire == null:
		push_error("profile_fire_reveal: no FireManager autoload.")
		return false
	var seasons := root.get_node_or_null(^"/root/SeasonManager")
	if seasons != null:
		seasons.set(&"phase", 1)  # SeasonManager.Phase.ACTIVE
	var clock := root.get_node_or_null(^"/root/TimeManager")
	if clock != null:
		clock.set(&"paused", false)
		# Night: the fire lights are at full strength (see BurningCellVFX's
		# day/night dim ramp), so the PointLight2D path is actually exercised —
		# in daylight it dims to 8% and the lit shader variants might never be
		# needed at all.
		clock.set(&"time_of_day", 0.0)

	# The free camera is the only way to move the view without moving the
	# player, whose own camera smooths the snap over several frames and would
	# smear the reveal across them.
	_cam = _map.find_child("FreeCamera", true, false) as Camera2D
	if _cam == null:
		push_error("profile_fire_reveal: no FreeCamera in %s." % _scene_path)
		return false
	# Not `Debug.free_movement` — a --script SceneTree compiles before the
	# autoloads register their global identifiers, so naming one directly is a
	# compile error here. Fetch the node instead.
	var dbg := root.get_node_or_null(^"/root/Debug")
	if dbg == null:
		push_error("profile_fire_reveal: no Debug autoload.")
		return false
	dbg.set(&"free_movement", true)
	if _sprite_flames:
		dbg.set(&"fire_blob_flames", false)

	var player := _map.find_child("Player", true, false) as Node2D
	_away = _cam.global_position if player == null else player.global_position
	_cam.global_position = _away

	return _pick_cluster()


## The `_fires` ignitable cells nearest a seed that is itself at least
## `_offscreen_px` from the parked camera — a tight cluster, so one camera
## position reveals the whole thing at once and hiding it hides all of it.
func _pick_cluster() -> bool:
	var reach: Dictionary = _pathfinder.compute_reachable_set(
			_pathfinder.world_to_cell(_away))
	var ignitable: Array[Vector2i] = []
	var far: Array[Vector2i] = []
	var farthest: float = 0.0
	for c: Vector2i in reach.keys():
		var d: float = _pathfinder.cell_to_world(c).distance_to(_away)
		farthest = maxf(farthest, d)
		if not bool(_fire.call(&"can_ignite", c)):
			continue
		ignitable.append(c)
		if d >= _offscreen_px:
			far.append(c)
	print("profile_fire_reveal: %d reachable, %d ignitable, %d of those beyond %.0f px"
			% [reach.size(), ignitable.size(), far.size(), _offscreen_px]
			+ " (farthest reachable cell %.0f px)" % farthest)
	if far.is_empty():
		push_error("profile_fire_reveal: nothing ignitable is off screen."
				+ " Lower --offscreen or pick a bigger map.")
		return false

	# Seed on the FARTHEST ignitable cell, so the whole cluster around it clears
	# the off-screen threshold rather than straddling it.
	var seed_cell: Vector2i = far[0]
	for c: Vector2i in far:
		if _pathfinder.cell_to_world(c).distance_to(_away) \
				> _pathfinder.cell_to_world(seed_cell).distance_to(_away):
			seed_cell = c
	_home = _pathfinder.cell_to_world(seed_cell)
	far.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return _pathfinder.cell_to_world(a).distance_to(_home) \
				< _pathfinder.cell_to_world(b).distance_to(_home))
	_cluster.clear()
	for c: Vector2i in far:
		# Keep the cluster inside one screen of the seed, or "hide" would leave
		# stragglers in view.
		if _pathfinder.cell_to_world(c).distance_to(_home) > _cluster_px:
			break
		_cluster.append(c)
		if _cluster.size() >= _fires:
			break
	print("  cluster of %d around %s, %.0f px from the parked camera"
			% [_cluster.size(), seed_cell, _home.distance_to(_away)])
	return not _cluster.is_empty()


# ----------------------------------------------------------------------------
# Report
# ----------------------------------------------------------------------------

func _report() -> void:
	print("\n=== profile_fire_reveal: %s ===" % _scene_path)
	print("%d cells lit, %d frames recorded, flames=%s"
			% [_cluster.size(), _times.size(), "sprite" if _sprite_flames else "blob"])

	# Drop the unmeasured index-0 placeholder before any statistic.
	var sorted := _times.slice(1)
	sorted.sort()
	var n: int = sorted.size()
	print("\nframe time  median %.2f ms   p95 %.2f ms   p99 %.2f ms   worst %.2f ms"
			% [sorted[n / 2], sorted[int(n * 0.95)], sorted[int(n * 0.99)], sorted[n - 1]])

	var order: Array = []
	for i in range(1, _times.size()):
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool: return _times[a] > _times[b])
	print("\n20 worst frames:")
	for k in mini(20, order.size()):
		var i: int = order[k]
		var parts: Array[String] = []
		for d in range(-4, 5):
			var nt: String = _notes.get(i + d, "")
			if not nt.is_empty():
				parts.append("%+d %s" % [d, nt])
		print("  frame %4d   %8.2f ms   %s" % [i, _times[i], " | ".join(parts)])

	# The number the whole tool exists to produce: what each scripted event cost
	# over the frames that followed it, against a quiet median.
	var base: float = sorted[n / 2]
	print("\nevent                              worst in the 8 frames after it")
	for ev: Array in [
		[AT_IGNITE, "ignite (off screen)"],
		[AT_REVEAL, "REVEAL"],
		[AT_HIDE, "hide"],
		[AT_REREVEAL, "RE-REVEAL (same fire)"],
	]:
		var at: int = ev[0]
		var worst: float = 0.0
		for d in range(1, 10):
			if at + d < _times.size():
				worst = maxf(worst, _times[at + d])
		print("  %-32s %7.2f ms  (%.1fx median %.2f ms)"
				% [ev[1], worst, worst / maxf(base, 0.001), base])
