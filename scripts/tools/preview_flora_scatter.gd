extends SceneTree
## Renders one ecosystem's natural flora on the real map: generates level1
## with the chosen EcosystemProfile pinned, strips the atmosphere, aims the
## camera at the densest stand of plants and saves a still at 1:1 and 2x
## NEAREST. The numbers (report_flora_scatter.gd) say WHERE each species
## lands; this is the only way to see whether it READS — whether a chuscal
## looks like a bamboo thicket in a wet valley, whether a shrub row sits on
## the cube top or floats, whether the y-sort holds when a frailejón stands
## behind a tussock.
##
## What to look for:
##   - Every sprite must stand ON its cell. The scene's Sprite2D offset was
##     tuned for row 0 of ISO_Plants.png; a species whose art has a different
##     ground line sinks or floats by the difference (measured bottom rows:
##     frailejón 25, hartwegiana 27, barclayana 24, arcytophyllum 23).
##   - Ground cover must NOT cast a shadow (casts_shadow = false) — a tussock
##     with a teardrop under it reads as a boulder.
##   - Patches must read as stands, not stripes: a species that lines up along
##     a diagonal is noise frequency aliasing on the grid.
##
## Also prints the spawned count per species and how many shadows were made,
## which is the cheapest cross-check of casts_shadow there is.
##
## Needs a rendering context — do NOT pass --headless.
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/preview_flora_scatter.gd -- --ecosystem nevados
##
## Args:
##   --out <dir>         output directory (default: user://)
##   --scene <res>       map to build on (default: level1)
##   --ecosystem <id>    chingaza | guerrero | nevados (default: the map's own)
##   --seed <n>          terrain seed (default: the map's own)

const DEFAULT_SCENE := "res://scenes/maps/level1.tscn"

const WINDOW_SIZE := Vector2i(960, 540)
const PIXEL_SCALE := 2
const CROP_SIZE := Vector2i(480, 300)
const SETTLE_FRAMES: int = 30
const GENERATION_TIMEOUT_FRAMES: int = 6000
const RENDER_FRAMES: int = 6
## Cells around a plant that count toward "densest stand".
const STAND_RADIUS: int = 5

const PROCEDURAL_WORLD_GROUP: StringName = &"procedural_world"
const PROCEDURAL_GROUP: StringName = &"procedural_object"

var _out_dir: String = "user://"
var _scene_path: String = DEFAULT_SCENE
var _ecosystem: StringName = &""
var _seed: int = -1
var _frames: int = 0
var _map: Node
var _pathfinder: Pathfinder
var _ready_to_shoot: bool = false
var _generation_done: bool = false
var _generation_hooked: bool = false
var _label: String = "flora"


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("preview_flora_scatter needs a rendering context. Drop --headless.")
		quit(1)
		return

	var argv := OS.get_cmdline_user_args()
	for i in argv.size():
		match argv[i]:
			"--out":
				if i + 1 < argv.size(): _out_dir = argv[i + 1]
			"--scene":
				if i + 1 < argv.size(): _scene_path = argv[i + 1]
			"--ecosystem":
				if i + 1 < argv.size(): _ecosystem = StringName(argv[i + 1])
			"--seed":
				if i + 1 < argv.size(): _seed = int(argv[i + 1])
	if not _out_dir.ends_with("/"):
		_out_dir += "/"
	DirAccess.make_dir_recursive_absolute(_out_dir)

	DisplayServer.window_set_size(WINDOW_SIZE)
	if current_scene != null:
		current_scene.queue_free()
	_map = load(_scene_path).instantiate()
	# The ProceduralWorld generates in its _ready, i.e. at add_child below, so
	# the overrides have to be poked into the instanced-but-not-yet-ready tree.
	var pw := _map.find_child("ProceduralWorld", true, false)
	if pw != null:
		if _ecosystem != &"":
			pw.set("ecosystem_override", _ecosystem)
		if _seed >= 0:
			pw.set("seed_override", _seed)
			pw.set("randomize_seed_on_ready", false)
	root.add_child(_map)


func _world_ready() -> bool:
	if _generation_done:
		return true
	var pw := root.get_tree().get_first_node_in_group(PROCEDURAL_WORLD_GROUP)
	if pw == null:
		return _frames >= SETTLE_FRAMES
	if not _generation_hooked and pw.has_signal(&"generation_finished"):
		pw.connect(&"generation_finished", func() -> void: _generation_done = true)
		_generation_hooked = true
	return false


