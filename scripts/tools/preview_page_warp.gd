extends SceneTree
## Renders the field journal's warped pages and MEASURES whether the warp actually
## lands on the drawn page.
##
## assets/shaders/page_warp.gdshader bends each page's content to follow the
## perspective drawn into Book.png. The failure it exists to prevent — content
## floating a few pixels off the paper — is a 1..9 px error that you cannot judge
## from a 480x270 still, so this harness does two things:
##
##   1. Saves PNGs (1:1 and 4x NEAREST). A 1 px stair-step is invisible at 1:1.
##   2. Traces a 1 px marker rule laid along the top and bottom of each page's
##      Content, finds it column by column in the render, and diffs it against the
##      expected rows derived from Book.png itself. That diff IS the alignment
##      check; the images are for judging how the stepping reads.
##
## Exit code 0 if every column is within --tol of the art, 1 otherwise.
##
## Needs a rendering context — do NOT pass --headless.
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/preview_page_warp.gd -- --out /tmp/pagewarp
##
## Args:
##   --out <dir>       output directory (default: user://)
##   --tol <px>        max allowed per-column deviation from the art (default 1)
##   --rows <px>       row_block_px to apply to both pages, for A/B-ing the
##                     line-quantised mode against the default per-pixel warp
##   --no-markers      skip the marker rules (and the numeric check) so the PNGs
##                     show only real page content

# load()ed, NOT preload()ed: a preload resolves at script COMPILE time, i.e. before
# _initialize() gets to hand-install the autoloads, and field_journal.gd then fails
# to compile on `SeasonManager` and the scene quietly instantiates with no script.
const JOURNAL_PATH := "res://scenes/ui/field_journal.tscn"
const BOOK_TEX: Texture2D = preload("res://assets/sprites/UX/Panels/Book.png")

const VIEW_SIZE := Vector2i(480, 270)
const PIXEL_SCALE := 4
# The full vertical sweep of a drawn page edge, in texels — the SubViewport's
# padding, and the most any content could follow. Content amplitude is measured
# against this to get the fraction it actually tracks.
const FULL_SWEEP_PX: float = 9.0

# Palette P13 #FEE1B8 — the cream the pages are drawn in. Used to locate the page
# rows in Book.png, so it must be byte-exact to the art.
const CREAM := Color8(0xFE, 0xE1, 0xB8, 0xFF)
# Palette P17 #44702D — the marker rules. Any palette entry absent from the book
# art works; green is unmistakable against cream and the red-brown cover.
const MARKER := Color8(0x44, 0x70, 0x2D, 0xFF)
# Palette P30 #14233A behind everything, so transparent margins read as "not page".
const BG := Color8(0x14, 0x23, 0x3A, 0xFF)
## Body face for the type specimen this tool prints on the page (see _add_specimen).
## load()ed rather than preload()ed for the same autoload reason as JOURNAL_PATH.
const _BODY_FONT := "res://assets/fonts/Tiny5-Regular.ttf"

var _out_dir: String = "user://"
var _tol: int = 1
var _row_block: float = 0.0
var _markers: bool = true
var _vp: SubViewport
var _journal: CanvasLayer
var _frames: int = 0
var _pages: Array = []  # [{name, x0, x1, marker_top_local, marker_bottom_local}]


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("preview_page_warp needs a rendering context. Drop --headless.")
		quit(1)
		return

	var argv := OS.get_cmdline_user_args()
	for i in argv.size():
		match argv[i]:
			"--out":
				if i + 1 < argv.size():
					_out_dir = argv[i + 1]
			"--tol":
				if i + 1 < argv.size():
					_tol = int(argv[i + 1])
			"--rows":
				if i + 1 < argv.size():
					_row_block = float(argv[i + 1])
			"--no-markers":
				_markers = false
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

	# Autoloads are NOT installed when the main loop is replaced via --script, and
	# FieldJournal's _process reads SeasonManager/TimeManager — without these its
	# script fails to COMPILE and the scene silently loads with no script at all.
	# (Same hand-install as profile_scene.gd, in project.godot order.)
	_install_autoloads()

	var packed := load(JOURNAL_PATH) as PackedScene
	if packed == null:
		push_error("preview_page_warp: could not load %s" % JOURNAL_PATH)
		quit(1)
		return
	_journal = packed.instantiate() as CanvasLayer
	_vp.add_child(_journal)
	# Posing is deferred to the first _process tick, NOT done here: nodes added
	# during _initialize get their _ready on the first iteration, and FieldJournal's
	# _ready parks the book below the screen and hides it — so anything we set now
	# is overwritten and the capture comes back empty.


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
			continue
		var scr := load(entry[1]) as Script
		if scr == null:
			push_warning("autoload %s: could not load %s" % [name_, entry[1]])
			continue
		var node := Node.new()
		node.set_script(scr)
		node.name = name_
		root.add_child(node)


