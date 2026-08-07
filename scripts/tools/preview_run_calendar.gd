extends SceneTree
## Renders the journal's LEFT page — the season slot (PageSlit), the run calendar
## (RunCalendar) and the supplies list — at several points in a run.
##
## Both are only meaningful against run state that does not exist at rest: the
## calendar draws nothing until days have passed, and the wheel only leaves its
## zero angle once the season clock is running. So the only way to see either is
## to drive SeasonManager and capture. This tool does that at four states, saved
## as separate PNGs so the progression is legible in stills:
##
##   0_idle       run not started  — empty grid, wheel at rest
##   1_early      3 of 20 days     — first row part-stamped
##   2_mid        11 of 20 days    — wheel a season and a bit round
##   3_survived   run complete     — every cell stamped
##
## What to look for, i.e. the failures it exists to catch:
##   - The slot's two lips must STEP with the page curl (they rise toward the
##     spine, on the RIGHT here — the left page's spine is its right edge) while
##     the wheel behind them does NOT move. If the wheel steps too, the mask has
##     been applied to the wrong thing.
##   - The calendar's rules must step in the same blocks as the page's text, and
##     no stamp may sit across a step — that is the row_block_px phase contract
##     from tests/test_journal_pages.gd, made visible.
##   - The lip shade must hug the cut, not float as a bar over the paper.
##
## Needs a rendering context — do NOT pass --headless.
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/preview_run_calendar.gd -- --out /tmp/cal
##
## Args:
##   --out <dir>    output directory (default: user://)
##   --full         save the whole 480x270 book instead of the right-page crop
##   --locale <id>  render in a specific language (en_GB / es_CO)

# load()ed, not preload()ed — see the same note in preview_page_warp.gd: a preload
# resolves before _initialize() installs the autoloads, and field_journal.gd then
# fails to compile on `SeasonManager`.
const JOURNAL_PATH := "res://scenes/ui/field_journal.tscn"

const VIEW_SIZE := Vector2i(480, 270)
const PIXEL_SCALE := 4
## The LEFT page plus a margin, in book space. Everything this tool is about.
## The page is at x 60..217, y 21..252; the crop leads in a few texels each side.
## It must reach the page's FOOT — the supplies list sits at content row 162, i.e.
## book y 192..228, and the old right-page crop height (190) cut it off.
const CROP := Rect2i(54, 14, 169, 246)
## Palette P30 #14233A behind everything, so transparent margins read as "not page".
const BG := Color8(0x14, 0x23, 0x3A, 0xFF)

## name -> [season_index, days_into_season, phase]. days_per_season is pinned to 4
## below, and season_count is 6, so the run is 24 days.
const STATES: Array[Array] = [
	["0_idle", 0, 0, 0],       # Phase.IDLE
	["1_early", 0, 3, 1],      # Phase.ACTIVE
	["2_mid", 2, 4, 1],
	["3_survived", 5, 4, 3],   # Phase.RUN_OVER
]

var _out_dir: String = "user://"
var _full: bool = false
var _locale: String = ""
var _vp: SubViewport
var _journal: CanvasLayer
var _frames: int = 0
var _state: int = 0


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("preview_run_calendar needs a rendering context. Drop --headless.")
		quit(1)
		return

	var argv := OS.get_cmdline_user_args()
	for i in argv.size():
		match argv[i]:
			"--out":
				if i + 1 < argv.size():
					_out_dir = argv[i + 1]
			"--full":
				_full = true
			"--locale":
				if i + 1 < argv.size():
					_locale = argv[i + 1]
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

	var packed := load(JOURNAL_PATH) as PackedScene
	if packed == null:
		push_error("preview_run_calendar: could not load %s" % JOURNAL_PATH)
		quit(1)
		return
	_journal = packed.instantiate() as CanvasLayer
	_vp.add_child(_journal)
	# Posing waits for _process: FieldJournal._ready parks the book off-screen and
	# hides it, and nodes added here get their _ready on the first iteration.


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


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		_apply_locale()
		_open_instantly(_journal)
		# 4 days a season x 6 seasons = a 4-wide, 6-tall grid (the shipped
		# shape). days_per_season is derived, so retune it through days_per_year.
		var seasons: int = maxi(1, (_season().get(&"season_cycle") as Array).size())
		_season().set(&"days_per_year", 4 * seasons)
		_season().set(&"season_count", 6)
		return false
	if _frames < 4:
		return false

	# Three frames per state: write, settle, capture. The settle frame matters —
	# the calendar redraws into PageLeft's SubViewport, which the container only
	# picks up on the following frame.
	var t: int = _frames - 4
	var index: int = t / 3
	if index >= STATES.size():
		quit(0)
		return true
	match t % 3:
		0:
			_write_state(STATES[index])
		2:
			_capture(STATES[index][0])
	return false


