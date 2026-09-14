class_name JournalPageCorners
extends Control

## The bent page corners that turn the journal's pages.
##
##     ┌──┐                  ┌──┐
##     │TL│   left page      │TR│   right page      TL / BL: the page BEFORE
##     └──┘                  └──┘                   TR / BR: the page AFTER
##     ┌──┐                  ┌──┐
##     │BL│                  │BR│
##     └──┘                  └──┘
##
## BookPageCrease.png is a full 480x270 overlay of Book.png with all four
## corners bent up. Only ONE corner shows at a time: the pointer is near a
## page's OUTER EDGE — a strip `REACH_PX` into the paper from that edge and
## out to the cover's rim, the full height of the page (`zone_rect`) — and
## the corner on that half of the strip lifts (top half, top corner), if it
## has somewhere to turn to: a left corner needs a page before this one, a
## right corner a page after. A click ANYWHERE in that strip turns the page
## that way: the hit box is the zone the corner lifted for, not the corner's
## own ink, so what reacts to the hover is what answers the click. The book
## does not wrap: on the run spread there is no left corner, on the last
## pair no right one. The fore-edge tab lives inside one of the strips and
## keeps priority — a point on it, or in its reach across the strip beside
## it, lifts nothing.
##
## The page ORDER is FieldJournal's `page_index()`: the run spread first, then
## the bitácora's pairs in browsable order (none until something is
## identified), so turning right from the run spread lands on the first
## species and turning left from the first species goes back to the calendar.
## The tab still jumps.
##
## Sits under Book/BookArt, authored AFTER ForeEdge, so it draws over the
## paper and is picked before BookHit (x 48..432, which every corner lies
## inside). `_has_point` is overridden to the SHOWN corner's zone only: the
## rest of the paper keeps its own input — the shop row's hover and clicks,
## the scrim's close. The pointer is watched from `_input`, not `_gui_input`,
## because a node that is only hit inside its corners would never hear the
## pointer APPROACHING one.
##
## The art is drawn by REGION: the sprite's pixel space is BookArt's own
## (both 480x270), so a corner's rect is the same rectangle in both, and the
## rest of the sheet is simply never sampled.

## Which corner. Order matters: index / 2 is the row, index % 2 the column.
enum Corner { TL, TR, BL, BR }

## The sheet with all four corners bent. Same size as Book.png.
@export var texture: Texture2D = preload("res://assets/sprites/UX/Panels/BookPageCrease.png")

## Each corner's ink, in this node's (BookArt's) space: where the sheet's
## OPAQUE texels differ from Book.png, per quadrant (2026-09-12, 35x79 each;
## the test re-measures them against both sprites so a repaint cannot
## silently move a hit box — and the measure holds whether the sheet is a
## transparent overlay or a full repaint of the cover, both of which it has
## been).
const CORNER_RECTS: Array[Rect2i] = [
	Rect2i(60, 25, 35, 79),    # TL
	Rect2i(385, 25, 35, 79),   # TR
	Rect2i(60, 169, 35, 79),   # BL
	Rect2i(385, 169, 35, 79),  # BR
]

## How far INTO the paper from its outer edge the lift zone reaches.
const REACH_PX: int = 20

## The pages' outer edges and rows, in BookArt space (field_journal.tscn:
## PageLeft x 60..217, PageRight x 264..420, both y 21..252), and the cover's
## rim (Book.png's paper stops at x 48 / 432).
const PAGE_LEFT_EDGE_X: int = 60
const PAGE_RIGHT_EDGE_X: int = 420
const COVER_LEFT_X: int = 48
const COVER_RIGHT_X: int = 432
const PAGE_TOP_Y: int = 21
const PAGE_BOTTOM_Y: int = 252

## Which corner is shown, or -1.
var _shown: int = -1
var _journal: FieldJournal = null


