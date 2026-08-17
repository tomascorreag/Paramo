class_name JournalTooltip
extends Control

## What the journal says about the shop entry the pointer is on: two little
## sentences in mouse glyphs, one under the picture and one over it.
##
##            [right click] [info]      <- over the art: read about it (a STUB)
##                 ( art )
##            [left click] [coin] 20    <- under the art: buy it, for this much
##
## The BUY line is only drawn when the entry is actually for sale; an entry that
## is owned, or priced past what the player holds, still prints its price (faded)
## but gets no mouse to promise a click with. The READ line is always there — the
## info verb is about the thing, not the transaction — and nothing is wired to
## right click yet.
##
## THE PRICE LIVES HERE, not in the page. It used to be printed inside the
## entry's cell, through the ink shader, which put it under three constraints
## that had nothing to do with prices: it had to fit a 20-texel cell, sit clear
## of both seams of a page-warp block, and be a child TextureRect to get its own
## `dim`. Pairing it with the click glyph — one group, one line, "click here, pay
## this" — is what took it out of the paper, and the constraints went with it.
##
## BARE GLYPHS — no panel, no frame, no word. The journal is a diegetic object,
## and a framed UI tag floating over the paper reads as the game interrupting the
## book. Mice and digits in the page's own ink read as part of the book. They also
## need no translation: the verb is the glyph and the price is a number.
##
## Code-built and spawned by JournalShopInput rather than authored in
## field_journal.tscn, per this project's three-ways-to-build-UI rule: it has no
## fixed position (it follows whichever entry the pointer is on). radial_menu.gd
## and loading_overlay.gd are the same family.
##
## It is NOT inside the page, and cannot be. Everything under the page's
## SubViewport goes through page_warp.gdshader and is clipped to the paper, so a
## glyph drawn there would shear across a warp block and be cut off at the page
## edge. This floats OVER the book instead, in the same brown. The book and the
## page are 1:1 with each other, so 8px type here is the same 8px type the page
## sets — moving the price out did not resize it.
##
## The art is a white mask (the UX atlas convention), so drawing it in the ink
## colour is the whole recolour — and the caller passes the section's own
## `text_color`, which keeps these glyphs and the page's lettering the same
## palette entry by construction. Note this is NOT the journal_ink shader: that
## shader overwrites COLOR and would map a flat white mask to one ramp stop
## regardless of what the page is set to.
##
## Mouse-transparent. It appears under the pointer by definition, and a tooltip
## that ate the click it is advertising would be its own worst bug.

## The mouse glyphs, left and right button cut out — the same art the FTUE leads
## its click steps with. One glyph for "this is a left click" across the game.
const _CLICK_ICON: Texture2D = preload("res://assets/sprites/UX/icons/click.tres")
const _RIGHT_CLICK_ICON: Texture2D = preload("res://assets/sprites/UX/icons/rightclick.tres")
## Painted into the UX atlas beside the two mice, in their idiom (a 9x9 white
## silhouette with the letterform knocked out of it, the way the mice knock out
## the pressed button).
const _INFO_ICON: Texture2D = preload("res://assets/sprites/UX/icons/info.tres")
## The token coin — the same 8px glyph RunCalendar stamps day yields with,
## deliberately, so a price here and a yield on the facing page read as the same
## currency rather than as two unrelated numbers on one spread.
const _COIN_ICON: Texture2D = preload("res://assets/sprites/UX/icons/money_small.tres")

## Line height of a group, in logical pixels — the mouse art's own 16.
const ROW_PX: float = 16.0

## Horizontal pitch between two 16px glyphs in the same group.
##
## SMALLER THAN THE ART, deliberately: a mouse inks 9 of its 16 columns and sits
## in the middle of them, so a 16px pitch leaves 7 texels of hole between two
## glyphs and the pair stops reading as a pair. 10 puts a texel of paper between
## the inked shapes without any of them overlapping.
const GLYPH_PITCH_PX: float = 10.0

## Where the price starts, measured from the left of the click glyph's 16px box.
## Same reasoning as the pitch: the mouse's ink ends at column 13, so this leaves
## 3 texels of paper before the coin rather than the 3 it would have if the boxes
## simply abutted.
const PRICE_OFFSET_PX: float = 16.0