# Applied on the first FRAME, not in _initialize. Project autoloads still run
# under --script, and LocaleManager._ready() sets the boot locale — which happens
# after _initialize and would silently overwrite an override set there. Ask for
# the language once everything that has an opinion about it has had its say.
func _apply_locale() -> void:
	if _locale.is_empty():
		return
	TranslationServer.set_locale(_locale)
	if TranslationServer.get_locale() != _locale:
		push_warning("preview_run_calendar: locale '%s' is not loaded (%s)"
			% [_locale, TranslationServer.get_loaded_locales()])
	_calendar().queue_redraw()


func _write_state(state: Array) -> void:
	_season().set(&"phase", state[3])
	_season().set(&"season_index", state[1])
	# days_into_season() is day_count - _day_at_season_start, so park the season's
	# start at its own boundary and let the absolute day count carry the rest.
	_season().set(&"_day_at_season_start", state[1] * 4)
	_clock().set(&"day_count", state[1] * 4 + state[2])
	_clock().set(&"time_of_day", 0.0)
	_seed_day_stats(state[1] * 4 + state[2])
	_calendar().queue_redraw()


# Each stamped cell also prints what that day YIELDED, and a zero prints nothing
# at all — so without this every still shows bare stamps and the feature is
# invisible in exactly the tool built to look at it. The clock is teleported by
# _write_state rather than advanced, so DayLog's own accumulation never runs and
# the history has to be written in directly.
#
# The series is deliberately UNEVEN, including days that yielded nothing on a
# channel: an even fill hides the one thing worth checking here, which is whether
# a sparse grid still reads as a record rather than as a texture.
const _PREVIEW_YIELD: Array[Array] = [
	[6, 4, 4], [0, 4, 4], [12, 3, 3], [2, 0, 0],
	[0, 5, 5], [8, 4, 4], [3, 4, 4], [0, 0, 0],
	[14, 2, 2], [5, 4, 4], [0, 4, 4], [9, 1, 1],
]


func _seed_day_stats(days: int) -> void:
	if not root.has_node(^"DayLog"):
		return
	var log_ := root.get_node(^"DayLog")
	for i: int in range(days):
		var y: Array = _PREVIEW_YIELD[i % _PREVIEW_YIELD.size()]
		log_.call(&"seed_day", i,
			{&"water": y[0], &"tokens": y[1], &"visitors": y[2]})


# The autoloads are hand-installed in _initialize (see _install_autoloads), and a
# --script main loop is COMPILED before that happens: the `SeasonManager` global
# identifier does not resolve here, only inside scripts loaded later. Hence the
# node lookups and set()/call() instead of typed property access.
func _season() -> Node:
	return root.get_node(^"SeasonManager")


func _clock() -> Node:
	return root.get_node(^"TimeManager")


func _calendar() -> Control:
	return _journal.get_node(
		"Book/BookArt/Pages/PageLeft/SubViewport/Content/RunCalendar") as Control


func _open_instantly(journal: CanvasLayer) -> void:
	journal.visible = true
	var book := journal.get_node("Book") as Control
	book.offset_top = 0.0
	book.offset_bottom = 0.0
	(journal.get_node("Dim") as ColorRect).modulate.a = 0.0


func _capture(name_: String) -> void:
	var img := _vp.get_texture().get_image()
	if not _full:
		img = img.get_region(CROP)
	img.save_png(_out_dir + "cal_%s.png" % name_)
	var big := img.duplicate() as Image
	big.resize(img.get_width() * PIXEL_SCALE, img.get_height() * PIXEL_SCALE,
		Image.INTERPOLATE_NEAREST)
	big.save_png(_out_dir + "cal_%s_%dx.png" % [name_, PIXEL_SCALE])
	var cal := _calendar()
	print("  %-12s grid %s, %s days stamped" % [
		name_, cal.call(&"grid_size"), cal.call(&"elapsed_days")])
