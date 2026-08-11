extends SceneTree
## Looks at the recoloured visitors — the crowd as a contact sheet, and
## optionally a real map with visitors walking on it.
##
## The shipped sheet (assets/sprites/characters/Visitor_1_general.png) is an
## INDEX, not a picture: opened in any image viewer it is a near-black
## silhouette. So there is no way to see what the art plus
## resources/characters/visitor_palette.tres actually produce except to render
## it, which is what this does.
##
## Two phases, and they answer different questions:
##
##   default   a grid of rolled variants, each shown in all four facings on the
##             palette's darkest bed. This is where the WARDROBE is judged: do
##             skin tones still read as skin across the roll, do the fabric
##             ramps hold their hue, does the darkest-base variant read as
##             flat-shaded rather than broken, do two neighbours ever come out
##             so similar that the crowd looks cloned.
##   --world   a real map with a crowd walking on it. This is where the RIG is
##             judged: y-sorting against terrain and against each other, the
##             shadow, the walk cycle, and whether the derived entry cell is
##             somewhere sensible. It prints the entry and each goal.
##
## Needs a rendering context — do NOT pass --headless.
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/preview_visitor_palettes.gd -- --out /tmp/visitors
##
## Args:
##   --out <dir>     output directory (default: user://)
##   --variants <n>  how many to roll for the contact sheet (default 12)
##   --seed <n>      RNG seed (default 20260808)
##   --world         also render a crowd on a map
##   --scene <res>   map for --world (default: level1)
##   --count <n>     crowd size for --world (default 6)
##   --frames <n>    frames of walking before the --world still (default 200).
##                   200 shows a crowd leaving the entry; route noise, breathers
##                   and group spacing need ~1500 to be legible.
##   --groups        keep the spawner's own stagger instead of bursting the
##                   crowd in at once, so parties arrive as parties
##   --trample <r>   override RegrowthManager.trample_per_step for the run.
##                   At the shipped 0.06 a cell needs ~15 crossings to go bare,
##                   which is days of game time — far past what any still can
##                   show. Crank it (0.3+) to see WHERE the traffic concentrates
##                   in one render; the shape is the answer, not the rate.
##
## In --world the tool forces SeasonManager into ACTIVE and zeroes the
## spawner's stagger. Both gates are real gameplay behaviour (nobody visits a
## paused mountain, and a day's arrivals trickle in over minutes) and both would
## otherwise make this tool render an empty map.

const SHEET := "res://assets/sprites/characters/Visitor_1_general.png"
const PALETTE := "res://resources/characters/visitor_palette.tres"
const SHADER := "res://assets/shaders/visitor_recolor.gdshader"
const DEFAULT_SCENE := "res://scenes/maps/level1.tscn"

const FRAME := Vector2i(32, 32)
const FACINGS: int = 4
const FRAMES_PER_DIR: int = 6
const PAD: int = 6
const COLUMNS: int = 3
const UPSCALE: int = 4

const WINDOW_SIZE := Vector2i(960, 540)
## A procedural map generates and PAINTS across many frames, rebuilding the
## pathfinder graph as it goes, and VisitorSpawner treats a fresh TileGrid as
## "the world was replaced" and sends its crowd home — correctly. So the tool
## waits for the grid to stop changing rather than for a fixed frame count,
## which is also what makes it work on a handcrafted map (settles immediately)
## and on level1 (does not) with the same number.
const GRID_STABLE_FRAMES: int = 90
const MIN_SETTLE_FRAMES: int = 60
## Long enough for a spawned visitor to clear the entry cell and be walking, so
## the still shows a crowd in motion rather than a stack on one tile. Route
## noise and breathers need considerably longer to read — that is what --frames
## is for.
const WALK_FRAMES: int = 200

var _out_dir: String = "user://"
var _variants: int = 12
var _seed: int = 20260808
var _world: bool = false
var _scene_path: String = DEFAULT_SCENE
var _count: int = 6
var _walk_frames: int = WALK_FRAMES
## Force the arrivals through in one burst (the default: a contact sheet of the
## WARDROBE wants everyone on screen). Cleared by --groups, which leaves the
## spawner's own stagger alone so parties arrive as parties.
var _burst: bool = true
## Negative = leave RegrowthManager's own rate alone.
var _trample: float = -1.0
var _regrowth: Node = null

