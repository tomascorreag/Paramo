extends SceneTree
## Frame-cost profiler for a gameplay scene.
##
## Loads a scene, lets it settle, then samples over a fixed window. Use to get
## REAL draw-call / node-count / frame-time numbers instead of estimating them
## from the source.
##
## Needs a rendering context — do NOT pass --headless (draw calls are always 0
## under the headless driver, which silently makes every result meaningless).
##
## Two traps this tool exists to avoid, both of which produced nonsense here
## before they were understood:
##
##  1. TIME_PROCESS / TIME_PHYSICS_PROCESS / TIME_FPS are published ONCE PER
##     SECOND, and the two time monitors are the MAX frame of that second, not
##     the mean (Main::iteration keeps process_max = MAX(process_max, ticks)).
##     Sampling them per-frame yields the same value ~200x in a row, and the max
##     exceeds the median frame time, so "% of frame" from them is meaningless.
##     Frame time here is therefore measured by wall clock, and the monitors are
##     reported only as spike detectors.
##  2. This project paints terrain across frames, so a short settle blends the
##     generation spike into the gameplay median. 600 frames was measured as the
##     point level1 reaches steady state; the report warns if it still drifted.
##
## The absolute ms is for this GPU at this window size. What transfers is the
## RATIO between two runs (before/after a change) and the DRAW CALL COUNT, which
## is hardware-independent and is usually the number that matters on web. To
## attribute cost to a system, A/B it: disable it and re-run.
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/profile_scene.gd \
##       -- --scene res://scenes/maps/level1.tscn --frames 600

const DEFAULT_SCENE := "res://scenes/maps/level1.tscn"
const DEFAULT_SETTLE := 600
const DEFAULT_FRAMES := 600

var _scene_path: String = DEFAULT_SCENE
var _frames: int = DEFAULT_FRAMES
var _frame: int = 0
var _settle: int = DEFAULT_SETTLE
var _last_usec: int = 0
var _samples: Dictionary = {}

# Monitors sampled every frame. Names verified against this project's existing
# usage (scripts/systems/tile_debug_overlay.gd:234-235).
const MONITORS := {
	"fps": Performance.TIME_FPS,
	"process_ms": Performance.TIME_PROCESS,
	"physics_ms": Performance.TIME_PHYSICS_PROCESS,
	"draw_calls": Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME,
	"objects_drawn": Performance.RENDER_TOTAL_OBJECTS_IN_FRAME,
	"primitives": Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME,
	"nodes": Performance.OBJECT_NODE_COUNT,
	"orphan_nodes": Performance.OBJECT_ORPHAN_NODE_COUNT,
	"video_mem_mb": Performance.RENDER_VIDEO_MEM_USED,
}


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("profile_scene needs a rendering context (draw calls read 0 "
			+ "under headless). Drop --headless.")
		quit(1)
		return

	var argv := OS.get_cmdline_user_args()
	for i in argv.size() - 1:
		if argv[i] == "--scene":
			_scene_path = argv[i + 1]
		elif argv[i] == "--frames":
			_frames = int(argv[i + 1])
		elif argv[i] == "--settle":
			_settle = int(argv[i + 1])

	var packed := load(_scene_path) as PackedScene
	if packed == null:
		push_error("Could not load scene at %s" % _scene_path)
		quit(1)
		return

	# Autoloads are NOT installed when the main loop is replaced via --script,
	# so any scene touching TimeManager/FireManager/etc would crash on _ready.
	# Install them by hand, in the project.godot order (later ones may reference
	# earlier ones). Verified present/absent at runtime rather than assumed.
	_install_autoloads()

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	var inst := packed.instantiate()
	root.add_child(inst)

	for key: String in MONITORS:
		# Array, NOT PackedFloat64Array: Packed*Array has VALUE semantics in
		# GDScript, so `_samples[key].append(x)` would append to a temporary copy
		# and silently discard every sample. Array is reference-counted.
		_samples[key] = [] as Array[float]
	_samples["frame_ms"] = [] as Array[float]

	print("scene profile")
	print("  scene:   %s" % _scene_path)
	print("  device:  %s" % RenderingServer.get_video_adapter_name())
	print("  window:  %s" % str(DisplayServer.window_get_size()))
	print("  settle:  %d frames, then %d timed frames" % [_settle, _frames])
	print("")