# The journal parks itself below the screen in _ready and only rises on open() via
# a tween. We want the resting pose in one frame, and no scrim over the art.
func _open_instantly(journal: CanvasLayer) -> void:
	journal.visible = true
	var book := journal.get_node("Book") as Control
	book.offset_top = 0.0
	book.offset_bottom = 0.0
	(journal.get_node("Dim") as ColorRect).modulate.a = 0.0


func _prepare_pages(journal: CanvasLayer) -> void:
	var pages := journal.get_node("Book/BookArt/Pages")
	# Book-space column range to CHECK, inclusive. Narrower than the page container
	# on the spine side: the innermost two columns of each page (215..216, 263..264)
	# are the curl where the paper turns into the binding, drawn as a partial-height
	# sliver (x=216 is only 57 rows tall). The warp is not meant to reproduce that
	# notch — it reproduces the page's top and bottom sweep — so measuring there
	# would compare against art that isn't a page edge. The check re-derives the
	# ROWS from Book.png; only these extents are stated here.
	var specs := [
		{"node": "PageLeft", "x0": 60, "x1": 214},
		{"node": "PageRight", "x0": 265, "x1": 419},
	]
	for spec: Dictionary in specs:
		var page := pages.get_node(spec["node"]) as SubViewportContainer
		page.set(&"row_block_px", _row_block)
		var content := page.get_node("SubViewport/Content") as Control
		var origin_y: int = int(page.position.y)
		var entry := {
			"name": spec["node"],
			"warp": page,
			"x0": spec["x0"],
			"x1": spec["x1"],
		}
		if _markers:
			# A 1 px rule at the very top and bottom of the flat content rect. Where
			# these land IS the warp, measured.
			_add_rule(content, 0.0)
			_add_rule(content, content.size.y - 1.0)
			# Where those rules sit in the RENDER before any warp, in book space.
			entry["flat_top"] = origin_y + int(content.position.y)
			entry["flat_bottom"] = origin_y + int(content.position.y + content.size.y) - 1
		_pages.append(entry)

	_add_specimen(pages)


## Something legible on a page, so the PNGs show how the stepping reads on real
## text rather than on two rules.
##
## The tool BRINGS its own specimen rather than retexting a label out of the scene.
## It used to drive PageLeft's `Entry` body copy, but neither page carries a plain
## Label any more — the left page is the run readout (calendar + supplies, both
## drawn or nested) and the right page is the known-set lists, whose titles are
## draw_string calls for the reason in journal_known_set.gd. Owning the specimen
## also means this measurement cannot be silently weakened by a scene edit.
##
## It goes in the right page's free bottom band. Two reasons: it is the only run of
## empty rows either page still has, and it is FAR from the page's vertical centre,
## which is where the warp's weighting — and so the stepping this is here to show —
## is strongest.
func _add_specimen(pages: Node) -> void:
	var content := pages.get_node(
		"PageRight/SubViewport/Content") as Control
	var label := Label.new()
	label.add_theme_font_override(&"font", load(_BODY_FONT))
	label.add_theme_font_size_override(&"font_size", 8)
	label.add_theme_color_override(&"font_color", Palette.P30)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# On the block grid, same contract as any authored page text: x a multiple of
	# col_block_px (4), y a multiple of the 9px Tiny5 line.
	label.position = Vector2(8, 180)
	label.size = Vector2(content.size.x - 16.0, 33.0)
	label.text = "the quick brown fox jumps over the lazy dog. "\
		+ "pack my box with five dozen liquor jugs. "\
		+ "how vexingly quick daft zebras jump. "\
		+ "sphinx of black quartz, judge my vow. "\
		+ "waltz, bad nymph, for quick jigs vex. "\
		+ "jackdaws love my big sphinx of quartz."
	content.add_child(label)
	# The number to feed --rows: row_block_px only helps if it matches this.
	print("  specimen label line height: %d px" % label.get_line_height())


