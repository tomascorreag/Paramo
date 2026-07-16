extends SceneTree
## Boots a scene with a rendering context, settles it past terrain generation and
## the title intro, and saves a screenshot of the final window framebuffer — so a
## structural change to the display pipeline (e.g. wrapping the world in a
## SubViewport) can be eyeballed without a human at the keyboard.
##
## Needs a rendering context — do NOT pass --headless.
##
##   ...console.exe --path . --script res://scripts/tools/screenshot_subpixel.gd \
##       -- --scene res://scenes/maps/level1.tscn --settle 700 --out /tmp/shot.png

const DEFAULT_SCENE := "res://scenes/maps/level1.tscn"

var _scene_path := DEFAULT_SCENE
var _settle := 700
var _out := ""
var _frame := 0


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("screenshot_subpixel needs a rendering context — drop --headless.")
		quit(1)
		return
	var argv := OS.get_cmdline_user_args()
	for i in argv.size() - 1:
		if argv[i] == "--scene":
			_scene_path = argv[i + 1]
		elif argv[i] == "--settle":
			_settle = int(argv[i + 1])
		elif argv[i] == "--out":
			_out = argv[i + 1]

	_install_autoloads()
	var packed := load(_scene_path) as PackedScene
	if packed == null:
		push_error("could not load %s" % _scene_path)
		quit(1)
		return
	root.add_child(packed.instantiate())
	print("screenshot: %s (settle %d frames)" % [_scene_path, _settle])


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
		if root.has_node(NodePath(entry[0])):
			continue
		var scr := load(entry[1]) as Script
		if scr == null:
			continue
		var node := Node.new()
		node.set_script(scr)
		node.name = entry[0]
		root.add_child(node)


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < _settle:
		return false
	var img := root.get_texture().get_image()
	if _out != "":
		img.save_png(_out)
		print("  saved %s (%dx%d)" % [_out, img.get_width(), img.get_height()])
	quit(0)
	return true
