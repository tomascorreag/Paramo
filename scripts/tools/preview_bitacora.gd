extends SceneTree
## Renders the journal's BITACORA spread — one species per page, two per
## spread, the fore-edge tabs beside them — for every pair of pages the book
## can show, as 1:1 and 4x stills. `--species <id>`
## renders the pair that species is in.
##
## What to look for, i.e. the failures it exists to catch:
##   - Every line of type must nest in an 18-row warp block: no letter sheared
##     across a step, no isolated 1px bar floating over a line. The fun facts
##     WRAP, so a Spanish fact one line longer than its English one is the
##     first thing that will land on a seam — render both locales.
##   - The photo is the herbarium sheet printed as a photograph, with two
##     tape strips over its top corners; the growth stages beside it are ink.
##   - The name sits in its block with the rule under it, not through it, and
##     the field note (one per showing, rotating) ends above the page's foot.
##   - The tabs hang OFF the page, the active one in the page's cream; the
##     the bent page corners (JournalPageCorners) only lift under the pointer;
##     `--corner` renders one lifted.
##
## Needs a rendering context — do NOT pass --headless.
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/preview_bitacora.gd -- --out /tmp/bitacora
##
## Args:
##   --out <dir>       output directory (default: user://)
##   --locale <id>     render in a specific language (en_GB / es_CO)
##   --species <ids>   comma-separated species to render (default: all)
##   --known <ids>     install a FloraCodex holding these species — the book then
##                     browses only those, and `--known ""` is the closed bitácora a
##                     run opens in. Without the flag there is no codex and every
##                     species is browsable (the layout-test picture).
##   --shop <n>        (kept for parity with preview_run_calendar; the page prints
##                     no price)
##   --tab             extend the fore-edge tab, as under the pointer
##   --hires           ALSO render the spread through a 4x canvas transform
##                     (`_hires.png`): the game's own upscale, where the floating
##                     photograph shows its 256x288 texture at 1:1 and the pixel
##                     art is 4x4 blocks. The plain still is 1:1 logical pixels
##                     and cannot show that difference.

const JOURNAL_PATH := "res://scenes/ui/field_journal.tscn"

const VIEW_SIZE := Vector2i(480, 270)
const PIXEL_SCALE := 4
const BG := Color8(0x14, 0x23, 0x3A, 0xFF)

var _out_dir: String = "user://"
var _locale: String = ""
var _species: PackedStringArray = PackedStringArray()
var _known: PackedStringArray = PackedStringArray()
var _install_codex: bool = false
var _shop_tokens: float = -1.0
var _hires: bool = false
## One of tl/tr/bl/br: render that page corner lifted, as under the pointer.
var _corner: String = ""
var _tab: bool = false
var _vp: SubViewport
var _vp_hires: SubViewport
var _journal_hires: CanvasLayer
var _journal: CanvasLayer
var _frames: int = 0
var _queue: PackedStringArray = PackedStringArray()


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("preview_bitacora needs a rendering context. Drop --headless.")
		quit(1)
		return
	var argv := OS.get_cmdline_user_args()
	for i in argv.size():
		match argv[i]:
			"--out":
				if i + 1 < argv.size():
					_out_dir = argv[i + 1]
			"--locale":
				if i + 1 < argv.size():
					_locale = argv[i + 1]
			"--species":
				if i + 1 < argv.size():
					_species = argv[i + 1].split(",", false)
			"--known":
				_install_codex = true
				if i + 1 < argv.size() and not argv[i + 1].begins_with("--"):
					_known = argv[i + 1].split(",", false)
			"--shop":
				if i + 1 < argv.size():
					_shop_tokens = maxf(0.0, float(argv[i + 1]))
			"--hires":
				_hires = true
			"--tab":
				_tab = true
			"--corner":
				if i + 1 < argv.size():
					_corner = argv[i + 1].to_lower()
	if not _out_dir.ends_with("/"):
		_out_dir += "/"
	DirAccess.make_dir_recursive_absolute(_out_dir)

	_vp = SubViewport.new()
	_vp.size = VIEW_SIZE
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.disable_3d = true
	_vp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	root.add_child(_vp)
	var bg_layer := CanvasLayer.new()
	bg_layer.layer = 0
	_vp.add_child(bg_layer)
	var bg := ColorRect.new()
	bg.size = Vector2(VIEW_SIZE)
	bg.color = BG
	bg_layer.add_child(bg)

	_install_autoloads()
	_install_shop()
	_install_known()

	var packed := load(JOURNAL_PATH) as PackedScene
	if packed == null:
		push_error("preview_bitacora: could not load %s" % JOURNAL_PATH)
		quit(1)
		return
	_journal = packed.instantiate() as CanvasLayer
	_vp.add_child(_journal)
	if _hires:
		# A second copy of the book under a 4x canvas transform — what the
		# window does at 1080p. CanvasLayer.transform scales everything under
		# it, including the floating photograph and the tabs.
		_vp_hires = SubViewport.new()
		_vp_hires.size = VIEW_SIZE * PIXEL_SCALE
		_vp_hires.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		_vp_hires.disable_3d = true
		_vp_hires.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
		root.add_child(_vp_hires)
		var bg2_layer := CanvasLayer.new()
		_vp_hires.add_child(bg2_layer)
		var bg2 := ColorRect.new()
		bg2.size = Vector2(VIEW_SIZE * PIXEL_SCALE)
		bg2.color = BG
		bg2_layer.add_child(bg2)
		_journal_hires = packed.instantiate() as CanvasLayer
		_journal_hires.transform = Transform2D().scaled(Vector2(PIXEL_SCALE, PIXEL_SCALE))
		_vp_hires.add_child(_journal_hires)