func _add_rule(content: Control, y: float) -> void:
	var rule := ColorRect.new()
	rule.color = MARKER
	rule.position = Vector2(0.0, y)
	rule.size = Vector2(content.size.x, 1.0)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(rule)


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		# _ready has now run, so posing sticks.
		_open_instantly(_journal)
		_prepare_pages(_journal)
		return false
	# Then a couple of frames: one for the page SubViewports to render, one for the
	# containers to composite them into the outer viewport.
	if _frames < 5:
		return false
	var img := _vp.get_texture().get_image()
	img.save_png(_out_dir + "page_warp.png")
	var big := img.duplicate() as Image
	big.resize(VIEW_SIZE.x * PIXEL_SCALE, VIEW_SIZE.y * PIXEL_SCALE, Image.INTERPOLATE_NEAREST)
	big.save_png(_out_dir + "page_warp_%dx.png" % PIXEL_SCALE)
	print("preview_page_warp: wrote %spage_warp.png (+%dx)" % [_out_dir, PIXEL_SCALE])

	var ok := true
	if _markers:
		ok = _check_alignment(img)
	quit(0 if ok else 1)
	return true


# Compares, per column, where the marker rules ACTUALLY landed against where they
# SHOULD land. Book.png is decoded here rather than trusting hardcoded numbers, so
# retouching the art surfaces as a failure instead of a silently stale constant.
#
# The target is NOT the drawn page edge itself. Content follows only part of the
# art's sweep (PageWarp.amplitude_*_px, currently 5 of the drawn 9): every texel of
# amplitude is one step in the warp's stair, and a step landing mid-glyph shears the
# letter, so the page deliberately trades curl fidelity for crisp type. The expected
# row is therefore the flat row plus that FRACTION of the art's own displacement,
# which keeps this a real check of the shader while letting the shortfall be tuned.
# The residual gap to the art is reported separately as information, not a failure.
func _check_alignment(render: Image) -> bool:
	var art := BOOK_TEX.get_image()
	if art.is_compressed():
		art.decompress()
	var all_ok := true
	for page: Dictionary in _pages:
		var worst_top := 0
		var worst_bottom := 0
		var worst_col := -1
		var missing := 0
		# What fraction of the art's sweep the content is authored to follow.
		var warp: PageWarp = page["warp"]
		var follow: float = absf(warp.amplitude_top_px) / FULL_SWEEP_PX
		var gap := 0
		for x: int in range(page["x0"], int(page["x1"]) + 1):
			var art_rows := _span(art, x, CREAM)
			var got_rows := _span(render, x, MARKER)
			if art_rows.x < 0 or got_rows.x < 0:
				missing += 1
				continue
			# The art's own displacement at this column, scaled by `follow`.
			var want_top: int = int(page["flat_top"]) 				+ int(roundf((art_rows.x - int(page["flat_top"])) * follow))
			var want_bottom: int = int(page["flat_bottom"]) 				+ int(roundf((art_rows.y - int(page["flat_bottom"])) * follow))
			var d_top: int = absi(got_rows.x - want_top)
			var d_bottom: int = absi(got_rows.y - want_bottom)
			if d_top > worst_top or d_bottom > worst_bottom:
				worst_col = x
			worst_top = maxi(worst_top, d_top)
			worst_bottom = maxi(worst_bottom, d_bottom)
			gap = maxi(gap, maxi(absi(got_rows.x - art_rows.x), absi(got_rows.y - art_rows.y)))
		var page_ok := missing == 0 and worst_top <= _tol and worst_bottom <= _tol
		all_ok = all_ok and page_ok
		print("  %-10s %s  worst dev: top %d px, bottom %d px (col %d), %d columns missing a marker" % [
			page["name"], "PASS" if page_ok else "FAIL",
			worst_top, worst_bottom, worst_col, missing,
		])
		print("             follows %.0f%% of the art's sweep; largest gap to the drawn edge %d px"
			% [follow * 100.0, gap])
	if not all_ok:
		print("  tolerance was %d px — pass --tol to loosen it" % _tol)
	return all_ok


# First and last row in column x matching `want`, as (top, bottom); (-1,-1) if absent.
func _span(img: Image, x: int, want: Color) -> Vector2i:
	var top := -1
	var bottom := -1
	for y in img.get_height():
		var c := img.get_pixel(x, y)
		if c.a < 0.99:
			continue
		if is_equal_approx(c.r, want.r) and is_equal_approx(c.g, want.g) \
				and is_equal_approx(c.b, want.b):
			if top < 0:
				top = y
			bottom = y
	return Vector2i(top, bottom)
