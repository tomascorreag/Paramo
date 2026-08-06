@tool
class_name RunCalendar
extends Control

## The run's length, drawn on the journal's right page as a calendar grid: one ROW
## per season, one CELL per day of that season. Days already lived get an X
## stamped on them, so the grid answers "how long is this run and how far in am I"
## at a glance — the thing the retired RunDebugLabel used to spell out in text.
##
## Shape is DERIVED from SeasonManager (season_count x days_per_season), never
## authored, so retuning days_per_year reshapes the calendar with no scene edit.
##
## Layout, top to bottom, all inside this node's own width (which it centres in):
##
##     season log                    <- header_text
##        1  2  3  4  5  6           <- day numbers, one per column
##   1 dry [X][X][X][X][X][X]        <- season number + SeasonProfile.id, then the grid
##   2 wet [X][X][  ][  ][  ][  ]
##
## Lives inside PageRight's SubViewport, so page_warp.gdshader bends it along with
## everything else printed on that page. Two consequences worth knowing:
##   - Cell height must be a MULTIPLE of the page's `row_block_px`, and both this
##     node's top and the grid's offset within it must be multiples of it too, or a
##     cell row straddles two warp blocks and gets a scanline duplicated straight
##     through it. `block_px` must therefore be kept equal to the page's
##     `row_block_px`; the header rows round up to it so a font change cannot knock
##     the grid off phase. tests/test_journal_pages.gd guards all of this.
##   - Rules and stamps are drawn with draw_rect on integer coordinates. draw_line
##     would antialias the diagonals of the X into the cream page.
##
## Nothing here is drawn as a single straight run: every rule and every leg of an X
## is broken into short segments nudged +-`*_wobble_px` texels off true, so the
## grid reads as ruled and stamped BY HAND rather than printed. The nudge comes
## from `_wobble`, an integer hash of (line, segment) — deterministic, so a cell
## looks identical on every redraw and nothing has to be seeded or saved.
##
## @tool for editor preview only: autoloads do not run in the editor, so the
## editor draws the `preview_*` shape instead of the live run.

## Cell footprint including its own top-left rule, in texels. The Y must be a
## multiple of PageWarp.row_block_px on the page this sits in (see the class
## comment) — on the journal that is 16, one line of Eggmode. The X is
## unconstrained, but the row must fit the 156-texel page alongside the label
## gutter: at a 6-day season, 56 + 6*16 + 1 = 153. Lengthening the season eats
## this margin cell by cell.
##
## The gutter itself holds "N <season>" in the BODY face (Tiny5 at font_size 8,
## from active_font — NOT the title face), right-aligned into label_width_px - 6.
## The journal sets 38, so 32 texels ≈ 8 characters. That sizing is driven by
## SPANISH, not English: "4 lluvia" measures 24px against "4 wet" at 19, and the
## gutter was widened from 30 to fit it with slack for a two-digit row.
## tests/test_journal_pages.gd measures every row in both locales, because
## draw_string clips silently at this width — an overflowing row just loses its
## tail with no error.
@export var cell_size: Vector2i = Vector2i(16, 16):
	set(value):
		cell_size = value
		queue_redraw()

## Width of the gutter holding each row's season number and name.
@export var label_width_px: int = 56:
	set(value):
		label_width_px = value
		queue_redraw()

## Title over the grid — a TRANSLATION KEY, resolved in _draw. Lowercase in every
## locale, per the project's UI copy convention. Empty drops the title line and
## pulls the grid up by one text row.
##
## Drawn in Eggmode, so its Spanish must be ACCENT-FREE — that face has no
## accented glyphs at all (see JournalKnownSet.title for the full note).
@export var header_text: String = "JOURNAL_SEASON_LOG":
	set(value):
		header_text = value
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

## The X stamped on a day that has passed. Red rather than the page's ink, so a
## stamped day reads as something pressed onto the paper afterwards.
@export var stamp_color: Color = Palette.P05:
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

## Size of the X relative to the largest one that fits the cell interior. Below 1
## the mark sits inside the cell with visible air around it, which is what stops a
## filled row reading as a solid block of red.
@export_range(0.3, 1.0, 0.05) var stamp_scale: float = 0.75:
	set(value):
		stamp_scale = value
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
@export var preview_seasons: int = 4:
	set(value):
		preview_seasons = value
		queue_redraw()

@export var preview_days_per_season: int = 6:
	set(value):
		preview_days_per_season = value
		queue_redraw()

@export var preview_elapsed_days: int = 6:
	set(value):
		preview_elapsed_days = value
		queue_redraw()

## Stands in for SeasonManager.season_cycle's ids, applied by index modulo its
## length exactly as the real cycle is.
@export var preview_season_names: PackedStringArray = ["SEASON_DRY", "SEASON_WET"]:
	set(value):
		preview_season_names = value
		queue_redraw()


