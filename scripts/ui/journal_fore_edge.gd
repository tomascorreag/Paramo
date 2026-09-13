class_name JournalForeEdge
extends Control

## The ONE tab on the fore-edge of the journal: the way to the OTHER spread,
## hanging off the side of the book that spread lies towards.
##
##      ┌───────────┬───────────┐          ┌───────────┬───────────┐
##  ┌───┤           │           ├───┐      │           │           │
##  │run│ bitácora  │ bitácora  │bit│      │  calendar │  shop     │
##  └───┤           │           ├───┘      │           │           │
##      └───────────┴───────────┘          └───────────┴───────────┘
##     on the bitácora: the run tab      on the run spread: the bitácora
##     on the LEFT (the shop is back      tab on the RIGHT (the notes are
##     that way)                          forward). Nothing identified yet:
##                                        no tab, the bitácora is closed.
##
## The tab is one frame of BookTab.png (a 16x16 sheet: TUCKED on top, 12
## wide, and EXTENDED below it, 16 wide, for the pointer over it — each a
## flat side that meets the page, a rounded side that sticks out, P11 rim
## and P12 fill) stretched ALONG the tab to fit its label — three slices,
## the caps kept (two lit rows at the top, three shadowed at the foot) and
## the middle rows repeated, so the rounded ends never scale — one texel off
## the page's outer edge, and mirrored (a negative-width draw) for the left
## side. The label is Tiny5 at 8, turned a quarter turn with
## draw_set_transform at an integer origin (an exact 90° keeps every texel on
## the grid; anything else resamples the face into a blur), anchored to the
## tab's OUTER edge so it slides out with the tab: the right tab reads top to
## bottom, the left one bottom to top — each turned so its letters' feet
## face the page. Tiny5 has the accented glyphs, so "bitácora" is spelt.
##
## Sits under Book/BookArt, authored AFTER Pages, so it draws over the paper
## and is picked before BookHit — which spans x 48..432 and overlaps both
## tabs. It is NOT inside a page: everything under a page's SubViewport is
## bent by page_warp.gdshader and clipped to the paper, and a tab has to hang
## OFF the paper to read as a tab. `_has_point` is overridden so only the
## shown tab takes a click — the tab as drawn, plus its REACH: the paper
## beside it, `REACH_PX` in from the page's edge over the tab's own rows,
## which is the corners' strip and would otherwise lift a corner for a
## pointer heading for the tab. The rest of this node's rect falls through
## to whatever is under it — the corners' strips, the scrim that closes the
## book. The tab sits at the middle of the page's height.
##
## Turning page by page is the bent corners' job (JournalPageCorners).

## Which side of the book a tab hangs off.
enum Side { LEFT, RIGHT }


## One tab: the spread it opens, its label key and its side.
class Tab:
	var spread: StringName
	var key: String
	var side: JournalForeEdge.Side
	func _init(s: StringName, k: String, sd: JournalForeEdge.Side) -> void:
		spread = s
		key = k
		side = sd


## The tab sheet: two frames stacked, flat side at x 0 (meets the page),
## rounded side sticking out to the right.
@export var texture: Texture2D = preload("res://assets/sprites/UX/Panels/BookTab.png")

## The frames on the sheet: tucked (the rest state) and extended (the pointer
## over the tab). Each frame's width is the tab's width in that state.
const FRAME_TUCKED: Rect2i = Rect2i(0, 0, 12, 8)
const FRAME_EXTENDED: Rect2i = Rect2i(0, 8, 16, 8)

## The rows of each rounded cap: the top one is lit, the bottom one carries
## the rim's shadow, so they differ.
const CAP_TOP_ROWS: int = 2
const CAP_BOTTOM_ROWS: int = 3

## Air between the page's outer edge and the tab's flat side.
const GAP_PX: int = 1

## The pages' outer edges, in BookArt space (field_journal.tscn: PageLeft
## x 60..217, PageRight x 264..420).
const PAGE_LEFT_EDGE_X: int = 60
const PAGE_RIGHT_EDGE_X: int = 420

## The pages' rows (PageLeft / PageRight y 21..252); the tab is centred on them.
const PAGE_TOP_Y: int = 21
const PAGE_BOTTOM_Y: int = 252