## The coin's footprint and the air between it and its digits, matching
## RunCalendar's stat glyphs exactly (8px art, 1px gap).
const COIN_PX: float = 8.0
const COIN_GAP_PX: float = 1.0

## Prices print in the data face at the data size — Tiny5 at 8, straight off the
## theme. Same figures as the calendar's day stats; a price set any larger stops
## being an annotation on the picture and starts competing with it.
const PRICE_FONT_SIZE: int = 8

## How far each group is pulled back INTO the art, in logical pixels. Sitting
## exactly on the art's edge (0) leaves a group reading as a loose object beside
## the entry; a few texels of overlap makes it a cursor resting on the picture.
const OVERLAP_PX: float = 5.0

## What an unaffordable price fades to. The section fades a locked swatch by the
## same amount (JournalKnownSet.LOCKED_ALPHA) — one number would be better, but
## that one is a shader `dim` and this is an alpha, so they are the same value in
## two units rather than a constant to share.
const UNAFFORDABLE_ALPHA: float = 0.4

## Length and shape of the recoil on a click the player cannot pay for.
const DENY_DURATION: float = 0.18

## Whether the left-click glyph is part of the buy line right now — i.e. whether
## this entry can actually be bought. Read by the tests; set through `show_for`.
var buyable: bool = false
## The price on the buy line, or 0 for an entry that has nothing to charge.
var price: int = 0

var _ink: Color = Color.WHITE
var _affordable: bool = true
## Top-left of each group, in this node's local space. Filled by `_lay_out`.
var _read_at: Vector2 = Vector2.ZERO
var _buy_at: Vector2 = Vector2.ZERO
var _deny_phase: float = 0.0
var _deny_tween: Tween


