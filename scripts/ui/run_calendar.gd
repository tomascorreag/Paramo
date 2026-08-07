@tool
class_name RunCalendar
extends Control

## The run's length, drawn on the journal's LEFT page as a calendar grid: one ROW
## per season, one CELL per day of that season. Days already lived get an X stamped
## on them and print what the mountain GAVE that day, so the grid answers both "how
## far into the run am I" and "what was that day worth" at a glance.
##
## Shape is DERIVED from SeasonManager (season_count x days_per_season), never
## authored, so retuning days_per_year reshapes the calendar with no scene edit.
##
## Layout, top to bottom, all inside this node's own width (which it centres in):
##
##     season log                    <- header_text, CENTRED, ruled under
##     ----------
##          1        2               <- day numbers, one per column
##   1 dry [X  O 6 ][X  O 2 ]        <- gutter label, then the grid. A lived cell is
##         [   @ 4 ][   @ 4 ]           stamped X on the left; to its right, what
##   2 wet [       ][       ]           that day yielded: water over tokens.
##
## THE CELL IS THE BINDING CONSTRAINT, and the numbers are worth keeping to hand
## before retuning anything. The page's Content is 157 texels wide; the gutter takes
## 38, leaving 119 for `days_per_season` columns — 29 each at the shipped 4 days,
## so 28 of usable interior, and 17 tall. Of that width the yield takes 17
## (8 glyph + 1 + 8 number) and the stamp gets the other 11.
##
## TWO channels, not the three DayLog records, and that is a HEIGHT limit rather
## than a preference. Two 8-texel rows is 16 of the 17; a third needs 24, so the
## cell would have to be 36 — the next multiple of the warp block — and 6 rows of
## 36 is 217 against the 177 the page has left under the header. Visitors is the
## channel dropped because it is the one the player never spends: it is an input to
## the token count already printed beside it.
##
## The same arithmetic is why the calendar CANNOT simply be made taller. Cell
## height is quantised to the warp block (see below), so the only sizes available
## are 18 and 36, and 36 does not fit. Measured, not guessed.
##
## Lives inside PageLeft's SubViewport, so page_warp.gdshader bends it along with
## everything else printed on that page. Consequences worth knowing:
##   - Cell height must be a MULTIPLE of the page's `row_block_px` (18 on the
##     journal), and both this node's top and the grid's offset within it must be
##     multiples of it too, or a cell row straddles two warp blocks and gets a
##     scanline duplicated straight through it. `block_px` must therefore be kept
##     equal to the page's `row_block_px`; the header rows round up to it so a font
##     change cannot knock the grid off phase. tests/test_journal_pages.gd guards
##     all of this.
##   - Nor may any INK sit on a block seam, which is why the cell's two stat rows
##     take interior rows 0..7 and 8..15, leaving row 16 bare against the seam at
##     the cell's bottom edge.
##   - Rules and stamps are drawn with draw_rect on integer coordinates (JournalPen).
##     draw_line would antialias the diagonals of the X into the cream page.
##
## Nothing here is drawn as a single straight run: every rule and every leg of an X
## is broken into short segments nudged +-`*_wobble_px` texels off true, so the
## grid reads as ruled and stamped BY HAND rather than printed. See JournalPen.
##
## The stat ICONS are drawn by a child JournalInkLayer rather than by this node,
## because they need assets/shaders/journal_ink.gdshader and the rules, title and
## numbers around them must not — a material covers everything its CanvasItem
## draws. See that class for why it exists.
##
## @tool for editor preview only: autoloads do not run in the editor, so the
## editor draws the `preview_*` shape instead of the live run.

