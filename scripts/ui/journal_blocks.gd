class_name JournalBlocks
extends RefCounted

## The algebra of the journal page's warp blocks: what may sit where, and how far
## it may be moved.
##
## assets/shaders/page_warp.gdshader displaces each `row_block_px` band of a page
## by a WHOLE number of texels, evaluated at the band's centre. Adjacent bands
## therefore differ by 0 or 1 texel, and where they differ the boundary between
## them duplicates or drops one source scanline. Measured on the right page (block
## 18, amplitude ±5, 12 bands): every one of the 11 boundaries steps across roughly
## half the page's columns — x 0..~120 of 156, the spine half. A seam is not a
## theoretical risk on this page, it is a certainty for anything drawn inboard of
## the outer third.
##
## THE RULE IS ABOUT INK, NOT ABOUT NODES. What a seam damages is drawn pixels, so
## the constraint is on each RUN OF INK: a run of height `h` must touch no more
## blocks than its height forces it to, `ceil(h / block)`. Everything follows from
## that one statement:
##
##   - a run SHORTER than a block must lie inside one block, and it has
##     `block - h` texels of freedom in where it starts;
##   - a run TALLER than a block cannot avoid seams — a 30-texel fence in an
##     18-texel grid crosses one wherever it is put — so the goal is to cross the
##     FEWEST, which it does anywhere in a `ceil(h/block) * block` window;
##   - a run exactly as tall as its block (Tiny5-16's 18-row line box, say) has
##     zero freedom and must start on a boundary.
##
## This replaced a much cruder rule that lived in the sections themselves: "the
## header must be a whole number of blocks". That was a proxy — sufficient, never
## necessary — and it was wrong in both directions. Too strong, because it forbade
## every one of the six other phases a 30-texel swatch in a 36-texel window can
## legally take. Too weak, because a section top on a boundary says nothing about
## where the ART inside it lands: the swatches were never checked at all, and one
## straddling three blocks would have passed.
##
## `slack()` is what "creative freedom" is worth in texels on any given row, and
## `snap_top()` is how a section spends it without ever rendering a sheared page.
## scripts/tools/audit_page_blocks.gd prints both for the real scene.
##
## Runs are Vector2i(offset_from_row_top, inked_height) — not Dictionaries: these
## are compared in loops that run per layout pass.


## Blocks a run of `height` MUST touch, wherever it is placed.
static func min_spans(height: int, block: int) -> int:
	var b: int = maxi(1, block)
	return maxi(1, int(ceilf(float(maxi(1, height)) / float(b))))


## Blocks a run of `height` starting at `top` actually touches.
static func spans(top: int, height: int, block: int) -> int:
	var b: int = maxi(1, block)
	var h: int = maxi(1, height)
	return floordiv(top + h - 1, b) - floordiv(top, b) + 1


## True when the run crosses no more seams than its own height forces.
static func is_clean(top: int, height: int, block: int) -> bool:
	return spans(top, height, block) <= min_spans(height, block)


## Texels of freedom a run of `height` has in where it starts: the window its
## minimum span buys it, less the ink. 0 means it must start on a boundary.
static func slack(height: int, block: int) -> int:
	var b: int = maxi(1, block)
	return min_spans(height, b) * b - maxi(1, height)


## True when every run stays clean with the row's top at `top`. Runs are offsets
## FROM that top, so this is the whole legality test for a section's content.
static func runs_clean(top: int, runs: Array[Vector2i], block: int) -> bool:
	for r: Vector2i in runs:
		if not is_clean(top + r.x, r.y, block):
			return false
	return true


## The nearest row top to `requested` that keeps every run clean and clears
## `floor_px` — what a section returns instead of the raw authored value.
##
## Ties break TIGHTER (upward). A negative `header_gap_px` is a request to pull
## the row up, and resolving the tie downward would answer a request to tighten by
## loosening, which is the one direction the author has already ruled out.
##
## Falls back to `requested` if nothing within `search_blocks` is legal, rather
## than looping forever or throwing: an unsatisfiable set of runs is a design
## error to be reported (see `_get_configuration_warnings` on the sections), not a
## crash in the middle of a page redraw.
static func snap_top(requested: int, runs: Array[Vector2i], block: int,
		floor_px: int, search_blocks: int = 3) -> int:
	var lo: int = maxi(0, floor_px)
	var start: int = maxi(requested, lo)
	if runs.is_empty() or runs_clean(start, runs, block):
		return start
	var reach: int = maxi(1, search_blocks) * maxi(1, block)
	for d: int in range(1, reach + 1):
		var down: int = start - d
		if down >= lo and runs_clean(down, runs, block):
			return down
		if runs_clean(start + d, runs, block):
			return start + d
	return start


## Every legal row top in [floor_px, floor_px + reach). For the audit tool: this
## is the answer to "how far can I move this heading", stated as the actual list
## of places it may go rather than as a rule to apply by hand.
static func legal_tops(runs: Array[Vector2i], block: int, floor_px: int,
		reach: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for t: int in range(maxi(0, floor_px), maxi(0, floor_px) + maxi(1, reach)):
		if runs_clean(t, runs, block):
			out.append(t)
	return out


# GDScript's / on ints truncates toward zero, so -1 / 18 is 0 and a run starting
# one texel above the content's top edge would report the same block as one
# starting on it. Content should never be placed above its own top, but `spans`
# is public and is fed authored numbers.
static func floordiv(a: int, b: int) -> int:
	return int(floorf(float(a) / float(maxi(1, b))))
