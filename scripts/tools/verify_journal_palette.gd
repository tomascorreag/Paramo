extends SceneTree
## Audits every RENDERED pixel of the field journal's two pages against the
## journal's reduced palette, and exits non-zero if anything else appears.
##
## Why this exists rather than a unit test: tests/test_journal_pages.gd can only
## check the colours somebody AUTHORED. It cannot see what those colours become
## once they are composited — and that gap is not theoretical. The calendar's rules
## were authored as P06 at alpha 0.7, a perfectly legal palette entry; every rule
## pixel rendered as 9D7967, a colour nobody authored and no RGB check would ever
## catch. Only a pixel audit of the real render finds that class of bug. (The fix
## was to make the rules an opaque lighter entry, P10; the test now also forbids
## alpha < 1 on journal ink, which is stricter than the project-wide "alpha is
## free" rule and stricter for exactly this reason.)
##
## THE REDUCED PALETTE is derived, never listed here: it is the union of the stops
## in the four resources/ui/journal_ink_*.tres ramps. Those ramps are what the ink
## shader can emit, so making them the whole page's budget is what keeps type,
## drawn marks and inked sprites in one set. Add a stop and the pages may use it;
## that is the only way the budget widens.
##
## ALSO ALLOWED: every colour in Book.png itself. The book's cover (B55945) and
## page edges (D4C692) fall inside the page rects, and art assets are palette-bound
## at authoring time — CLAUDE.md's Color Palette rule covers values TYPED by code
## or set in .tres/.tscn, not the sprites. Reading them off the PNG rather than
## hardcoding the two hexes means a repaint of the book cannot fail this tool.
##
## EXEMPT: the season disc and the slot cut around it. The disc is an object mounted
## BEHIND the book rather than ink on the page, so it keeps the world palette; the
## brief that introduced this budget excluded it explicitly.
##
## Needs a rendering context — do NOT pass --headless.
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/verify_journal_palette.gd
##
## Args:
##   --out <dir>        also save the audited render (default: don't)
##   --verbose          list every allowed colour and its pixel count, not just failures
##   --spread bitacora  audit the BITACORA spread instead: every pair of pages the
##                      book can show, one render each. The photographs are
##                      exempt (they are photographs, taped in, like the disc is
##                      a disc); everything around them — tape, stages, type —
##                      is audited. The slot is not exempt there (it is hidden
##                      with the run spread).

const JOURNAL_PATH := "res://scenes/ui/field_journal.tscn"
const BOOK_PATH := "res://assets/sprites/UX/Panels/Book.png"
const VIEW_SIZE := Vector2i(480, 270)

const RAMP_PATHS: Array[String] = [
	"res://resources/ui/journal_ink_warm.tres",
	"res://resources/ui/journal_ink_green.tres",
	"res://resources/ui/journal_ink_cool.tres",
	"res://resources/ui/journal_ink_neutral.tres",
]

## Page rects in book space, matching tests/test_journal_pages.gd's PAGE_RECTS.
const PAGE_RECTS := {
	"left": Rect2i(60, 21, 157, 231),
	"right": Rect2i(264, 21, 156, 231),
}
## The season-disc slot, exempt (see the header). Matches SeasonGaugeHolder's rect.
const SLOT_RECT := Rect2i(106, 30, 64, 38)
## The bitacora's polaroids, exempt on that spread for the same reason as the
## disc: a photograph stuck into the page is not ink, and the frame around it
## is an art asset (PolaroidFrame.png, authored white and P12 gold), which the
## palette rule covers at authoring time, not here.
## Read off the plates at audit time, in book space, and GROWN by the page
## warp's reach: page_warp.gdshader stretches content by up to its amplitude
## (5 texels) and steps columns by one, so the photo's edge rows land a few
## texels outside the unwarped rect. Measured before the growth: 24 photo
## pixels a page reported off-palette, all on its edges.
var _photo_rects: Array[Rect2i] = []
const PHOTO_EXEMPT_GROW := Vector2i(1, 6)

var _out_dir: String = ""
var _verbose: bool = false
var _spread: String = "run"
var _vp: SubViewport
var _journal: CanvasLayer
var _frames: int = 0
var _queue: PackedStringArray = PackedStringArray()
var _failures: int = 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i: int in range(args.size()):
		match args[i]:
			"--out":
				if i + 1 < args.size():
					_out_dir = args[i + 1].rstrip("/") + "/"
			"--verbose":
				_verbose = true
			"--spread":
				if i + 1 < args.size():
					_spread = args[i + 1]

	_vp = SubViewport.new()
	_vp.size = VIEW_SIZE
	_vp.transparent_bg = false
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(_vp)

	_journal = (load(JOURNAL_PATH) as PackedScene).instantiate()
	_vp.add_child(_journal)
	# Posed on the first FRAME, not here: FieldJournal._ready hides the layer
	# and parks the book below the viewport, and a node added from _initialize
	# gets its _ready on the first iteration — after anything set here. Opened
	# from _initialize, the tool audited an empty viewport and reported the
	# clear colour as the pages' one off-palette pixel.
	# SceneTree._process returns bool (true ends the loop), not void.


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		_open_instantly(_journal)
		if _spread == "bitacora":
			# One render per PAIR: the even positions of the ring.
			var ids: PackedStringArray = _journal.call(&"browsable_species")
			for k: int in range(0, ids.size(), 2):
				_queue.append(ids[k])
		else:
			_queue.append("")
		return false
	# Four frames per render: pose, then let the page SubViewports render their
	# content and the containers pick it up, then audit.
	var t: int = _frames - 2
	var i: int = t / 4
	if i >= _queue.size():
		if _failures > 0:
			print("\nFAIL: %d off-palette colours on the journal pages." % _failures)
			print("      Either the colour is wrong, or a legal one is being composited")
			print("      at alpha < 1 (see this file's header) — check the alpha first.")
			quit(1)
		else:
			print("\nPASS: every page pixel is a ramp stop or Book.png's own art.")
			quit(0)
		return true
	if t % 4 == 0 and not _queue[i].is_empty():
		_journal.call(&"show_species", StringName(_queue[i]))
		_photo_rects = _collect_photo_rects()
	elif t % 4 == 3:
		_failures += _audit(_queue[i])
	return false