## Cell footprint including its own top-left rule, in texels. The Y must be a
## multiple of PageWarp.row_block_px on the page this sits in (see the class
## comment) — on the journal that is 18. The X is unconstrained by the warp, but
## the row must fit the 157-texel page alongside the label gutter, and the cell's
## contents need what is left: at the shipped 4-day season, 38 + 4*29 + 1 = 155 of
## 157. Lengthening the season narrows the cells until the 20-texel
## glyph-plus-number group stops fitting; the HEIGHT is fixed at one warp block by
## the class comment's arithmetic and is not a free choice.
##
## The gutter itself holds "N <season>" in the BODY face (Tiny5 at font_size 8,
## from active_font — NOT the title face), right-aligned into label_width_px - 6.
## The journal sets 38, so 32 texels ≈ 8 characters. That sizing is driven by
## SPANISH, not English: "4 lluvia" measures 24px against "4 wet" at 19, and the
## gutter was widened from 30 to fit it with slack for a two-digit row.
## tests/test_journal_pages.gd measures every row in both locales, because
## draw_string clips silently at this width — an overflowing row just loses its
## tail with no error.
@export var cell_size: Vector2i = Vector2i(29, 18):
	set(value):
		cell_size = value
		queue_redraw()

## Width of the gutter holding each row's season number and name.
@export var label_width_px: int = 56:
	set(value):
		label_width_px = value
		queue_redraw()

## Title over the grid — a TRANSLATION KEY, resolved at draw time by JournalTitle.
## Lowercase in every locale, per the project's UI copy convention. Empty drops the
## title (and its rule) and pulls the grid up by one block.
##
## Drawn in Eggmode, so its Spanish must be ACCENT-FREE — that face has no
## accented glyphs at all (see JournalKnownSet.title for the full note).
@export var header_text: String = "JOURNAL_SEASON_LOG":
	set(value):
		header_text = value
		queue_redraw()

@export_group("Header")
## Rows below the TITLE's block that the underline sits at.
##
## The rule lands in the DAY-NUMBER row's block, not in a block of its own, and
## that is where the header's spacing comes from: `day_number_offset_px` pushes the
## numbers into the bottom of that same block, so one block carries both and the
## grid starts 18 texels higher than it would otherwise. Keep this clear of row 0
## (the seam) and of where the numbers land.
@export_range(0, 17) var header_underline_offset_px: int = 2:
	set(value):
		header_underline_offset_px = value
		queue_redraw()

## Rows into the day-number block that the numbers' LINE BOX starts at. 0 puts them
## directly under the title's block and leaves a gap above the grid; the shipped 9
## drops them to the block's lower half, tight to the grid, with the underline
## above them.
##
## Ink lands on rows offset+1 .. offset+7 of the block (Tiny5-8 inks rows 1..7 of
## its 9-row box), so offset + 8 must stay below `block_px` or the numbers cross
## the seam into the grid.
@export_range(0, 9) var day_number_offset_px: int = 9:
	set(value):
		day_number_offset_px = value
		queue_redraw()

## WHOLE BLANK BLOCKS between the header and the grid. 0 is tight, which is what
## this page wants; raise it only to open the layout up deliberately. Blocks, not
## texels, because anything else pushes the grid off the warp's quantisation and
## puts a duplicated scanline through a row of cells.
@export_range(0, 4) var header_gap_blocks: int = 0:
	set(value):
		header_gap_blocks = value
		queue_redraw()

@export_group("Type")
## Body face — the day numbers and the season labels. Leave null to take the
## theme's Label font (Tiny5), which is what the journal wants: the handwritten
## face is reserved for TITLES, so the data underneath stays legible at 8px.
@export var font: Font = null:
	set(value):
		font = value
		queue_redraw()

## Title face, used for `header_text` alone. Leave null to reuse the body face.
## The journal sets this to Eggmode — a title is a thing you WROTE at the top of
## the page, the grid below it is a thing you ruled and stamped.
@export var header_font: Font = null:
	set(value):
		header_font = value
		queue_redraw()

## Size for `header_font`. Must be a multiple of that face's native em (16 for
## Eggmode) — see `font_size` for what happens otherwise.
@export var header_font_size: int = 16:
	set(value):
		header_font_size = value
		queue_redraw()

## Constrained by the FACE, not by taste. Every pixel face has a native em its
## outline is drawn on, and any size that is not a multiple of it scales the glyphs
## by a fraction: roughly one pixel row per em gets duplicated, at a DIFFERENT place
## in each letter, so a line of text visibly staggers. Tiny5 and Bytesized are 8px,
## Eggmode 16 — measured off the glyph outlines, not read off the specimen.
##
## Second: `block_px` must be a whole number of these lines, or a line straddles two
## warp blocks and gets a scanline duplicated through it. Tiny5 at 8 is 9 rows and
## the journal's block is 18, so two body lines nest in one block exactly.
@export var font_size: int = 8:
	set(value):
		font_size = value
		queue_redraw()