# Same list as preview_grass_wear: everything that tints the ground.
func _strip_atmosphere() -> void:
	for path: String in [
		"TitleIntro", "RainLayer", "PostProcessLayer", "HUD", "FireAuraLayer",
		"PauseMenu", "FieldJournal", "BackgroundLayer", "UXOverlay",
	]:
		var n := _map.find_child(path, true, false)
		if n != null:
			n.set("visible", false)
	for path: String in ["DayNightController", "AltitudeFogController"]:
		var n := _map.find_child(path, true, false)
		if n != null:
			n.free()
	for node in _map.find_children("*", "CanvasModulate", true, false):
		(node as CanvasModulate).color = Color.WHITE
	for node in _map.find_children("*", "TileMapLayer", true, false):
		(node as TileMapLayer).modulate = Color.WHITE
	for node in root.find_children("*", "LoadingOverlay", true, false):
		node.free()
	for path: String in ["Player", "VFXContainer"]:
		var n := _map.find_child(path, true, false)
		if n is CanvasItem:
			(n as CanvasItem).visible = false


func _process(_delta: float) -> bool:
	_frames += 1
	if not _ready_to_shoot:
		if not _world_ready():
			if _frames > GENERATION_TIMEOUT_FRAMES:
				push_error("preview_flora_scatter: the map never finished generating.")
				quit(1)
				return true
			return false
		_strip_atmosphere()
		_pathfinder = root.get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
		var pw := root.get_tree().get_first_node_in_group(PROCEDURAL_WORLD_GROUP)
		var eco: Variant = pw.get("ecosystem") if pw != null else null
		_label = String(eco.id) if eco != null else "flora"
		var focus := _census_and_focus()
		if focus == Pathfinder.NO_CELL:
			push_error("preview_flora_scatter: no plants on this map.")
			quit(1)
			return true
		_aim_camera(focus)
		_ready_to_shoot = true
		_frames = 0
		return false
	if _frames % RENDER_FRAMES != 0:
		return false
	_save()
	quit(0)
	return true


# Prints the spawned count per species (+ shadows) and returns the cell of the
# plant with the most plants within STAND_RADIUS — the densest stand.
func _census_and_focus() -> Vector2i:
	var counts: Dictionary = {}
	var cells: Array[Vector2i] = []
	for n in root.get_tree().get_nodes_in_group(PROCEDURAL_GROUP):
		if not (n is Frailejon):
			continue
		var kind: StringName = (n as Frailejon).occupant_kind()
		counts[kind] = counts.get(kind, 0) + 1
		cells.append((n as Frailejon).cell)
	var shadows: int = root.get_tree().get_nodes_in_group(&"shadow").size()
	print("preview_flora_scatter [%s]: %d plants, %d shadows in the scene" % [_label, cells.size(), shadows])
	var keys: Array = counts.keys()
	keys.sort_custom(func(a, b): return counts[a] > counts[b])
	for k in keys:
		print("  %-24s %d" % [k, counts[k]])
	if cells.is_empty():
		return Pathfinder.NO_CELL
	var best := cells[0]
	var best_n: int = -1
	for c in cells:
		var n: int = 0
		for o in cells:
			if absi(o.x - c.x) <= STAND_RADIUS and absi(o.y - c.y) <= STAND_RADIUS:
				n += 1
		if n > best_n:
			best_n = n
			best = c
	print("  focus: cell %s (%d plants within %d)" % [best, best_n, STAND_RADIUS])
	return best


func _aim_camera(cell: Vector2i) -> void:
	var cam := _find_camera(root)
	if cam == null or _pathfinder == null:
		push_warning("preview_flora_scatter: no current Camera2D — framing is the map's.")
		return
	var tile = _pathfinder.grid().get_tile(cell)
	var alt: int = tile.altitude_low if tile != null else 0
	cam.position_smoothing_enabled = false
	cam.global_position = _pathfinder.cell_to_world(cell) \
			+ Vector2(0.0, -alt * Pathfinder.HALF_STEP_PX)


func _find_camera(node: Node) -> Camera2D:
	if node is Camera2D and (node as Camera2D).is_current():
		return node as Camera2D
	for child in node.get_children():
		var found := _find_camera(child)
		if found != null:
			return found
	return null


func _save() -> void:
	var img := root.get_texture().get_image()
	img.save_png("%sflora_%s.png" % [_out_dir, _label])
	var crop := Rect2i(
		(img.get_width() - CROP_SIZE.x) / 2, (img.get_height() - CROP_SIZE.y) / 2,
		CROP_SIZE.x, CROP_SIZE.y
	)
	var sub := img.get_region(crop)
	var big := Image.create(
		sub.get_width() * PIXEL_SCALE, sub.get_height() * PIXEL_SCALE, false, sub.get_format())
	for y in big.get_height():
		for x in big.get_width():
			big.set_pixel(x, y, sub.get_pixel(x / PIXEL_SCALE, y / PIXEL_SCALE))
	big.save_png("%sflora_%s@%dx.png" % [_out_dir, _label, PIXEL_SCALE])
	print("preview_flora_scatter: wrote flora_%s.png (+@%dx)" % [_label, PIXEL_SCALE])
