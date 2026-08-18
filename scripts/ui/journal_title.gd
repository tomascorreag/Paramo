class_name JournalTitle
extends RefCounted

## The heading at the top of a journal section — centred on the page and ruled
## under, in the written face (Eggmode).
##
## Three sections now want the identical heading (RunCalendar's "season log",
## JournalKnownSet's "known buildings" / "known flora", JournalResources'
## "resources"), and each had grown its own copy of the same three rules. Those
## rules are not obvious and getting one wrong is a subtle rendering fault, so they
## live here once:
##
##   1. THE TITLE IS DRAWN, NEVER A LABEL. A page sits inside a SubViewport that
##      page_warp.gdshader bends, and the warp quantises to whole `block` bands.
##      Eggmode's line height is 16 and the journal's block is 18; 18 % 16 != 0, so
##      a Label carrying that face fails test_journal_pages.gd's "row_block_px must
##      be a whole number of text lines". Drawing sidesteps the Label phase rule
##      entirely — and re-translates for free, see 3.
##   2. NO INK MAY TOUCH A BLOCK EDGE. The warp translates each band rigidly and the
##      seam between two bands either duplicates or drops the row next to it.
##      Eggmode at 16 inks 17 rows inside an 18-row block — exactly one row of
##      slack — so the title is pushed down by `INK_INSET_PX`, spending that slack
##      at the TOP where the caps are and leaving the bottom row to descenders.
##   3. tr() IS CALLED AT DRAW TIME. Control queue_redraw()s itself on
##      NOTIFICATION_TRANSLATION_CHANGED, so resolving the key inside _draw is the
##      whole locale story. A cached translation would freeze the heading in
##      whichever language it was first resolved in and need its own handler.
##
## The underline is why `row_px` costs TWO blocks rather than one: point 2 leaves no
## room for a rule inside the title's own block, so it goes in the top rows of the
## next one. That is also why it cannot simply be drawn a few pixels under the
## baseline and forgotten about.
##
## WHOSE BLOCK THAT IS is the caller's choice, and it is worth a block of paper.
## The rule is DRAWN at the same row either way — what `Underline` changes is what a
## section charges itself for it, and so what a `header_gap_px` of 0 means.

## What a heading costs, i.e. where its content starts when the gap is 0.
##
## Deliberately NOT an "auto" that picks the tighter: the mode is the authored
## default rhythm of the page and must not move because a swatch was repainted a
## few texels shorter. Physics is the snap's job (JournalBlocks); this is taste's.
enum Underline {
	## The rule gets a block to itself: a heading is two blocks, and content starts
	## under both. What a section whose content fills its own block has to do —
	## JournalResources' 16px glyph beside an 18-row Tiny5 line leaves nothing for a
	## rule to share with.
	OWN_BLOCK,
	## The heading is charged ONE block and the rule sits in the top rows of the
	## content's own first block, the content clearing it below. Worth a whole block
	## of paper, and only legal when the content's ink still lands clean after
	## clearing the rule — which is the snap's business, not this flag's.
	SHARE_ROW,
}

## Rows the title's ink is pushed down inside its own block. See point 2 above.
const INK_INSET_PX: int = 1

## Default rows into the block BELOW the title that the underline sits at. Far
## enough from the seam at the block boundary that a duplicated or dropped row
## there cannot touch it. Callers pass their own `underline_y`; this is what they
## build it from.
const UNDERLINE_INSET_PX: int = 2

## Thickness of the underline. Matches RunCalendar's `border_width` — the heading's
## rule and the calendar's frame are the same stroke of the same pen.
const UNDERLINE_THICK_PX: int = 2

## How far the rule overhangs the text at each end. Without it the rule stops dead
## on the last glyph and reads as a strikethrough that slipped.
const UNDERLINE_OVERHANG_PX: int = 3


## Height this heading occupies, always a whole number of `block`s so whatever sits
## below it stays in phase with the page's warp however the face or size changes.
## Underlined headings cost one block more — that is where the rule goes.
static func row_px(font: Font, size: int, block: int, underlined: bool = true) -> int:
	var b: int = maxi(1, block)
	var h: float = font.get_height(size) if font != null else float(size)
	var rows: int = int(ceilf(h / float(b))) * b
	return rows + (b if underlined else 0)


## The title's own ink as a JournalBlocks run — (offset from the heading's top,
## inked height). The inset is part of the run, not something applied to it: what
## a seam damages is where the ink IS.
static func ink_run(font: Font, size: int) -> Vector2i:
	var h: float = font.get_height(size) if font != null else float(size)
	return Vector2i(INK_INSET_PX, int(ceilf(h)))


## The rule's ink as a run, WOBBLE INCLUDED. `JournalPen.rule` displaces whole
## segments up to `wobble_px` off true, so the line inks `2 * wobble` rows more
## than its own thickness and a floor computed from the thickness alone is one
## short — which is how content ends up printed through the top of its own rule.
static func rule_ink(underline_y: int, wobble_px: int = 1) -> Vector2i:
	var w: int = maxi(0, wobble_px)
	return Vector2i(underline_y - w, UNDERLINE_THICK_PX + 2 * w)


## The first row a section's content may use without touching its own rule.
static func rule_floor(underline_y: int, wobble_px: int = 1) -> int:
	var ink := rule_ink(underline_y, wobble_px)
	return ink.x + ink.y


## Draws `key` (a TRANSLATION KEY, resolved here — see point 3) centred across
## `width`, with the rule at `underline_y` (negative draws no rule). `ci` must be a
## Node, which every CanvasItem is; it supplies both the draw surface and `tr`.
##
## The rule's y is the CALLER's to choose rather than derived here, because whether
## it needs a block of its own depends on what sits underneath. A section whose
## next row is 8px body copy can put the rule in the TOP of that row's block and
## the copy in the bottom of it, sharing one block instead of spending two — which
## is 18 texels of blank paper saved. `row_px(underlined)` covers the other case,
## where the rule really does need a block to itself.
static func draw(ci: CanvasItem, font: Font, size: int, key: String, width: int,
		color: Color, underline_y: int,
		wobble_px: int = 1, segment_px: int = 14) -> void:
	if font == null or key.is_empty():
		return
	var text: String = ci.tr(key)
	ci.draw_string(font, Vector2(0, font.get_ascent(size) + INK_INSET_PX), text,
		HORIZONTAL_ALIGNMENT_CENTER, width, size, color)
	if underline_y < 0:
		return
	# Measured, not assumed: the Spanish headings are a good deal wider than the
	# English ones, and a rule sized to the wrong string is immediately visible.
	var tw: int = int(ceilf(
		font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x))
	var span: int = mini(tw + 2 * UNDERLINE_OVERHANG_PX, width)
	var x: int = maxi(0, (width - span) / 2)
	JournalPen.rule(ci, Vector2i(x, underline_y), span,
		UNDERLINE_THICK_PX, true, color, wobble_px, 7, segment_px)
