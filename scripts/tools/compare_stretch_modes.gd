extends SceneTree
## Side-by-side capture of DisplayConfig.stretch_mode: CANVAS_ITEMS (rasterize at
## window res) vs VIEWPORT (rasterize into the window/N framebuffer, upscale by N).
##
## Why this exists: the two modes are IDENTICAL in framing — both cameras are at
## zoom 1, so content_scale_size is window/N either way and the same world is on
## screen. The only difference is rasterization resolution, which you cannot read
## off the source and cannot see in the editor. Rendering it is the only way to
## judge it.
##
## Needs a rendering context — do NOT pass --headless (you would capture nothing).
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##     --path . --script res://scripts/tools/compare_stretch_modes.gd -- --out /tmp/stretch
##
## Args: --scene <path> (default level1), --out <dir>, --settle <frames>.
##
## WHAT THIS TOOL CANNOT TELL YOU — read before drawing conclusions:
##
##  1. It cannot decide the aesthetic. The deciding artifact under VIEWPORT is
##     pixel CRAWL: Player/Camera2D has position_smoothing_enabled (speed 1.0), so
##     it rests on fractional positions by construction, and a low-res grid
##     resamples them differently every frame. Crawl only exists in MOTION. These
##     are still frames and are blind to it. Judge that in-game via the debug
##     overlay's "Pixel Grid" toggle, panning.
##  2. It cannot tell you the perf win. Desktop cannot resolve this project's
##     canvas fill at all (benchmark_fire.gd measured an 80-cell worst case AT the
##     noise floor on a 3080, and deltas there invert). VIEWPORT's saving is
##     exactly N**2 fewer fragments on the fullscreen passes — an arithmetic fact,
##     not something to re-measure here. Whether that matters is a question for
##     the WEB build.
##
## What it IS good for: confirming the modes agree on framing, and seeing what the
## pixel grid does to the shaders (rain/fire) and the 8px UI on a still frame.

const AUTOLOADS: Array[Array] = [
	["DisplayManager", "res://scripts/systems/display_manager.gd"],
	["TimeManager", "res://scripts/systems/time_manager.gd"],
	["Debug", "res://scripts/systems/debug.gd"],
	["FireManager", "res://scripts/systems/fire_manager.gd"],
	["ResourceLedger", "res://scripts/systems/resource_ledger.gd"],
	["SeasonManager", "res://scripts/systems/season_manager.gd"],
]

var _scene_path: String = "res://scenes/maps/level1.tscn"
var _out_dir: String = "user://stretch_compare"
var _settle: int = 600


func _init() -> void:
	_parse_args()
	_run.call_deferred()


func _parse_args() -> void:
	var argv := OS.get_cmdline_user_args()
	var i := 0
	while i < argv.size():
		match argv[i]:
			"--scene":
				i += 1
				if i < argv.size():
					_scene_path = argv[i]
			"--out":
				i += 1
				if i < argv.size():
					_out_dir = argv[i]
			"--settle":
				i += 1
				if i < argv.size():
					_settle = int(argv[i])
		i += 1


func _install_autoloads() -> void:
	for entry in AUTOLOADS:
		var name_: String = entry[0]
		if root.has_node(NodePath(name_)):
			continue
		var scr := load(entry[1]) as Script
		if scr == null:
			push_warning("autoload %s: could not load %s" % [name_, entry[1]])
			continue
		var node := Node.new()
		node.set_script(scr)
		node.name = name_
		root.add_child(node)


func _run() -> void:
	var packed := load(_scene_path) as PackedScene
	if packed == null:
		push_error("Could not load scene at %s" % _scene_path)
		quit(1)
		return

	_install_autoloads()
	await process_frame
	# Fetched as a plain Node, never as the `DisplayManager` identifier: autoloads
	# are not registered under --script, so naming it would fail to COMPILE, before
	# _install_autoloads ever runs.
	var display: Node = root.get_node_or_null(^"DisplayManager")
	if display == null:
		push_error("DisplayManager autoload did not install")
		quit(1)
		return

	DirAccess.make_dir_recursive_absolute(_out_dir)
	root.add_child(packed.instantiate())

	# Terrain paints across frames; capturing early photographs the generation
	# spike rather than the game (same reason profile_scene.gd settles 600).
	for i in _settle:
		await process_frame

	var win: Window = root
	print("stretch mode compare")
	print("  scene:  %s" % _scene_path)
	print("  device: %s" % RenderingServer.get_video_adapter_name())
	print("  window: %s   N=%d   content_scale_size=%s" % [
		str(win.size), display.current_scale, str(win.content_scale_size)
	])
	print("")

	for mode: int in [Window.CONTENT_SCALE_MODE_CANVAS_ITEMS, Window.CONTENT_SCALE_MODE_VIEWPORT]:
		display.set_stretch_mode(mode as Window.ContentScaleMode)
		for i in 5:
			await process_frame
		var img: Image = win.get_texture().get_image()
		var label := "viewport" if mode == Window.CONTENT_SCALE_MODE_VIEWPORT else "canvas_items"
		var path := "%s/%s.png" % [_out_dir, label]
		img.save_png(path)
		print("  %-12s framebuffer %-11s upscale %s -> %s" % [
			label, str(img.get_size()), str(win.get_final_transform().get_scale()), path
		])

	print("")
	print("  Both PNGs are the backing framebuffer, so they differ in SIZE:")
	print("  canvas_items is window-res, viewport is window/N. Scale the small one")
	print("  up by N with NEAREST to compare like for like — that upscale is")
	print("  exactly what the engine does to put it on screen.")
	quit()