## Rows the TITLE is pushed down inside its warp block.
##
## page_warp.gdshader translates each block rigidly and the seam between two blocks
## either duplicates or drops the row adjacent to it, so no line's ink may touch a
## block edge. The body face has room to spare (Tiny5 at 8 inks rows 1..7 of its
## 9-row line box, clear at both ends) but the title does not: Eggmode at 16 inks 17
## rows — 12 above the baseline, 4 below for "g" — inside an 18-row block, one row
## of slack. Spending it at the top is what keeps the caps off the seam; the row
## left exposed at the bottom is the descender row.
const TITLE_INK_INSET_PX: int = 1


func _ready() -> void:
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


## Height of the TITLE row, rounded up to a whole block. Separate from the body
## row because the two use different faces at different sizes; rounding each to a
## whole block independently is what lets them mix without knocking the grid off
## phase.
func header_row_px() -> int:
	return _rounded_row_px(active_header_font(), header_font_size)


## Vertical offset of the grid's top edge within this node. A multiple of block_px
## by construction — the title and the day-number strip are each a whole number of
## blocks, which is the only reason a font change can't knock the grid out of phase.
func grid_top_px() -> int:
	return text_row_px() + (header_row_px() if not header_text.is_empty() else 0)


func _draw() -> void:
	var grid := grid_size()
	var cw: int = maxi(3, cell_size.x)
	var ch: int = maxi(3, cell_size.y)
	var gutter: int = maxi(0, label_width_px)
	var grid_w: int = grid.x * cw + rule_width
	var grid_h: int = grid.y * ch + rule_width
	# The whole block self-centres in this node's width, so a shape change
	# (retuning days_per_year) cannot leave it hanging off one side of the page.
	var left: int = (int(size.x) - (gutter + grid_w)) / 2
	var grid_x: int = left + gutter
	var top: int = grid_top_px()

	var face := active_font()
	var row := text_row_px()
	var ascent: float = face.get_ascent(font_size) if face != null else 0.0

	var title := active_header_font()
	if title != null and not header_text.is_empty():
		var title_y: float = title.get_ascent(header_font_size) + TITLE_INK_INSET_PX
		# tr() inside _draw rather than cached — Control redraws itself on
		# NOTIFICATION_TRANSLATION_CHANGED, so that is the whole locale story here.
		draw_string(title, Vector2(left, title_y), tr(header_text),
			HORIZONTAL_ALIGNMENT_LEFT, -1, header_font_size, text_color)

	if face != null:
		var day_y: float = top - row + ascent
		for c: int in range(grid.x):
			draw_string(face, Vector2(grid_x + c * cw, day_y), str(c + 1),
				HORIZONTAL_ALIGNMENT_CENTER, cw, font_size, text_color)

	# Inner rules first, then the frame over them: the frame is thicker, so drawing
	# it last hides the rule ends instead of leaving them poking out of the corners.
	# The keys are spread apart so a column's wobble doesn't echo a row's.
	for c: int in range(1, grid.x):
		_draw_rule(Vector2i(grid_x + c * cw, top), grid_h, rule_width, false,
			rule_color, rule_wobble_px, 100 + c)
	for r: int in range(1, grid.y):
		_draw_rule(Vector2i(grid_x, top + r * ch), grid_w, rule_width, true,
			rule_color, rule_wobble_px, 400 + r)
	_draw_frame(Rect2(grid_x, top, grid_w, grid_h), border_width, border_color)

	if face != null:
		for r: int in range(grid.y):
			var text: String = "%d %s" % [r + 1, season_name(r)]
			var base: float = top + r * ch + (ch - font_size) * 0.5 + ascent
			# -6, not -0: right-aligned to the gutter's full width the labels butt
			# straight into the grid's left border, which wobbles into them.
			draw_string(face, Vector2(left, floorf(base)), text,
				HORIZONTAL_ALIGNMENT_RIGHT, gutter - 6, font_size, text_color)

	var lived := elapsed_days()
	for i: int in range(mini(lived, grid.x * grid.y)):
		# +rule_width skips the cell's own top-left rules, leaving the interior clear.
		_draw_stamp(
			Vector2i(grid_x + (i % grid.x) * cw + rule_width,
				top + (i / grid.x) * ch + rule_width),
			Vector2i(cw - rule_width, ch - rule_width), i)


func _draw_frame(rect: Rect2, width: int, color: Color) -> void:
	var origin := Vector2i(rect.position)
	var w: int = int(rect.size.x)
	var h: int = int(rect.size.y)
	_draw_rule(origin, w, width, true, color, rule_wobble_px, 1)
	_draw_rule(origin + Vector2i(0, h - width), w, width, true, color, rule_wobble_px, 2)
	_draw_rule(origin, h, width, false, color, rule_wobble_px, 3)
	_draw_rule(origin + Vector2i(w - width, 0), h, width, false, color, rule_wobble_px, 4)


