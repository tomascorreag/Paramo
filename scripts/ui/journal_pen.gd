class_name JournalPen
extends RefCounted

## Ruled strokes for the journal's pages, drawn as if BY HAND.
##
## Nothing on these pages is a single straight run: a rule is broken into short
## segments each nudged +-`amp` texels off true, so the page reads as ruled with a
## ruler and a shaky hand rather than printed. The nudge comes from `wobble`, an
## integer hash of (line, segment) — deterministic, so a line lands identically on
## every redraw and there is nothing to seed and nothing to save. That matters more
## than it sounds: RunCalendar repaints on every day tick, and an RNG here would
## make the whole grid crawl once a day.
##
## Everything is `draw_rect` on integer coordinates. `draw_line` antialiases, which
## on a 480x270 canvas of hard pixel art reads as a smudge, and on the diagonals of
## the calendar's X stamp it is unmistakable.
##
## Extracted from RunCalendar once JournalTitle needed the same strokes for its
## underline. All static, no state — the same shape as Palette / PixelUI.

## Deterministic -1 / 0 / +1 from two integers.
##
## The step is a texel wide because the page is drawn on the pixel grid — there is
## no such thing as half a texel off true — so the only lever on how much wobble
## READS is how often a segment steps at all. This table weights that: six of its
## eight slots are 0, so roughly a quarter of segments move and a run of straight
## ones usually separates them. An even -1/0/+1 split moves two segments in three
## and reads as a torn edge rather than a hand-ruled line.
const OFFSETS: PackedInt32Array = [0, 0, 0, -1, 0, 0, 0, 1]


static func wobble(a: int, b: int) -> int:
	var h: int = (a * 73856093) ^ ((b + 1) * 19349663)
	h ^= h >> 13
	h *= 1274126177
	return OFFSETS[absi(h >> 7) % OFFSETS.size()]


## One ruled line, broken into `segment_px` runs each nudged up to `amp` texels off
## true. Each step is bridged by a short perpendicular rect, so the line stays
## continuous however the segments land — a stepped 1px rule with no bridge is a
## dotted rule. `key` identifies the line: two lines sharing it wobble identically,
## so spread the keys of lines that sit near each other.
static func rule(ci: CanvasItem, from: Vector2i, length: int, thick: int,
		horizontal: bool, color: Color, amp: int, key: int,
		segment_px: int = 14) -> void:
	if amp <= 0:
		ci.draw_rect(_span_rect(from, length, thick, horizontal), color)
		return
	var seg: int = maxi(2, segment_px)
	var i: int = 0
	var s: int = 0
	var prev: int = 0
	while i < length:
		var run: int = mini(seg, length - i)
		var off: int = wobble(key, s) * amp
		ci.draw_rect(
			_span_rect(_step(from, i, off, horizontal), run, thick, horizontal), color)
		if s > 0 and off != prev:
			var lo: int = mini(off, prev)
			var bridge: int = absi(off - prev) + thick
			ci.draw_rect(
				_span_rect(_step(from, i, lo, horizontal), bridge, thick, not horizontal),
				color)
		prev = off
		i += run
		s += 1


## A hollow rectangle of four `rule` strokes. Drawn AFTER any inner rules it
## surrounds: the frame is the thicker stroke, so painting it last hides the inner
## rules' wobbling ends instead of leaving them poking out of the corners.
static func frame(ci: CanvasItem, rect: Rect2, width: int, color: Color,
		amp: int, key: int, segment_px: int = 14) -> void:
	var origin := Vector2i(rect.position)
	var w: int = int(rect.size.x)
	var h: int = int(rect.size.y)
	rule(ci, origin, w, width, true, color, amp, key + 0, segment_px)
	rule(ci, origin + Vector2i(0, h - width), w, width, true, color, amp, key + 1, segment_px)
	rule(ci, origin, h, width, false, color, amp, key + 2, segment_px)
	rule(ci, origin + Vector2i(w - width, 0), h, width, false, color, amp, key + 3, segment_px)


# Rect `length` along the line and `thick` across it.
static func _span_rect(at: Vector2i, length: int, thick: int, horizontal: bool) -> Rect2:
	return Rect2(Vector2(at),
		Vector2(length, thick) if horizontal else Vector2(thick, length))


# `along` texels down the line from `from`, `perp` texels off it.
static func _step(from: Vector2i, along: int, perp: int, horizontal: bool) -> Vector2i:
	return from + (Vector2i(along, perp) if horizontal else Vector2i(perp, along))