var _palette: VisitorPalette
var _rng := RandomNumberGenerator.new()
var _vp: SubViewport
var _frames: int = 0
var _stage: int = 0
var _map: Node
var _walk_until: int = 0
var _grid_stamp: int = 0
var _stable_since: int = 0
## Typed as Node, not VisitorSpawner, on purpose: a static reference would make
## visitor_spawner.gd a compile-time dependency of this file, and that script
## names the TimeManager / SeasonManager autoloads — which do not resolve while
## a --script tool compiles. Duck-typing keeps the dependency to runtime, where
## the autoloads exist.
var _spawner: Node


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("preview_visitor_palettes needs a rendering context. Drop --headless.")
		quit(1)
		return

	var argv := OS.get_cmdline_user_args()
	for i in argv.size():
		match argv[i]:
			"--out":
				if i + 1 < argv.size(): _out_dir = argv[i + 1]
			"--variants":
				if i + 1 < argv.size(): _variants = maxi(1, int(argv[i + 1]))
			"--seed":
				if i + 1 < argv.size(): _seed = int(argv[i + 1])
			"--scene":
				if i + 1 < argv.size(): _scene_path = argv[i + 1]
			"--count":
				if i + 1 < argv.size(): _count = maxi(1, int(argv[i + 1]))
			"--frames":
				if i + 1 < argv.size(): _walk_frames = maxi(1, int(argv[i + 1]))
			"--groups":
				_burst = false
			"--trample":
				if i + 1 < argv.size(): _trample = float(argv[i + 1])
			"--world":
				_world = true
	if not _out_dir.ends_with("/"):
		_out_dir += "/"
	DirAccess.make_dir_recursive_absolute(_out_dir)

	_palette = load(PALETTE) as VisitorPalette
	if _palette == null:
		push_error("could not load %s" % PALETTE)
		quit(1)
		return
	_rng.seed = _seed

	if current_scene != null:
		current_scene.queue_free()

	if _world:
		DisplayServer.window_set_size(WINDOW_SIZE)
		_map = load(_scene_path).instantiate()
		root.add_child(_map)
	else:
		_build_contact_sheet()


func _process(_delta: float) -> bool:
	_frames += 1
	if not _world:
		# Two frames for the SubViewport to draw, then grab and go.
		if _frames < 3:
			return false
		_save(_vp.get_texture().get_image(), "variants")
		quit(0)
		return true

	if _spawner == null:
		if not _grid_settled():
			if _frames > 3000:
				push_error("preview_visitor_palettes: the grid never settled.")
				quit(1)
				return true
			return false
		_strip_atmosphere()
		if not _start_crowd():
			quit(1)
			return true
		_walk_until = _frames + _walk_frames
		return false
	if _frames < _walk_until:
		return false
	if _frames == _walk_until:
		# Aim last, then let a frame draw: the camera follows the PLAYER, who is
		# nowhere near the trailhead, so a capture without this is a screenshot
		# of empty mountain.
		_aim_at_crowd()
		return false
	_report_crowd()
	var vp: Viewport = root.find_child("WorldViewport", true, false) as Viewport
	_save((vp if vp != null else root).get_texture().get_image(), "world")
	quit(0)
	return true


# ----------------------------------------------------------------------------
# Contact sheet
# ----------------------------------------------------------------------------