func _install_autoloads() -> void:
	var order: Array[Array] = [
		["DisplayManager", "res://scripts/systems/display_manager.gd"],
		["TimeManager", "res://scripts/systems/time_manager.gd"],
		["Debug", "res://scripts/systems/debug.gd"],
		["FireManager", "res://scripts/systems/fire_manager.gd"],
		["ResourceLedger", "res://scripts/systems/resource_ledger.gd"],
		["SeasonManager", "res://scripts/systems/season_manager.gd"],
	]
	for entry in order:
		var name_: String = entry[0]
		if root.has_node(NodePath(name_)):
			continue  # already installed by the engine — don't double-add
		var scr := load(entry[1]) as Script
		if scr == null:
			push_warning("autoload %s: could not load %s" % [name_, entry[1]])
			continue
		var node := Node.new()
		node.set_script(scr)
		node.name = name_
		root.add_child(node)


func _process(_delta: float) -> bool:
	_frame += 1
	# Wall-clock frame time, measured here rather than read from TIME_FPS: the
	# FPS monitor is smoothed, so it disagrees with the (unsmoothed) TIME_PROCESS
	# monitor and the two cannot honestly be combined into a percentage.
	var now := Time.get_ticks_usec()
	var dt_ms := 0.0
	if _last_usec != 0:
		dt_ms = float(now - _last_usec) / 1000.0
	_last_usec = now

	if _frame <= _settle:
		return false
	if dt_ms > 0.0:
		(_samples["frame_ms"] as Array).append(dt_ms)
	for key: String in MONITORS:
		(_samples[key] as Array).append(Performance.get_monitor(MONITORS[key]))
	if _frame < _settle + _frames:
		return false
	_report()
	return true


func _pct(a: Array, p: float) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	return float(s[clampi(int(p * float(s.size())), 0, s.size() - 1)])


# The scene must reach steady state before the numbers mean anything: this
# project paints terrain across frames (ProceduralWorld.regenerate_async), so a
# sampling window that opens too early mixes the generation spike with gameplay
# and produces a median that describes neither. Compare the first and last
# quarter of the window; if they disagree the window was too early, and the
# report says so instead of quietly reporting a blended number.
func _drifted(a: Array) -> bool:
	if a.size() < 8:
		return false
	var q := a.size() / 4
	var head := 0.0
	var tail := 0.0
	for i in q:
		head += float(a[i])
		tail += float(a[a.size() - 1 - i])
	head /= float(q)
	tail /= float(q)
	return absf(head - tail) > 0.25 * maxf(head, tail)


func _report() -> void:
	var frame := _samples["frame_ms"] as Array
	var proc := _samples["process_ms"] as Array
	var phys := _samples["physics_ms"] as Array
	var f_med := _pct(frame, 0.5)
	# TIME_PROCESS / TIME_PHYSICS_PROCESS are reported in seconds.
	var proc_ms := _pct(proc, 0.5) * 1000.0
	var phys_ms := _pct(phys, 0.5) * 1000.0

	print("  --- frame time (wall clock, measured here) ---")
	print("  median %7.3f ms  (%.0f fps)   p95 %7.3f ms   worst %7.3f ms"
		% [f_med, 1000.0 / maxf(f_med, 0.0001), _pct(frame, 0.95), _pct(frame, 1.0)])
	print("")
	# TIME_PROCESS / TIME_PHYSICS_PROCESS are NOT averages: Main::iteration
	# accumulates process_max = MAX(process_max, process_ticks) and publishes it
	# once per second. So each is the WORST frame of its second, and legitimately
	# exceeds the median frame time above. They are spike detectors — do not
	# express them as a percentage of a median frame, and do not subtract them
	# from it to "derive" GPU time. To attribute steady-state cost, A/B it:
	# disable a system and re-measure the wall-clock median.
	print("  --- worst-frame spikes (1 s max, NOT an average) ---")
	print("  _process  worst-in-second %7.3f ms" % proc_ms)
	print("  _physics  worst-in-second %7.3f ms" % phys_ms)
	if _drifted(frame):
		print("")
		print("  !! NOT AT STEADY STATE: cost drifted >25%% between the start and")
		print("     end of the window. The scene was probably still generating or")
		print("     painting. Re-run with a larger --settle; these medians blend")
		print("     two regimes and should not be quoted.")
	print("")
	print("  --- rendering (hardware-independent — these transfer to web) ---")
	print("  draw calls         %8d" % int(_pct(_samples["draw_calls"], 0.5)))
	print("  objects drawn      %8d" % int(_pct(_samples["objects_drawn"], 0.5)))
	print("  primitives         %8d" % int(_pct(_samples["primitives"], 0.5)))
	print("  video mem          %8.1f MB"
		% (_pct(_samples["video_mem_mb"], 0.5) / 1048576.0))
	print("")
	print("  --- scene tree ---")
	print("  nodes              %8d" % int(_pct(_samples["nodes"], 0.5)))
	print("  orphan nodes       %8d" % int(_pct(_samples["orphan_nodes"], 0.5)))
	quit(0)