## How far INTO the page the tab's reach goes: the corners' strip
## (JournalPageCorners.REACH_PX), so beside the tab the whole strip is the
## tab's and none of it a corner's.
const REACH_PX: int = 20

const FONT_SIZE: int = 8
## Air at each end of a tab's label, along the tab, caps included.
const LABEL_PAD_PX: int = 6
## Tiny5-8's letters stand this many rows on the baseline (the cap height).
const LETTER_ROWS: int = 5
## Air between the letters and the tab's outer (rounded) edge, across the tab.
const LABEL_INSET_PX: int = 3

const INK: Color = Palette.P06

var _tabs: Array[Tab] = []
var _journal: FieldJournal = null
## The pointer is over the shown tab, which is drawn extended.
var _extended: bool = false


func _ready() -> void:
	name = "ForeEdge"
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	mouse_filter = Control.MOUSE_FILTER_STOP
	_tabs = [
		Tab.new(&"run", "JOURNAL_TAB_RUN", Side.LEFT),
		Tab.new(&"bitacora", "JOURNAL_TAB_BITACORA", Side.RIGHT),
	]
	var j := journal()
	if j != null:
		j.spread_changed.connect(func(_s: StringName) -> void: hover(get_local_mouse_position()))
		j.browsable_changed.connect(func() -> void: hover(get_local_mouse_position()))
		j.closed.connect(func() -> void: hover(Vector2(-1000, -1000)))


## The journal this node navigates. `owner` when authored inside
## field_journal.tscn (the normal case), else the one in the "journal" group.
func journal() -> FieldJournal:
	if _journal != null and is_instance_valid(_journal):
		return _journal
	_journal = owner as FieldJournal
	if _journal == null and is_inside_tree():
		_journal = get_tree().get_first_node_in_group(&"journal") as FieldJournal
	return _journal


## Both tabs, whether or not they show.
func tabs() -> Array[Tab]:
	return _tabs


func tab(spread: StringName) -> Tab:
	for t: Tab in _tabs:
		if t.spread == spread:
			return t
	return null


## The tab showing now — the way to the spread the book is NOT open on — or
## null when there is nowhere to go (nothing identified: no bitácora).
func shown() -> Tab:
	var j := journal()
	if j == null:
		return null
	if j.spread() == &"bitacora":
		return tab(&"run")
	return tab(&"bitacora") if j.has_bitacora() else null


## Whether the shown tab is drawn extended (the pointer is over it).
func is_extended() -> bool:
	return _extended


## The frame drawn for a tab in a state.
static func frame(extended: bool) -> Rect2i:
	return FRAME_EXTENDED if extended else FRAME_TUCKED


## Where `t` sits, in this node's (BookArt's) space, whether or not it shows:
## its flat side one texel off its page's outer edge, as wide as the frame
## for `extended`, as long as its label plus the pads, centred on the page's
## height.
func tab_rect(t: Tab, extended: bool = _extended) -> Rect2i:
	var w: int = frame(extended).size.x
	var length: int = ceili(label_length_px(t.key)) + 2 * LABEL_PAD_PX
	var x: int = PAGE_RIGHT_EDGE_X + GAP_PX if t.side == Side.RIGHT \
		else PAGE_LEFT_EDGE_X - GAP_PX - w
	return Rect2i(x, (PAGE_TOP_Y + PAGE_BOTTOM_Y - length) / 2, w, length)


## What answers to `t`: its rect as drawn, grown INTO the page by the gap
## and REACH_PX over the tab's own rows, so a pointer near the tab on the
## paper extends it and clicks it rather than lifting a corner.
func reach_rect(t: Tab, extended: bool = _extended) -> Rect2i:
	var r := tab_rect(t, extended)
	var into: int = GAP_PX + REACH_PX
	return r.grow_individual(into, 0, 0, 0) if t.side == Side.RIGHT \
		else r.grow_individual(0, 0, into, 0)