## The page's warp quantisation. The title row and the day-number row are each
## rounded UP to a multiple of this, which is what keeps the grid below them in
## phase however tall the two chosen faces turn out to be — so changing either
## size cannot silently push the grid off the block grid.
@export var block_px: int = 9:
	set(value):
		block_px = value
		queue_redraw()

@export_group("Ink")
## Rules between cells.
@export var rule_color: Color = Palette.with_alpha(Palette.P06, 0.7):
	set(value):
		rule_color = value
		queue_redraw()

## The grid's outer frame and the header's underline — the heavy strokes.
@export var border_color: Color = Palette.P06:
	set(value):
		border_color = value
		queue_redraw()

@export var rule_width: int = 1:
	set(value):
		rule_width = value
		queue_redraw()

@export var border_width: int = 2:
	set(value):
		border_width = value
		queue_redraw()

## Header title, day numbers and season labels.
@export var text_color: Color = Palette.P06:
	set(value):
		text_color = value
		queue_redraw()

## The X stamped on a day that has passed. RED, and the one thing on either page
## that is not journal ink — a stamp is not something written on the paper, it is
## something pressed onto it afterwards, and the whole point of the mark is that it
## reads as a different medium from the record it sits on.
##
## That makes it the single exception to the page's ink rule: everything else
## authored on a page must be a STOP ON ONE OF THE INK RAMPS (so flat ink and inked
## art can never disagree), while this only has to be a palette2 entry.
## test_journal_pages.gd encodes the exception by name — if the stamp ever stops
## being a stamp, take it back out.
@export var stamp_color: Color = Palette.DANGER:
	set(value):
		stamp_color = value
		queue_redraw()

## Stroke width of that X, in texels.
@export var stamp_width: int = 2:
	set(value):
		stamp_width = value
		queue_redraw()

## Shifts each X up to this many texels off-centre, deterministically by day
## index, so the column of marks reads as hand-stamped rather than tiled. 0 = dead
## centre. Never pushed outside its own cell.
@export_range(0, 2) var stamp_jitter_px: int = 1:
	set(value):
		stamp_jitter_px = value
		queue_redraw()

## Size of the X relative to its band (the left part of the cell — see
## `stamp_band_px`). The remaining air is what keeps a filled row from reading as a
## solid bar of red. Below ~0.6 it stops looking stamped and starts looking ticked.
@export_range(0.3, 1.0, 0.05) var stamp_scale: float = 0.9:
	set(value):
		stamp_scale = value
		queue_redraw()

## Width of the X relative to the height `stamp_scale` gave it. 1 is as wide as its
## band allows; below 1 the mark narrows toward an upright cross, above 1 it
## flattens. Separate from `stamp_scale` because the cell is far wider than it is
## tall, so "how big" and "what shape" are genuinely different questions here.
@export_range(0.2, 2.0, 0.05) var stamp_aspect: float = 1.0:
	set(value):
		stamp_aspect = value
		queue_redraw()

## Nudges the X off centre within its band, in texels. Whole texels only — the mark
## is drawn on the pixel grid and a fractional offset would resample it.
@export var stamp_offset: Vector2i = Vector2i.ZERO:
	set(value):
		stamp_offset = value
		queue_redraw()

## Width of the band the X is stamped in, at the LEFT of each cell; the day's yield
## takes what is left. The stamp needs a band rather than sitting behind the numbers
## because it prints at full strength — a red stroke through an 8px digit makes the
## digit unreadable. Widening this past `cell_size.x - 18` starts clipping the
## counts.
@export_range(4, 24) var stamp_band_px: int = 11:
	set(value):
		stamp_band_px = value
		queue_redraw()

@export_group("Day stats")
## Whether a lived day prints what it yielded. Off leaves the bare X, which is what
## the calendar showed before DayLog existed.
@export var show_day_stats: bool = true:
	set(value):
		show_day_stats = value
		queue_redraw()

