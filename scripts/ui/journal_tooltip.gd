class_name JournalTooltip
extends TextureRect

## The little mouse glyph that appears over a shop entry the player can actually
## afford: "this picture is a button, click it".
##
## A BARE GLYPH — no panel, no frame, no word. The journal is a diegetic object,
## and a framed UI tag floating over the paper reads as the game interrupting the
## book. One brown mouse in the page's own ink reads as part of the book. It also
## needs no translation, which is the other half of the argument: the word it
## would otherwise carry ("buy" / "comprar") is already implied by the price
## printed under the swatch.
##
## Code-built and spawned by JournalShopInput rather than authored in
## field_journal.tscn, per this project's three-ways-to-build-UI rule: it has no
## fixed position (it follows whichever entry the pointer is on). radial_menu.gd
## and loading_overlay.gd are the same family.
##
## It is NOT inside the page, and cannot be. Everything under the page's
## SubViewport goes through page_warp.gdshader and is clipped to the paper, so a
## glyph drawn there would shear across a warp block and be cut off at the page
## edge. This floats OVER the book instead, in the same brown.
##
## The art is a white mask (the UX atlas convention), so `self_modulate` is the
## whole recolour — and the caller sets it from the section's own `text_color`,
## which keeps the glyph and the page's ink the same palette entry by
## construction. Note this is NOT the journal_ink shader: that shader overwrites
## COLOR and would map a flat white mask to one ramp stop regardless of what the
## page is set to.
##
## Mouse-transparent. It appears under the pointer by definition, and a tooltip
## that ate the click it is advertising would be its own worst bug.

## The mouse glyph, left button cut out — the same art the FTUE leads its click
## steps with. One glyph for "this is a left click" across the whole game.
const _CLICK_ICON: Texture2D = preload("res://assets/sprites/UX/icons/click.tres")

## How far the glyph is pulled back INTO the swatch's top-right corner, in
## logical pixels. Centring it exactly on the corner (0) leaves it reading as a
## loose object beside the entry; a few texels of overlap makes it a cursor
## resting on the picture.
##
## The corner, and not "floating above the entry", because there is nothing above
## it: the swatch row sits directly under its heading's rule (see
## JournalKnownSet.row_gap_px), so a glyph above the art lands ON the rule, in
## the same brown, and neither survives. The corner is inside the entry's own
## cell, where nothing else on the page can reach.
const OVERLAP_PX: float = 5.0


func _init() -> void:
	name = "ShopTooltip"
	texture = _CLICK_ICON
	# Sized to the art, in _init rather than by a container: this node has no
	# layout parent, and show_above needs a real size in the frame it is called.
	custom_minimum_size = _CLICK_ICON.get_size()
	size = _CLICK_ICON.get_size()
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	visible = false
	# IGNORE, not PASS: this sits directly over the book's hit area, and a PASS
	# still blocks nothing but costs a picking test per event.
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Tuck the glyph into the top-right corner of `art` (the entry's inked rect, in
## this node's parent's space) and show it, in `ink`.
##
## `bounds` is the rect it may not leave — the book. The rightmost entry of a
## section sits near the page edge, and the entry it names is the one thing on
## screen that cannot move to make room.
func show_over(art: Rect2, bounds: Rect2, ink: Color) -> void:
	self_modulate = ink
	var pos := Vector2(art.end.x - OVERLAP_PX, art.position.y - size.y + OVERLAP_PX)
	pos.x = clampf(pos.x, bounds.position.x, maxf(bounds.position.x, bounds.end.x - size.x))
	pos.y = maxf(pos.y, bounds.position.y)
	# Whole pixels: this is 16px pixel art, and a half-texel origin resamples it
	# into a blur — the same rule the swatches' own positions are floored by.
	position = pos.round()
	visible = true


func hide_tip() -> void:
	visible = false