# One ruled line, broken into `wobble_segment_px` runs each nudged up to `amp`
# texels off true. Each step is bridged by a short perpendicular rect, so the line
# is continuous however the segments land — a stepped 1px rule with no bridge is a
# dotted rule. `key` identifies the line: two lines sharing it wobble identically.
func _draw_rule(from: Vector2i, length: int, thick: int, horizontal: bool,
		color: Color, amp: int, key: int) -> void:
	if amp <= 0:
		draw_rect(_span_rect(from, length, thick, horizontal), color)
		return
	var seg: int = maxi(2, wobble_segment_px)
	var i: int = 0
	var s: int = 0
	var prev: int = 0
	while i < length:
		var run: int = mini(seg, length - i)
		var off: int = _wobble(key, s) * amp
		draw_rect(_span_rect(_step(from, i, off, horizontal), run, thick, horizontal), color)
		if s > 0 and off != prev:
			var lo: int = mini(off, prev)
			var bridge: int = absi(off - prev) + thick
			draw_rect(
				_span_rect(_step(from, i, lo, horizontal), bridge, thick, not horizontal),
				color)
		prev = off
		i += run
		s += 1


# Rect `length` along the line and `thick` across it.
func _span_rect(at: Vector2i, length: int, thick: int, horizontal: bool) -> Rect2:
	return Rect2(Vector2(at),
		Vector2(length, thick) if horizontal else Vector2(thick, length))


# `along` texels down the line from `from`, `perp` texels off it.
func _step(from: Vector2i, along: int, perp: int, horizontal: bool) -> Vector2i:
	return from + (Vector2i(along, perp) if horizontal else Vector2i(perp, along))


# Deterministic -1 / 0 / +1 from two integers. Not an RNG: the same rule must land
# in the same place on every redraw (this node repaints on every day tick), so
# there is nothing to seed and nothing to save.
#
# The step is a texel wide because the grid is drawn on the pixel grid — there is
# no such thing as half a texel off true — so the only lever on how much wobble
# READS is how often a segment steps at all. OFFSETS weights that: six of its eight
# slots are 0, so roughly a quarter of segments move and a run of straight ones
# usually separates them. An even -1/0/+1 split moves two segments in three and
# reads as a torn edge rather than a hand-ruled line.
const _OFFSETS: PackedInt32Array = [0, 0, 0, -1, 0, 0, 0, 1]

static func _wobble(a: int, b: int) -> int:
	var h: int = (a * 73856093) ^ ((b + 1) * 19349663)
	h ^= h >> 13
	h *= 1274126177
	return _OFFSETS[absi(h >> 7) % _OFFSETS.size()]


# An X drawn as a square brush dragged along both diagonals, each leg nudged off
# true in the same segmented way as the rules. Sized to the cell interior, so
# retuning cell_size never needs a matching edit here.
func _draw_stamp(at: Vector2i, inner: Vector2i, index: int) -> void:
	var t: int = maxi(1, stamp_width)
	# n brush steps span (n - 1 + t) texels; leave 2 texels of margin inside the cell
	# so the mark never crowds the rules it sits between, then take stamp_scale of
	# what is left. The wobble spends part of that same margin, so it is subtracted
	# here rather than clamped away leg by leg.
	var amp: int = clampi(stamp_wobble_px, 0, 2)
	# Sized off the cell's HEIGHT, then clamped to its width. Cells are wider or
	# narrower depending on how long a season is; the mark should not shrink with
	# them, it should only refuse to overflow.
	var room: int = inner.y - t - 3 - amp
	var n: int = maxi(3, int(roundf(float(room) * clampf(stamp_scale, 0.1, 1.0))))
	n = mini(n, maxi(3, inner.x - t - amp))
	var span := Vector2i(n - 1 + t + amp, n - 1 + t)
	var slack := (inner - span).max(Vector2i.ZERO)
	var off := slack / 2 + Vector2i(amp, 0)
	if stamp_jitter_px > 0:
		# Cheap fixed permutation: no RNG, so the same day always stamps the same
		# way and nothing has to be seeded or saved.
		off += Vector2i(index * 7 % 3 - 1, index * 5 % 3 - 1) * stamp_jitter_px
		off = off.clamp(Vector2i(amp, 0), slack + Vector2i(amp, 0))
	var brush := Vector2(t, t)
	var seg: int = maxi(2, wobble_segment_px)
	for k: int in range(n):
		# Wobble across the leg only (x): the brush is t texels wide and the march is
		# diagonal, so consecutive squares still overlap and the leg stays solid.
		var wa: int = _wobble(index * 31 + 1, k / seg) * amp
		var wb: int = _wobble(index * 31 + 2, k / seg) * amp
		draw_rect(Rect2(Vector2(at + off + Vector2i(k + wa, k)), brush), stamp_color)
		draw_rect(Rect2(Vector2(at + off + Vector2i(n - 1 - k + wb, k)), brush), stamp_color)