## The stat glyphs, one per row with its count beside it, 1:1 with `_STAT_IDS`.
## Each must be an 8x8 texture: two of them stack into the cell's 17 usable rows
## with one to spare, where 16x16 glyphs would need 32. The icons/*_small.tres
## variants exist for exactly this. (The RESOURCES section on the other page has a
## whole block per row and uses the full-size 16x16 icons.)
@export var stat_icons: Array[Texture2D] = []:
	set(value):
		stat_icons = value
		queue_redraw()

## Runs the stat icons through assets/shaders/journal_ink.gdshader so they print as
## page ink rather than in their own UI colours (the water glyph is blues and the
## visitor glyph a flat black silhouette — neither is anything a journal page would
## contain). Carried by a child JournalInkLayer, NOT by this node: a material covers
## everything its CanvasItem draws, and the rules, title and numbers must stay out
## of the ramp.
@export var ink_material: ShaderMaterial = null:
	set(value):
		ink_material = value
		_sync_ink_layer()

## Height of one stat row inside a cell. Two of them plus a bare row against the
## bottom seam must fit the cell interior — at the shipped 18-texel cell that
## caps this at 8.
@export_range(6, 16) var stat_row_px: int = 8:
	set(value):
		stat_row_px = value
		queue_redraw()

## Nudges both glyphs within their rows, in texels. Whole texels only: these are
## 8px sprites in a 1:1 nearest viewport, where a fractional offset resamples them.
@export var stat_icon_offset: Vector2i = Vector2i.ZERO:
	set(value):
		stat_icon_offset = value
		queue_redraw()

## Nudges both counts relative to their glyphs. X is measured from the glyph's
## right edge, so raising it opens the gap between a glyph and its number without
## moving the glyph.
@export var stat_number_offset: Vector2i = Vector2i.ZERO:
	set(value):
		stat_number_offset = value
		queue_redraw()

## What each preview cell yields in the editor, where DayLog does not run. Applied
## by index modulo its length across the stamped days.
@export var preview_stats: PackedInt32Array = [6, 4, 3, 2, 5, 1, 0, 4, 2]:
	set(value):
		preview_stats = value
		queue_redraw()

@export_group("Hand")
## How far a rule segment may sit off true, in texels. 0 draws dead-straight lines.
@export_range(0, 2) var rule_wobble_px: int = 1:
	set(value):
		rule_wobble_px = value
		queue_redraw()

## Same, for the two legs of an X. Kept separate because the stamp is a thicker
## stroke: the wobble that reads as "ruled by hand" on a 1px rule reads as a broken
## line on a 2px diagonal.
@export_range(0, 2) var stamp_wobble_px: int = 1:
	set(value):
		stamp_wobble_px = value
		queue_redraw()

## Length of one straight run before the line is allowed to step again. Short
## segments read as a shaky hand, long ones as a slightly crooked ruler. Paired
## with the weighting in _OFFSETS: at 14 a cell edge is one segment, so a step
## almost always falls on a cell boundary rather than part-way across a cell.
@export_range(2, 32) var wobble_segment_px: int = 14:
	set(value):
		wobble_segment_px = value
		queue_redraw()

@export_group("Editor preview")
@export var preview_seasons: int = 6:
	set(value):
		preview_seasons = value
		queue_redraw()

@export var preview_days_per_season: int = 4:
	set(value):
		preview_days_per_season = value
		queue_redraw()

@export var preview_elapsed_days: int = 6:
	set(value):
		preview_elapsed_days = value
		queue_redraw()

## Stands in for SeasonManager.season_cycle's ids, applied by index modulo its
## length exactly as the real cycle is.
@export var preview_season_names: PackedStringArray = ["SEASON_WET", "SEASON_DRY"]:
	set(value):
		preview_season_names = value
		queue_redraw()


## The stat channels, one per ROW of a cell, matching DayLog's keys and
## `stat_icons`. Visitors are deliberately NOT here: a cell has room for two rows,
## and of the three channels visitors is the one the player does not spend — it is
## an input to the token count already printed beside it.
const _STAT_IDS: Array[StringName] = [&"water", &"tokens"]

## Glyph size. Not read off the texture: a wrong-sized icon should be visibly wrong
## rather than silently pushing its number out of the cell.
const _STAT_ICON_PX: int = 8