func _init() -> void:
	name = "ShopTooltip"
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	visible = false
	# IGNORE, not PASS: this sits directly over the book's hit area, and a PASS
	# still blocks nothing but costs a picking test per event.
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Put the two groups on `art` (the entry's inked rect, in this node's parent's
## space) and show them, in `ink`.
##
## `bounds` is what neither group may leave. Its TOP is the section's swatch row,
## not the book's: a swatch sits a few texels down inside its cell, so a read line
## placed above the ART alone lands squarely on the heading's rule, in the same
## brown, and neither survives (measured, on the fence). Clamped to the row it
## comes to rest on the upper part of the picture, which is where a cursor belongs
## anyway.
##
## `for_sale` drops the left-click glyph: an entry that is owned, or priced past
## what the player holds, must not be offered a buy verb that would be refused.
## `cost` of 0 drops the price with it — an owned entry is not free, it is done.
func show_for(art: Rect2, bounds: Rect2, ink: Color, for_sale: bool,
		cost: int = 0, affordable: bool = true) -> void:
	_ink = ink
	buyable = for_sale
	price = maxi(0, cost)
	_affordable = affordable
	_lay_out(art, bounds)
	visible = true
	queue_redraw()


func hide_tip() -> void:
	visible = false


## Redden the price for a click the player cannot pay for. The swatch's own
## recoil is the section's business (JournalKnownSet.flash_denied); this is the
## other half of the same refusal, and it lives here because the price does.
func flash_denied() -> void:
	if _deny_tween and _deny_tween.is_valid():
		_deny_tween.kill()
	# Full red NOW, not on the tween's first process frame. A refusal answers the
	# click that caused it, and a tween only writes its start value a frame later.
	_set_deny_phase(1.0)
	# Decaying rather than constant: a flash that fades reads as the page
	# absorbing the poke, where an even one reads as a broken animation.
	_deny_tween = create_tween()
	_deny_tween.tween_method(_set_deny_phase, 1.0, 0.0, DENY_DURATION)


func _set_deny_phase(value: float) -> void:
	_deny_phase = value
	queue_redraw()


## Width of the read line: right click, then info.
func _read_width() -> float:
	return GLYPH_PITCH_PX + _INFO_ICON.get_size().x


## Width of the buy line: the click glyph if the entry is for sale, then the
## price if it has one. Zero when it has neither, which is what hides the line.
func _buy_width() -> float:
	var w: float = 0.0
	if buyable:
		w = PRICE_OFFSET_PX if price > 0 else _CLICK_ICON.get_size().x
	if price > 0:
		w += COIN_PX + COIN_GAP_PX + _digits_width()
	return w


func _digits_width() -> float:
	var face := get_theme_font(&"font", &"Label")
	if face == null or price <= 0:
		return 0.0
	return face.get_string_size(str(price), HORIZONTAL_ALIGNMENT_LEFT, -1,
			PRICE_FONT_SIZE).x


# Both groups are centred on the art and clamped into `bounds`; this node's rect
# is their union, so `position`/`size` still describe everything it draws.
#
# Whole pixels throughout: this is 16px and 8px pixel art over a 1:1 book, and a
# half-texel origin resamples it into a blur — the same rule the swatches' own
# positions are floored by.
func _lay_out(art: Rect2, bounds: Rect2) -> void:
	var read_w := _read_width()
	var buy_w := _buy_width()
	var read_x := _centre_x(art, bounds, read_w)
	var buy_x := _centre_x(art, bounds, buy_w)
	var read_y := maxf(art.position.y + OVERLAP_PX - ROW_PX, bounds.position.y)
	var buy_y := minf(art.end.y - OVERLAP_PX, bounds.end.y - ROW_PX)
	var left := minf(read_x, buy_x) if buy_w > 0.0 else read_x
	var right := maxf(read_x + read_w, buy_x + buy_w) if buy_w > 0.0 \
			else read_x + read_w
	position = Vector2(left, minf(read_y, buy_y)).floor()
	size = Vector2(right - left, maxf(read_y, buy_y) + ROW_PX - position.y).ceil()
	_read_at = Vector2(read_x, read_y).floor() - position
	_buy_at = Vector2(buy_x, buy_y).floor() - position


func _centre_x(art: Rect2, bounds: Rect2, width: float) -> float:
	return clampf(art.get_center().x - width * 0.5, bounds.position.x,
			maxf(bounds.position.x, bounds.end.x - width))


func _draw() -> void:
	draw_texture(_RIGHT_CLICK_ICON, _read_at, _ink)
	draw_texture(_INFO_ICON, _read_at + Vector2(GLYPH_PITCH_PX, 0.0), _ink)
	var x: float = _buy_at.x
	if buyable:
		draw_texture(_CLICK_ICON, Vector2(x, _buy_at.y), _ink)
		x += PRICE_OFFSET_PX if price > 0 else 0.0
	if price > 0:
		_draw_price(Vector2(x, _buy_at.y))


# The coin and its digits, vertically centred in the row so they sit on the same
# optical line as the 16px mouse beside them.
func _draw_price(at: Vector2) -> void:
	var face := get_theme_font(&"font", &"Label")
	if face == null:
		return
	var colour := _ink if _affordable \
			else Palette.with_alpha(_ink, UNAFFORDABLE_ALPHA)
	if _deny_phase > 0.0:
		# The one place this page prints something that is NOT a journal ink ramp
		# stop. A refusal has to read at a glance, and the ramps are low contrast
		# by authoring (see the tests' minimum-luminance guard) — every red in
		# them sits within a shade of the brown it would replace. It is transient
		# and code-side, so it never reaches the authored-colour rule the ramps
		# exist to enforce.
		colour = Palette.with_alpha(Palette.DANGER, _deny_phase)
	# The coin keeps its OWN colours — it is the only thing in this tag that is not
	# a white mask, and the gold is what makes it read as the same currency as the
	# count in the page's supplies panel a few rows above it. Only its ALPHA
	# follows the price, so an unaffordable pair fades together; the denial red is
	# the one case that overrides the art, because a refusal has to read at a
	# glance.
	var coin_tint := Color(1.0, 1.0, 1.0, colour.a) if _deny_phase <= 0.0 \
			else colour
	draw_texture(_COIN_ICON,
			Vector2(at.x, at.y + floorf((ROW_PX - COIN_PX) * 0.5)), coin_tint)
	var ascent := face.get_ascent(PRICE_FONT_SIZE)
	var descent := face.get_descent(PRICE_FONT_SIZE)
	var baseline := at.y + floorf((ROW_PX - ascent - descent) * 0.5) + ascent
	draw_string(face, Vector2(at.x + COIN_PX + COIN_GAP_PX, baseline), str(price),
			HORIZONTAL_ALIGNMENT_LEFT, -1, PRICE_FONT_SIZE, colour)