func _ready() -> void:
	name = "PageCorners"
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	mouse_filter = Control.MOUSE_FILTER_STOP
	var j := journal()
	if j != null:
		# What has somewhere to turn to changes with the page; re-read the
		# pointer so a corner that just lost its page drops without motion.
		j.spread_changed.connect(func(_s: StringName) -> void: hover(get_local_mouse_position()))
		j.species_changed.connect(func(_id: StringName) -> void: hover(get_local_mouse_position()))
		j.browsable_changed.connect(func() -> void: hover(get_local_mouse_position()))
		j.closed.connect(func() -> void: hover(Vector2(-1000, -1000)))


## The journal this node turns. `owner` when authored inside
## field_journal.tscn (the normal case), else the one in the "journal" group.
func journal() -> FieldJournal:
	if _journal != null and is_instance_valid(_journal):
		return _journal
	_journal = owner as FieldJournal
	if _journal == null and is_inside_tree():
		_journal = get_tree().get_first_node_in_group(&"journal") as FieldJournal
	return _journal


## The corner showing now, or -1.
func shown() -> int:
	return _shown


## Whether corner `c` has a page to turn to.
func is_enabled(c: int) -> bool:
	var j := journal()
	if j == null:
		return false
	if c % 2 == 0:
		return j.page_index() > 0
	return j.page_index() < j.page_count() - 1


## The strip of the page that lifts corner `c` and answers its click: from
## the cover's rim to REACH_PX inside the page's outer edge, over that
## corner's half of the page's height — grown to the corner's own ink where
## that reaches further in, so the lifted corner is always clickable.
func zone_rect(c: int) -> Rect2i:
	var x0: int = COVER_LEFT_X if c % 2 == 0 else PAGE_RIGHT_EDGE_X - REACH_PX
	var x1: int = PAGE_LEFT_EDGE_X + REACH_PX if c % 2 == 0 else COVER_RIGHT_X
	var mid: int = (PAGE_TOP_Y + PAGE_BOTTOM_Y) / 2
	var y0: int = PAGE_TOP_Y if c < 2 else mid
	var y1: int = mid if c < 2 else PAGE_BOTTOM_Y
	return Rect2i(x0, y0, x1 - x0, y1 - y0).merge(CORNER_RECTS[c])


## The corner the pointer at `local` would lift: the ENABLED one whose zone
## holds the point, or -1. A point on a fore-edge tab lifts nothing.
func corner_for(local: Vector2) -> int:
	if _on_a_tab(local):
		return -1
	for c: int in CORNER_RECTS.size():
		if is_enabled(c) and Rect2(zone_rect(c)).has_point(local):
			return c
	return -1


# The tab (JournalForeEdge, a sibling) sits inside a strip; it is authored
# before this node, so without this a lifted corner would take its click.
func _on_a_tab(local: Vector2) -> bool:
	var edge := get_parent().get_node_or_null("ForeEdge") as Control
	if edge == null:
		return false
	return edge._has_point(local - edge.position)


## Pointer at `local` (this node's space): show the corner it is near. Public
## so tests and the preview tool set the hover without synthesising events.
func hover(local: Vector2) -> void:
	var c: int = corner_for(local)
	if c != _shown:
		_shown = c
		queue_redraw()


func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseMotion) or not is_visible_in_tree():
		return
	hover(get_local_mouse_position())


## Only the shown corner's zone is hit — exactly what lifted it — so a
## click lands wherever the hover reacted; everything else falls through.
func _has_point(point: Vector2) -> bool:
	return _shown >= 0 and Rect2(zone_rect(_shown)).has_point(point) and not _on_a_tab(point)


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if handle_click(mb.position):
		accept_event()


## The click path, public so tests drive it. Turns the page the shown corner
## points at; false if `local` is not in the shown corner's zone.
func handle_click(local: Vector2) -> bool:
	var j := journal()
	if j == null or not _has_point(local):
		return false
	var turned: bool = j.turn_page(-1 if _shown % 2 == 0 else 1)
	hover(local)
	return turned


func _draw() -> void:
	if _shown < 0 or texture == null:
		return
	var r := Rect2(CORNER_RECTS[_shown])
	draw_texture_rect_region(texture, r, r)