## Air between a glyph and its number.
const _STAT_GAP_PX: int = 1

## Width of the number beside each glyph. Two digits at Tiny5's 4-texel advance,
## which `_STAT_MAX` is what clamps values to.
const _STAT_NUM_PX: int = 8

## Counts clamp here rather than running out of their column. Two digits is what
## `_STAT_NUM_PX` holds; a heavy rain day can bank more water than that.
const _STAT_MAX: int = 99

# Child that carries `ink_material` for the stat glyphs alone. See _sync_ink_layer.
var _ink: JournalInkLayer = null


func _ready() -> void:
	_sync_ink_layer()
	if Engine.is_editor_hint():
		return
	# Every edge that can change the shape or the fill. day_completed is the only
	# one that fires mid-season; the rest re-shape the grid or end the run.
	TimeManager.day_completed.connect(_on_clock_changed)
	SeasonManager.season_started.connect(_on_season_changed)
	SeasonManager.season_ended.connect(_on_season_changed)
	SeasonManager.run_completed.connect(_on_run_completed)


func _on_clock_changed(_day: int) -> void:
	queue_redraw()


func _on_season_changed(_index: int, _profile: SeasonProfile) -> void:
	queue_redraw()


func _on_run_completed(_reason: StringName) -> void:
	queue_redraw()


## Rows (seasons) x columns (days per season) of the current run.
func grid_size() -> Vector2i:
	if Engine.is_editor_hint():
		return Vector2i(maxi(1, preview_days_per_season), maxi(1, preview_seasons))
	return Vector2i(maxi(1, SeasonManager.days_per_season), maxi(1, SeasonManager.season_count))


## Days already lived, counted from the start of the run. Stops where the run
## stopped: a loss leaves the remaining cells blank, surviving fills them all.
func elapsed_days() -> int:
	if Engine.is_editor_hint():
		return preview_elapsed_days
	if SeasonManager.phase == SeasonManager.Phase.IDLE:
		return 0
	var per: int = maxi(1, SeasonManager.days_per_season)
	var done: int = SeasonManager.season_index * per \
		+ clampi(SeasonManager.days_into_season(), 0, per)
	var grid := grid_size()
	return clampi(done, 0, grid.x * grid.y)


## Short lowercase name for season `index`, translated from the profile's
## `short_name_key`. display_name is Title Case, English-only (it feeds a debug
## print) and too wide for the gutter, so it is not what the calendar shows.
##
## Resolved per call from inside _draw, never cached — that is what makes a
## locale switch repaint the gutter for free (Control redraws on
## NOTIFICATION_TRANSLATION_CHANGED).
func season_name(index: int) -> String:
	if Engine.is_editor_hint():
		if preview_season_names.is_empty():
			return ""
		return tr(preview_season_names[index % preview_season_names.size()])
	var cycle: Array[SeasonProfile] = SeasonManager.season_cycle
	if cycle.is_empty():
		return ""
	var profile: SeasonProfile = cycle[index % cycle.size()]
	if profile == null:
		return ""
	# Fall back to the id so a profile authored without a key still labels its
	# rows (untranslated) instead of leaving the gutter blank.
	return tr(profile.short_name_key) if not profile.short_name_key.is_empty() \
		else String(profile.id)


## The body font actually used: the export if set, else the theme's Label font.
func active_font() -> Font:
	return font if font != null else get_theme_font(&"font", &"Label")


## The title font actually used: its own export if set, else the body font.
func active_header_font() -> Font:
	return header_font if header_font != null else active_font()


func _rounded_row_px(f: Font, size_: int) -> int:
	var h: float = f.get_height(size_) if f != null else float(size_)
	var block: int = maxi(1, block_px)
	return int(ceilf(h / float(block))) * block


## Height of one BODY text row (the day-number strip), rounded up to a whole block.
func text_row_px() -> int:
	return _rounded_row_px(active_font(), font_size)


## Height of the TITLE row, rounded up to a whole block. NOT including a block for
## the underline — that shares the day-number row's block (see
## `header_underline_offset_px`). Separate from the body row because the two use
## different faces at different sizes; rounding each to a whole block independently
## is what lets them mix without knocking the grid off phase.
func header_row_px() -> int:
	return JournalTitle.row_px(active_header_font(), header_font_size, block_px, false)