func _install_autoloads() -> void:
	var order: Array[Array] = [
		["DisplayManager", "res://scripts/systems/display_manager.gd"],
		["TimeManager", "res://scripts/systems/time_manager.gd"],
		["Debug", "res://scripts/systems/debug.gd"],
		["FireManager", "res://scripts/systems/fire_manager.gd"],
		["ResourceLedger", "res://scripts/systems/resource_ledger.gd"],
		["SeasonManager", "res://scripts/systems/season_manager.gd"],
		["DayLog", "res://scripts/systems/day_log.gd"],
	]
	for entry in order:
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


func _install_shop() -> void:
	if _shop_tokens < 0.0:
		return
	var scr := load("res://scripts/systems/unlock_state.gd") as Script
	if scr == null:
		return
	var node := Node.new()
	node.set_script(scr)
	node.name = "UnlockState"
	root.add_child(node)


func _install_known() -> void:
	if not _install_codex:
		return
	var scr := load("res://scripts/systems/flora_codex.gd") as Script
	if scr == null:
		return
	var node := Node.new()
	node.set_script(scr)
	node.name = "FloraCodex"
	root.add_child(node)
	for id: String in _known:
		node.call(&"discover", StringName(id.strip_edges()))


func _apply_locale() -> void:
	if _locale.is_empty():
		return
	TranslationServer.set_locale(_locale)
	if TranslationServer.get_locale() != _locale:
		push_warning("preview_bitacora: locale '%s' is not loaded (%s)"
			% [_locale, TranslationServer.get_loaded_locales()])


# Extends the fore-edge tab on `journal` by hovering the middle of it.
func _extend_tab(journal: CanvasLayer) -> void:
	if not _tab:
		return
	var edge := journal.get_node_or_null("Book/BookArt/ForeEdge")
	if edge == null:
		return
	var shown: Variant = edge.call(&"shown")
	if shown != null:
		edge.call(&"hover", Rect2(edge.call(&"tab_rect", shown, false)).get_center())


# Lifts the requested corner on `journal` by hovering the middle of it.
func _lift_corner(journal: CanvasLayer) -> void:
	if _corner.is_empty():
		return
	# Duck-typed: naming JournalPageCorners here would pull FieldJournal (and
	# its autoload references) into this script's compile, which a --script
	# tool cannot do (see dev-notes: tool-script autoload timing).
	var corners := journal.get_node_or_null("Book/BookArt/PageCorners")
	if corners == null:
		return
	var idx: int = ["tl", "tr", "bl", "br"].find(_corner)
	if idx < 0:
		push_warning("preview_bitacora: --corner wants tl/tr/bl/br, not '%s'" % _corner)
		return
	var rects: Array = corners.get(&"CORNER_RECTS")
	corners.call(&"hover", Rect2(rects[idx]).get_center())