# Each plate's photo rect, plate-local -> book space (the plate sits at the
# page's Content origin: page rect + the 9px content inset).
func _collect_photo_rects() -> Array[Rect2i]:
	var out: Array[Rect2i] = []
	var pages := {"PageLeft": PAGE_RECTS["left"], "PageRight": PAGE_RECTS["right"]}
	for page_name: String in pages:
		var content := _journal.get_node_or_null(
			"Book/BookArt/Pages/%s/SubViewport/Content" % page_name) as Control
		if content == null:
			continue
		for child: Node in content.get_children():
			if not child.has_method(&"frame_rects") or not (child as Control).visible:
				continue
			var page_rect: Rect2i = pages[page_name]
			for r: Rect2i in child.call(&"frame_rects"):
				var at := page_rect.position + Vector2i(content.position) + r.position
				out.append(Rect2i(at - PHOTO_EXEMPT_GROW, r.size + 2 * PHOTO_EXEMPT_GROW))
	return out


func _is_exempt(p: Vector2i) -> bool:
	for r: Rect2i in _photo_rects:
		if r.has_point(p):
			return true
	return false


func _open_instantly(journal: CanvasLayer) -> void:
	journal.visible = true
	var book := journal.get_node("Book") as Control
	book.offset_top = 0.0
	book.offset_bottom = 0.0
	(journal.get_node("Dim") as ColorRect).modulate.a = 0.0


func _audit(label: String) -> int:
	var img := _vp.get_texture().get_image()
	if _out_dir != "":
		img.save_png(_out_dir + "journal_palette_audit%s.png"
			% (("_" + label) if not label.is_empty() else ""))
	if not label.is_empty():
		print("\n=== %s" % label)

	var allowed := _reduced_palette()
	print("reduced palette: %d colours from %d ramps" % [allowed.size(), RAMP_PATHS.size()])
	var book_colors := _book_colors()
	print("Book.png art:    %d colours (exempt — art is palette-bound at authoring)"
		% book_colors.size())
	for hex: String in book_colors:
		allowed[hex] = true

	var ox: int = int((img.get_width() - VIEW_SIZE.x) / 2.0)
	var oy: int = int((img.get_height() - VIEW_SIZE.y) / 2.0)
	var failures := 0
	for name_: String in PAGE_RECTS:
		var rect: Rect2i = PAGE_RECTS[name_]
		var off: Dictionary = {}
		var seen: Dictionary = {}
		var total := 0
		for y: int in range(rect.position.y, rect.end.y):
			for x: int in range(rect.position.x, rect.end.x):
				if _spread != "bitacora" and SLOT_RECT.has_point(Vector2i(x, y)):
					continue
				if _is_exempt(Vector2i(x, y)):
					continue
				var hex := img.get_pixel(ox + x, oy + y).to_html(false)
				total += 1
				seen[hex] = seen.get(hex, 0) + 1
				if not allowed.has(hex):
					off[hex] = off.get(hex, 0) + 1
		failures += off.size()
		print("\n%-6s page: %d px audited, %d distinct colours, %d OFF-palette"
			% [name_, total, seen.size(), off.size()])
		if _verbose:
			for hex: String in _by_count(seen):
				print("    %s %s x%d"
					% ["   " if allowed.has(hex) else "OFF", hex, seen[hex]])
		for hex: String in _by_count(off):
			print("    OFF %s x%d" % [hex, off[hex]])

	return failures


func _reduced_palette() -> Dictionary:
	var out: Dictionary = {}
	for path: String in RAMP_PATHS:
		var ramp := load(path) as GradientTexture1D
		if ramp == null:
			push_error("verify_journal_palette: missing ramp " + path)
			continue
		for c: Color in ramp.gradient.colors:
			out[c.to_html(false)] = true
	return out


func _book_colors() -> Dictionary:
	var out: Dictionary = {}
	var tex := load(BOOK_PATH) as Texture2D
	if tex == null:
		return out
	var img := tex.get_image()
	for y: int in range(img.get_height()):
		for x: int in range(img.get_width()):
			var c := img.get_pixel(x, y)
			if c.a > 0.0:
				out[c.to_html(false)] = true
	return out


func _by_count(counts: Dictionary) -> Array:
	var keys := counts.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return counts[a] > counts[b])
	return keys