## Vertical offset of the grid's top edge within this node. A multiple of block_px
## by construction — the title and the day-number strip are each a whole number of
## blocks, which is the only reason a font change can't knock the grid out of phase.
func grid_top_px() -> int:
	return text_row_px() + maxi(0, header_gap_blocks) * maxi(1, block_px) \
		+ (header_row_px() if not header_text.is_empty() else 0)


# Cell interior origin and size for day `index`, in this node's local space. The
# ONE place the grid's arithmetic lives: the parent's stamps and numbers and the
# ink layer's icons all come through here, so they cannot drift apart the way two
# copies of the same offsets would.
func _cell_interior(index: int) -> Rect2i:
	var grid := grid_size()
	var cw: int = maxi(3, cell_size.x)
	var ch: int = maxi(3, cell_size.y)
	var gutter: int = maxi(0, label_width_px)
	# The whole block self-centres in this node's width, so a shape change
	# (retuning days_per_year) cannot leave it hanging off one side of the page.
	var left: int = (int(size.x) - (gutter + grid.x * cw + rule_width)) / 2
	# +rule_width skips the cell's own top-left rules, leaving the interior clear.
	return Rect2i(
		Vector2i(left + gutter + (index % grid.x) * cw + rule_width,
			grid_top_px() + (index / grid.x) * ch + rule_width),
		Vector2i(cw - rule_width, ch - rule_width))


func _draw() -> void:
	var grid := grid_size()
	var cw: int = maxi(3, cell_size.x)
	var ch: int = maxi(3, cell_size.y)
	var gutter: int = maxi(0, label_width_px)
	var grid_w: int = grid.x * cw + rule_width
	var grid_h: int = grid.y * ch + rule_width
	var left: int = (int(size.x) - (gutter + grid_w)) / 2
	var grid_x: int = left + gutter
	var top: int = grid_top_px()

	var face := active_font()
	var row := text_row_px()
	var ascent: float = face.get_ascent(font_size) if face != null else 0.0

	# The rule lands in the DAY-NUMBER row's block rather than in one of its own,
	# and the numbers sit in the lower part of that same block. One block instead of
	# two is 18 texels of blank paper the header no longer costs.
	var head: int = header_row_px() if not header_text.is_empty() else 0
	JournalTitle.draw(self, active_header_font(), header_font_size, header_text,
		int(size.x), text_color, head + header_underline_offset_px,
		rule_wobble_px, wobble_segment_px)

	if face != null:
		var day_y: float = top - row + day_number_offset_px + ascent
		for c: int in range(grid.x):
			draw_string(face, Vector2(grid_x + c * cw, day_y), str(c + 1),
				HORIZONTAL_ALIGNMENT_CENTER, cw, font_size, text_color)

	# Inner rules first, then the frame over them: the frame is thicker, so drawing
	# it last hides the rule ends instead of leaving them poking out of the corners.
	# The keys are spread apart so a column's wobble doesn't echo a row's.
	for c: int in range(1, grid.x):
		JournalPen.rule(self, Vector2i(grid_x + c * cw, top), grid_h, rule_width,
			false, rule_color, rule_wobble_px, 100 + c, wobble_segment_px)
	for r: int in range(1, grid.y):
		JournalPen.rule(self, Vector2i(grid_x, top + r * ch), grid_w, rule_width,
			true, rule_color, rule_wobble_px, 400 + r, wobble_segment_px)
	JournalPen.frame(self, Rect2(grid_x, top, grid_w, grid_h), border_width,
		border_color, rule_wobble_px, 1, wobble_segment_px)

	if face != null:
		for r: int in range(grid.y):
			var text: String = "%d %s" % [r + 1, season_name(r)]
			var base: float = top + r * ch + (ch - font_size) * 0.5 + ascent
			# -6, not -0: right-aligned to the gutter's full width the labels butt
			# straight into the grid's left border, which wobbles into them.
			draw_string(face, Vector2(left, floorf(base)), text,
				HORIZONTAL_ALIGNMENT_RIGHT, gutter - 6, font_size, text_color)

	# The stamp keeps to its own band on the left of each cell; the day's yield
	# prints to its right. The icons come last of all, from the child ink layer
	# (children draw after their parent).
	var lived: int = mini(elapsed_days(), grid.x * grid.y)
	for i: int in range(lived):
		var band := _stamp_band(_cell_interior(i))
		_draw_stamp(band.position, band.size, i)
	if show_day_stats and face != null:
		for i: int in range(lived):
			_draw_stat_numbers(_cell_interior(i), i, face, ascent)
	# Queued from here rather than from each of the ~20 export setters: everything
	# the icons depend on is a thing that also repaints this node, so one call at
	# the end of the parent's draw keeps the two in step.
	if _ink != null and is_instance_valid(_ink):
		_ink.queue_redraw()