func _build_contact_sheet() -> void:
	var tex: Texture2D = load(SHEET)
	var shader: Shader = load(SHADER)
	var rows: int = int(ceilf(float(_variants) / float(COLUMNS)))
	var cell := Vector2i(FRAME.x * FACINGS, FRAME.y)
	var size := Vector2i(
		COLUMNS * (cell.x + PAD) + PAD,
		rows * (cell.y + PAD) + PAD)

	_vp = SubViewport.new()
	_vp.size = size
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.disable_3d = true
	_vp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	root.add_child(_vp)

	# The darkest palette entry, matching the bed preview_fire_blobs.gd uses:
	# these sprites are seen against night-tinted ground, and a white page makes
	# every dark ramp look like a silhouette.
	var bed := ColorRect.new()
	bed.color = Palette.P30
	bed.size = Vector2(size)
	_vp.add_child(bed)

	for v in _variants:
		var choices := VisitorAppearance.roll(_palette, _rng)
		var colors := VisitorAppearance.resolve(_palette, choices)
		var col: int = v % COLUMNS
		var row: int = v / COLUMNS
		var origin := Vector2(
			float(PAD + col * (cell.x + PAD)),
			float(PAD + row * (cell.y + PAD)))
		# One material per variant — sharing one would make every visitor on the
		# sheet take the last roll, the same trap visitor.tscn's
		# resource_local_to_scene avoids at runtime.
		var mat := ShaderMaterial.new()
		mat.shader = shader
		VisitorAppearance.apply(mat, colors)
		for facing in FACINGS:
			var s := Sprite2D.new()
			s.texture = tex
			s.hframes = FACINGS * FRAMES_PER_DIR
			s.frame = facing * FRAMES_PER_DIR
			s.centered = false
			s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			s.material = mat
			s.position = origin + Vector2(float(facing * FRAME.x), 0.0)
			_vp.add_child(s)
		print("%2d  %s" % [v, _describe(choices)])


func _describe(choices: Array) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for slot in VisitorSlots.SLOT_COUNT:
		var ramps := _palette.slot_ramps(slot)
		var pick: Array = choices[slot]
		var label: String = "?" if pick[0] < 0 or pick[0] >= ramps.size() \
				else String(ramps[pick[0]].name)
		parts.append("%s=%s@%d" % [VisitorSlots.slot_name(slot), label, pick[1]])
	return " ".join(parts)


# ----------------------------------------------------------------------------
# World
# ----------------------------------------------------------------------------

# Same atmospheric strip preview_fence.gd does, and for the same reason: the
# night modulate and the fog tint every sprite on screen, which is exactly what
# a tool for judging colour must not have happening.
func _strip_atmosphere() -> void:
	for path: String in [
		"TitleIntro", "RainLayer", "PostProcessLayer", "HUD", "FireAuraLayer",
		"PauseMenu", "FieldJournal", "BackgroundLayer",
	]:
		var n := _map.find_child(path, false, false)
		if n != null:
			n.set("visible", false)
	for path: String in ["DayNightController", "AltitudeFogController"]:
		var n := _map.find_child(path, false, false)
		if n != null:
			n.free()
	for node in _map.find_children("*", "CanvasModulate", true, false):
		(node as CanvasModulate).color = Color.WHITE
	for node in _map.find_children("*", "TileMapLayer", true, false):
		(node as TileMapLayer).modulate = Color.WHITE


## True once the pathfinder has held the same TileGrid instance for
## GRID_STABLE_FRAMES — i.e. generation and painting are done rebuilding it.
func _grid_settled() -> bool:
	var pf := root.get_tree().get_first_node_in_group(&"pathfinder")
	if pf == null:
		return false
	var grid: Object = pf.call(&"grid")
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
		push_error("preview_visitor_palettes: no VisitorSpawner in %s." % _scene_path)
		return false
	# Both are real gameplay gates, forced open for the tool — see the header.
	# Reached through the node tree, not by name: under --script the autoloads
	# are not registered as global identifiers when this file compiles, so
	# `SeasonManager.phase` here is a compile error (it is fine inside gameplay
	# scripts, which compile later, as part of loading the scene).
	var seasons := root.get_node_or_null(^"/root/SeasonManager")
	if seasons != null:
		seasons.set(&"phase", 1)  # SeasonManager.Phase.ACTIVE
	var clock := root.get_node_or_null(^"/root/TimeManager")
	if clock != null:
		clock.set(&"paused", false)
		# Midday. The spawner keeps opening hours now, and SeasonManager resets
		# the clock to MIDNIGHT when a run starts — so without this the tool
		# renders an empty mountain and every other gate looks innocent.
		clock.set(&"time_of_day", 0.5)
	if _burst:
		_spawner.set(&"stagger_seconds", 0.0)
		_spawner.set(&"group_member_stagger_seconds", 0.0)
	_regrowth = _map.get_tree().get_first_node_in_group(&"regrowth")
	if _regrowth != null and _trample >= 0.0:
		_regrowth.set(&"trample_per_step", _trample)
	_spawner.set(&"max_concurrent", maxi(int(_spawner.get(&"max_concurrent")), _count))
	_spawner.request_visitors(_count)
	print("entry cell %s" % _spawner.entry_cell())
	return true