## Pointer at `local`: the shown tab extends while the pointer is over it or
## in its reach (over the tab as it is drawn now, so an extended tab stays
## out until the pointer leaves its wider rect). Public so tests and the
## preview tools set the hover without synthesising events.
func hover(local: Vector2) -> void:
	var over: bool = _has_point(local)
	if over != _extended:
		_extended = over
	queue_redraw()


func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseMotion) or not is_visible_in_tree():
		return
	hover(get_local_mouse_position())


## Only the shown tab, as drawn now, and its reach are hit; everything else
## falls through.
func _has_point(point: Vector2) -> bool:
	var t := shown()
	return t != null and Rect2(reach_rect(t)).has_point(point)


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if handle_click(mb.position):
		accept_event()


## The click path, public so tests drive it without synthesising events.
func handle_click(local: Vector2) -> bool:
	var j := journal()
	if j == null or not _has_point(local):
		return false
	j.show_spread(shown().spread)
	hover(local)
	return true


## Width the label takes ALONG the tab.
func label_length_px(key: String) -> float:
	var f := get_theme_font(&"font", &"Label")
	if f == null:
		return 0.0
	return f.get_string_size(tr(key), HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x


func _draw() -> void:
	var t := shown()
	if t == null or texture == null:
		return
	var r := Rect2(tab_rect(t))
	_draw_tab(r, frame(_extended), t.side == Side.LEFT)
	var f := get_theme_font(&"font", &"Label")
	if f == null:
		return
	# The label is turned a quarter turn, and the baseline sits at a world x
	# with the letters growing AWAY from the page: on the right, clockwise —
	# local +x runs DOWN the tab, the letters' LETTER_ROWS grow rightward from
	# the baseline — so it reads top to bottom; on the left, anticlockwise —
	# local +x runs UP, the letters grow leftward — so it reads bottom to
	# top. Either way the letters' far column is LABEL_INSET_PX inside the
	# tab's OUTER edge, which is what keeps the label with the tab when it
	# extends, and the run starts LABEL_PAD_PX in from the end it reads from.
	# (The baseline's own pixel row lands on ox clockwise and on ox - 1
	# anticlockwise — the row spans local y in [-1, 0) — hence the extra 1.)
	var ox: float
	var oy: float
	var angle: float
	if t.side == Side.RIGHT:
		ox = r.end.x - 1 - LABEL_INSET_PX - (LETTER_ROWS - 1)
		oy = r.position.y + LABEL_PAD_PX
		angle = PI * 0.5
	else:
		ox = r.position.x + LABEL_INSET_PX + LETTER_ROWS
		oy = r.end.y - LABEL_PAD_PX
		angle = -PI * 0.5
	draw_set_transform(Vector2(ox, oy), angle)
	draw_string(f, Vector2(0, 0), tr(t.key), HORIZONTAL_ALIGNMENT_LEFT, -1,
		FONT_SIZE, INK)
	draw_set_transform(Vector2.ZERO, 0.0)


# Three slices of `fr` along the tab: the caps at their own size, the middle
# rows (all alike) stretched to whatever is left. `mirrored` flips every
# slice across, so the flat side faces the page on the left as well.
func _draw_tab(r: Rect2, fr: Rect2i, mirrored: bool) -> void:
	var w: float = float(fr.size.x)
	var top: float = float(CAP_TOP_ROWS)
	var bottom: float = float(CAP_BOTTOM_ROWS)
	var fx: float = float(fr.position.x)
	var fy: float = float(fr.position.y)
	var fh: float = float(fr.size.y)
	var slices: Array[Array] = [
		[Rect2(fx, fy, w, top), Rect2(r.position, Vector2(w, top))],
		[Rect2(fx, fy + top, w, fh - top - bottom),
			Rect2(r.position + Vector2(0, top), Vector2(w, r.size.y - top - bottom))],
		[Rect2(fx, fy + fh - bottom, w, bottom),
			Rect2(r.position + Vector2(0, r.size.y - bottom), Vector2(w, bottom))],
	]
	for s: Array in slices:
		var dst: Rect2 = s[1]
		if mirrored:
			# A negative width draws the region flipped across; the rect's
			# position stays its top-left (the size is only made absolute).
			dst = Rect2(dst.position, Vector2(-w, dst.size.y))
		draw_texture_rect_region(texture, dst, s[0])