# An X drawn as a square brush dragged along both diagonals, each leg nudged off
# true in the same segmented way as the rules (JournalPen). Sized to the cell
# interior, so retuning cell_size never needs a matching edit here.
#
# One brush step per ROW, with x INTERPOLATED across the span — not the square
# one-step-per-row-and-column march it used to be. The cells are wider than they
# are tall now, and a square X in a 28x17 cell leaves the mark hanging in the
# middle with bare paper either side, reading as a tick rather than a stamp.
func _draw_stamp(at: Vector2i, inner: Vector2i, index: int) -> void:
	var t: int = maxi(1, stamp_width)
	var amp: int = clampi(stamp_wobble_px, 0, 2)
	var s: float = clampf(stamp_scale, 0.1, 1.0)
	# The box the two diagonals SWEEP; the brush adds t to each axis on top, and
	# the wobble spends amp more across, so both are taken out here rather than
	# clamped away leg by leg. Width takes `stamp_aspect` on top of the shared
	# scale, then clamps: the band is narrow, so a wide aspect would otherwise push
	# the mark into the numbers beside it.
	var span := Vector2i(
		clampi(int(roundf(float(inner.x - t - amp) * s * clampf(stamp_aspect, 0.1, 4.0))),
			1, maxi(1, inner.x - t - amp)),
		maxi(1, int(roundf(float(inner.y - t) * s))))
	var slack := (inner - span - Vector2i(t + amp, t)).max(Vector2i.ZERO)
	var off := slack / 2 + Vector2i(amp, 0)
	if stamp_jitter_px > 0:
		# Cheap fixed permutation: no RNG, so the same day always stamps the same
		# way and nothing has to be seeded or saved.
		off += Vector2i(index * 7 % 3 - 1, index * 5 % 3 - 1) * stamp_jitter_px
		off = off.clamp(Vector2i(amp, 0), slack + Vector2i(amp, 0))
	# Added AFTER the jitter clamp, not before: that clamp keeps the mark inside its
	# own band, and folding a deliberate offset in first would let it cancel it.
	off += stamp_offset
	var brush := Vector2(t, t)
	var seg: int = maxi(2, wobble_segment_px)
	for k: int in range(span.y + 1):
		var fx: int = int(roundf(float(span.x) * float(k) / float(span.y)))
		# Wobble across the leg only (x): the brush is t texels wide and the march
		# is diagonal, so consecutive squares still overlap and the leg stays solid.
		var wa: int = JournalPen.wobble(index * 31 + 1, k / seg) * amp
		var wb: int = JournalPen.wobble(index * 31 + 2, k / seg) * amp
		draw_rect(Rect2(Vector2(at + off + Vector2i(fx + wa, k)), brush), stamp_color)
		draw_rect(Rect2(Vector2(at + off + Vector2i(span.x - fx + wb, k)), brush), stamp_color)


# --- Day stats ---------------------------------------------------------------

# The cell splits LEFT/RIGHT rather than layering: the stamp gets `stamp_band_px`
# and the day's yield gets the rest.
#
# The X used to be drawn across the whole cell UNDER the numbers, which worked only
# while it was faded — at full strength a red stroke through an 8px digit makes the
# digit unreadable, and dropping the stamp's opacity to fix that makes the stamp
# read as a smudge. Two channels instead of three is what freed the texels this
# needs; at three there was no band to give it.
func _stamp_band(cell: Rect2i) -> Rect2i:
	return Rect2i(cell.position,
		Vector2i(clampi(stamp_band_px, 1, maxi(1, cell.size.x - 1)), cell.size.y))