func _open_instantly(journal: CanvasLayer) -> void:
	journal.visible = true
	var book := journal.get_node("Book") as Control
	book.offset_top = 0.0
	book.offset_bottom = 0.0
	(journal.get_node("Dim") as ColorRect).modulate.a = 0.0


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		_apply_locale()
		if _shop_tokens >= 0.0 and root.has_node(^"ResourceLedger"):
			root.get_node(^"ResourceLedger").call(&"set_amount", &"tokens", _shop_tokens)
		_open_instantly(_journal)
		if _journal_hires != null:
			_open_instantly(_journal_hires)
			# Under a scaled CanvasLayer the full-rect Book still anchors to the
			# 4x viewport, which would put the centred art off-screen; in the
			# game DisplayManager shrinks the logical viewport instead. Pin the
			# copy's Book to the logical 480x270 by hand.
			var book := _journal_hires.get_node("Book") as Control
			book.set_anchors_preset(Control.PRESET_TOP_LEFT)
			book.position = Vector2.ZERO
			book.size = Vector2(VIEW_SIZE)
		return false
	if _frames == 2:
		# The codex binds deferred; by now it has. Build the render queue from
		# what the book can actually show.
		var browsable: PackedStringArray = _journal.call(&"browsable_species")
		if _species.is_empty():
			for k: int in range(0, browsable.size(), 2):
				_queue.append(browsable[k])
		else:
			for id: String in _species:
				if browsable.has(id):
					_queue.append(id)
				else:
					push_warning("preview_bitacora: '%s' is not browsable here" % id)
		if _queue.is_empty():
			_queue.append("")
		return false
	if _frames < 4:
		return false
	# Three frames per still: pose, settle (the pages redraw into their
	# SubViewports, which the containers pick up next frame), capture.
	var t: int = _frames - 4
	var index: int = t / 3
	if index >= _queue.size():
		quit(0)
		return true
	match t % 3:
		0:
			var id: String = _queue[index]
			for j: CanvasLayer in [_journal, _journal_hires]:
				if j == null:
					continue
				if id.is_empty():
					j.call(&"show_spread", &"bitacora")
				else:
					j.call(&"show_species", StringName(id))
				_lift_corner(j)
				_extend_tab(j)
		2:
			_capture(_queue[index] if not _queue[index].is_empty() else "empty")
	return false


func _capture(name_: String) -> void:
	var suffix: String = ("_" + _locale) if not _locale.is_empty() else ""
	var img := _vp.get_texture().get_image()
	img.save_png(_out_dir + "bitacora_%s%s.png" % [name_, suffix])
	var big := img.duplicate() as Image
	big.resize(img.get_width() * PIXEL_SCALE, img.get_height() * PIXEL_SCALE,
		Image.INTERPOLATE_NEAREST)
	big.save_png(_out_dir + "bitacora_%s%s_%dx.png" % [name_, suffix, PIXEL_SCALE])
	if _vp_hires != null:
		_vp_hires.get_texture().get_image().save_png(
			_out_dir + "bitacora_%s%s_hires.png" % [name_, suffix])
	var dirty: int = 0
	var runs: int = 0
	for path: String in ["Book/BookArt/Pages/PageLeft/SubViewport/Content/SpeciesPlateLeft",
			"Book/BookArt/Pages/PageRight/SubViewport/Content/SpeciesPlateRight"]:
		var plate := _journal.get_node(path)
		for r: Dictionary in plate.call(&"ink_runs"):
			runs += 1
			if not JournalBlocks.is_clean(r["top"], r["height"], 18):
				dirty += 1
	var pair: Array = _journal.call(&"page_species")
	print("  %-24s + %-24s %d runs, %d seam crossings"
		% [name_, String(pair[1]) if pair[1] != &"" else "(blank)", runs, dirty])