func _report_crowd() -> void:
	var live := _live_visitors()
	# The spawner's own gates, printed because an empty map has several possible
	# causes and guessing between them wastes a run.
	var seasons := root.get_node_or_null(^"/root/SeasonManager")
	var clock := root.get_node_or_null(^"/root/TimeManager")
	print("spawner: pending=%d live=%d entry=%s | phase=%s paused=%s open=%s (%.2f)" % [
		_spawner.pending_count(), _spawner.live_count(), _spawner.entry_cell(),
		seasons.get(&"phase") if seasons != null else "?",
		clock.get(&"paused") if clock != null else "?",
		_spawner.is_open_now(),
		clock.get(&"time_of_day") if clock != null else -1.0])
	if _regrowth != null:
		# Bare cells are the visible tracks; the deficit counts partial wear the
		# art cannot show yet, which is most of it early on.
		print("trampling: %d bare cell(s), %.1f cells of grass worn away (rate %.3f)" % [
			_regrowth.call(&"bare_count"), _regrowth.call(&"vegetation_deficit"),
			_regrowth.get(&"trample_per_step")])
	print("%d visitor(s) on the map after %d frames:" % [live.size(), _walk_frames])
	for v in live:
		print("  at %s -> goal %s  alt %.1f  moving=%s"
				% [v.current_cell, v.goal_cell, v.current_altitude(), v.is_moving()])


## Park the current camera on the crowd's centroid. Smoothing off first — it
## lerps toward its target over many frames and the capture would catch it in
## transit.
func _aim_at_crowd() -> void:
	var live := _live_visitors()
	if live.is_empty():
		return
	var mid := Vector2.ZERO
	for v in live:
		mid += v.global_position
	mid /= float(live.size())
	var cam := _find_camera(root)
	if cam == null:
		return
	cam.position_smoothing_enabled = false
	cam.make_current()
	cam.global_position = mid


func _find_camera(node: Node) -> Camera2D:
	if node is Camera2D and (node as Camera2D).is_current():
		return node as Camera2D
	for child in node.get_children():
		var found := _find_camera(child)
		if found != null:
			return found
	return null


## Visitors are deliberately NOT in a group (ObjectPainter's regenerate sweep
## frees group members under World), so they are found by type.
func _live_visitors() -> Array[Visitor]:
	var out: Array[Visitor] = []
	for n in _map.find_children("*", "Node2D", true, false):
		if n is Visitor:
			out.append(n as Visitor)
	return out


# ----------------------------------------------------------------------------
# Capture
# ----------------------------------------------------------------------------

# Saved at 1:1 and at UPSCALE with NEAREST. At 1:1 a 32px character is too small
# to judge a two-tone ramp on — the shade rung is a handful of texels.
func _save(img: Image, name: String) -> void:
	img.save_png("%svisitors_%s.png" % [_out_dir, name])
	var big := Image.create(
		img.get_width() * UPSCALE, img.get_height() * UPSCALE, false, img.get_format())
	for y in big.get_height():
		for x in big.get_width():
			big.set_pixel(x, y, img.get_pixel(x / UPSCALE, y / UPSCALE))
	big.save_png("%svisitors_%s@%dx.png" % [_out_dir, name, UPSCALE])
	print("wrote visitors_%s.png (%dx%d) and its %dx upscale."
			% [name, img.get_width(), img.get_height(), UPSCALE])