# Left edge of the glyph-plus-number group: hard against the right of the stamp's
# band, so the two never overlap however either is tuned.
func _stat_group_x(inner_w: int) -> int:
	return clampi(stamp_band_px, 0, maxi(0, inner_w - 1))


## What day `index` (0-based, matching the calendar's cells) yielded on channel
## `stat`. Clamped to what a column can print — see `_STAT_MAX`.
func stat_value(index: int, stat: int) -> int:
	var raw: int = 0
	if Engine.is_editor_hint():
		# DayLog is an autoload and autoloads do not run in the editor, so the
		# editor prints the preview series instead of an empty run.
		if not preview_stats.is_empty():
			raw = preview_stats[(index * _STAT_IDS.size() + stat) % preview_stats.size()]
	else:
		raw = int(DayLog.day(index).get(_STAT_IDS[stat], 0))
	return clampi(raw, 0, _STAT_MAX)


# The numbers, drawn by THIS node so they print in flat ink. Their icons are drawn
# by the child ink layer below, which is the only part that wants the ramp.
#
# A ZERO PRINTS NOTHING — no glyph, no digit. This is the single biggest thing
# keeping the grid readable: with 24 days x 3 channels there are 72 slots on a
# 157-texel page, and filling every one of them turns the calendar into a texture
# rather than a record. Blank means "nothing came in", which is the honest reading
# and the one that lets a good day stand out.
func _draw_stat_numbers(cell: Rect2i, index: int, face: Font, ascent: float) -> void:
	var x: int = cell.position.x + _stat_group_x(cell.size.x) \
		+ _STAT_ICON_PX + _STAT_GAP_PX + stat_icon_offset.x + stat_number_offset.x
	for s: int in range(_STAT_IDS.size()):
		var v: int = stat_value(index, s)
		if v <= 0:
			continue
		# Line box top at the row's own top, so ink lands on rows 1..7 of it —
		# clear of the row above and, on the lower row, of the cell's bottom seam.
		var y: float = cell.position.y + s * stat_row_px + ascent \
			+ stat_icon_offset.y + stat_number_offset.y
		draw_string(face, Vector2(x, y), str(v),
			HORIZONTAL_ALIGNMENT_LEFT, _STAT_NUM_PX, font_size, text_color)


# Painted by the child JournalInkLayer, so `ink_material` recolours these glyphs
# and nothing else this node draws. Runs the same _cell_interior arithmetic as the
# stamps and numbers, so the three cannot fall out of alignment.
func _paint_stat_icons(ci: CanvasItem) -> void:
	if not show_day_stats or stat_icons.is_empty():
		return
	var grid := grid_size()
	var lived: int = mini(elapsed_days(), grid.x * grid.y)
	var glyph := Vector2(_STAT_ICON_PX, _STAT_ICON_PX)
	for i: int in range(lived):
		var cell := _cell_interior(i)
		var x: int = cell.position.x + _stat_group_x(cell.size.x) + stat_icon_offset.x
		for s: int in range(mini(stat_icons.size(), _STAT_IDS.size())):
			var tex: Texture2D = stat_icons[s]
			# Paired with _draw_stat_numbers: a channel that yielded nothing prints
			# neither its glyph nor its digit, so the glyph is always a label FOR a
			# number rather than a row heading standing on its own.
			if tex == null or stat_value(i, s) <= 0:
				continue
			ci.draw_texture_rect(tex, Rect2(Vector2(x,
				cell.position.y + s * stat_row_px + stat_icon_offset.y), glyph), false)


# Created in code rather than authored in field_journal.tscn because it is pure
# plumbing: it has no layout of its own, it exists only to hold `ink_material`
# away from this node's text. Deliberately not set_owner'd — under @tool an owned
# child would be written into the scene file.
func _sync_ink_layer() -> void:
	if not is_inside_tree():
		return
	if _ink == null or not is_instance_valid(_ink):
		_ink = JournalInkLayer.new()
		_ink.name = "StatIcons"
		_ink.painter = _paint_stat_icons
		add_child(_ink)
		_ink.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ink.material = ink_material
	_ink.queue_redraw()
