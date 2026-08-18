extends SceneTree
## Prints the journal pages' warp-block budget: where every seam is, what each
## section inks, and exactly how far each heading may move.
##
## The page warp displaces each `row_block_px` band by a whole number of texels
## (assets/shaders/page_warp.gdshader), so the boundary between two bands
## duplicates or drops a scanline wherever their displacements differ. This tool
## answers the two questions that come up whenever the page is re-laid-out:
##
##   1. WHERE ARE THE SEAMS, and how much of the page's width does each one
##      actually step? Printed per boundary, per column, from the real curves.
##   2. HOW FAR CAN I MOVE THIS HEADING? Printed as the LIST of legal row tops for
##      each section, with the binding run named — the run whose ink is tallest is
##      the one that forbids the rest of the phases.
##
## Both come out of JournalBlocks, which is also what the sections snap against and
## what tests/test_journal_pages.gd asserts, so this cannot drift from what renders.
##
## Needs a rendering context (the sections read real textures) — do NOT pass
## --headless.
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/audit_page_blocks.gd
##
## Args:
##   --gap <n>   re-ask every section for this header_gap_px and report what it
##               resolves to. The way to price a tightening before authoring it.

# load()ed, not preload()ed: a preload resolves before _initialize() installs the
# autoloads, and field_journal.gd then fails to compile on SeasonManager.
const JOURNAL_PATH := "res://scenes/ui/field_journal.tscn"

## Columns are sampled on this grid — the pages' authored `col_block_px`, which is
## the grid the warp itself quantises to, so a finer sweep would report steps the
## shader cannot produce.
const COL_STEP: int = 4

var _frames: int = 0
var _journal: CanvasLayer
var _gap: int = 0
var _gap_set: bool = false


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("audit_page_blocks needs a rendering context. Drop --headless.")
		quit(1)
		return
	var argv := OS.get_cmdline_user_args()
	for i in argv.size():
		if argv[i] == "--gap" and i + 1 < argv.size():
			_gap = int(argv[i + 1])
			_gap_set = true


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		_journal = load(JOURNAL_PATH).instantiate()
		root.add_child(_journal)
		return false
	# One frame for _ready, one for the sections to rebuild against real textures.
	if _frames < 4:
		return false
	_audit()
	return true


func _audit() -> void:
	var pages := _journal.get_node_or_null("Book/BookArt/Pages")
	if pages == null:
		push_error("no Book/BookArt/Pages in %s" % JOURNAL_PATH)
		quit(1)
		return
	var bad: int = 0
	for page_name: String in ["PageLeft", "PageRight"]:
		var page := pages.get_node_or_null(page_name) as PageWarp
		if page == null:
			continue
		bad += _audit_page(page_name, page)
	print("")
	if bad > 0:
		print("%d run(s) cross a seam they need not. See the legal tops above." % bad)
		quit(1)
		return
	print("every inked run is on the minimum number of blocks.")
	quit(0)


func _audit_page(page_name: String, page: PageWarp) -> int:
	var content := page.get_node_or_null("SubViewport/Content") as Control
	if content == null:
		return 0
	var block: int = int(page.row_block_px)
	print("")
	print("=== %s  block %d  content %d rows at y %d"
		% [page_name, block, int(content.size.y), int(content.position.y)])
	_print_seams(page, content, block)

	var bad: int = 0
	for section: Node in content.get_children():
		if not section.has_method(&"ink_runs"):
			continue
		bad += _audit_section(section as Control, block)
	return bad


# Replays the shader's own arithmetic (see page_warp.gdshader's fragment): the
# weight is evaluated at each block's CENTRE and the offset rounded to whole
# texels, so two adjacent blocks step wherever their rounded offsets differ.
func _print_seams(page: PageWarp, content: Control, block: int) -> void:
	var sub := page.get_node_or_null("SubViewport") as SubViewport
	if sub == null or page.curve_top == null or page.curve_bottom == null:
		return
	var tex_w: float = float(sub.size.x)
	var content_top: float = content.position.y
	var content_h: float = content.size.y
	var half_h: float = 0.5 * content_h
	var count: int = int(ceilf(content_h / float(maxi(1, block))))

	var table: Array[PackedInt32Array] = []
	for b: int in count:
		var yq: float = content_top + (float(b) + 0.5) * float(block)
		var w: float = clampf((content_top + half_h - yq) / half_h, -1.0, 1.0)
		var row := PackedInt32Array()
		for x: int in range(0, int(tex_w), COL_STEP):
			var xq: float = (floorf(float(x) / float(COL_STEP)) + 0.5) * float(COL_STEP)
			var u: float = xq / tex_w
			var cu: float = (1.0 - u) if page.flip_x else u
			var curve: Curve = page.curve_top if w > 0.0 else page.curve_bottom
			var amp: float = page.amplitude_top_px if w > 0.0 else page.amplitude_bottom_px
			row.append(int(roundf(curve.sample_baked(cu) * amp * absf(w))))
		table.append(row)

	var cols: int = table[0].size()
	var parts := PackedStringArray()
	for b: int in range(count - 1):
		var stepped: int = 0
		for i: int in cols:
			if table[b][i] != table[b + 1][i]:
				stepped += 1
		parts.append("y%d:%d%%" % [(b + 1) * block, int(round(100.0 * stepped / cols))])
	print("  seams (share of columns that step): %s" % ", ".join(parts))


func _audit_section(section: Control, block: int) -> int:
	print("")
	print("  --- %s  at y %d, %d rows"
		% [section.name, int(section.position.y), int(section.size.y)])

	if _gap_set and &"header_gap_px" in section:
		section.set(&"header_gap_px", _gap)
	if section.has_method(&"requested_header_row_px"):
		var asked: int = section.call(&"requested_header_row_px")
		var got: int = section.call(&"header_row_px")
		var mark: String = "" if asked == got else "  <- SNAPPED, asked %d" % asked
		print("      header_gap_px %d -> row top %d%s"
			% [section.get(&"header_gap_px"), got, mark])

	var bad: int = 0
	for run: Dictionary in section.call(&"ink_runs"):
		var top: int = run["top"]
		var h: int = run["height"]
		var spans: int = JournalBlocks.spans(top, h, block)
		var least: int = JournalBlocks.min_spans(h, block)
		var clean: bool = spans <= least
		if not clean:
			bad += 1
		print("      %-18s ink %2d rows at %3d  spans %d (min %d) slack %2d  %s"
			% [run["name"], h, top, spans, least, JournalBlocks.slack(h, block),
				"ok" if clean else "CROSSES A SEAM"])

	if not section.has_method(&"content_ink_runs"):
		return bad
	# The list, not a rule: this is the answer to "how far can I move it".
	var runs: Array[Vector2i] = section.call(&"content_ink_runs")
	var floor_px: int = JournalTitle.rule_floor(section.call(&"underline_y"))
	var tops := JournalBlocks.legal_tops(runs, block, floor_px, 4 * block)
	# The run with the LEAST slack is the one that forbids the phases the others
	# could have taken — the thing to shorten if the section needs to move.
	var tightest: int = -1
	for r: Vector2i in runs:
		var s: int = JournalBlocks.slack(r.y, block)
		if tightest < 0 or s < tightest:
			tightest = s
	print("      legal row tops >= %d: %s" % [floor_px, str(tops).replace(" ", "")])
	print("      binding run has %d texels of slack in its window" % maxi(0, tightest))
	return bad
