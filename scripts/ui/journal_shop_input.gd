class_name JournalShopInput
extends Control

## Attached to the journal's BookHit — the one Control that actually RECEIVES
## clicks on the open book (every page Control is mouse-IGNORE and the page
## SubViewports have gui_disable_input, by design: ink on paper takes no
## input). This script turns those absorbed clicks into shop purchases.
##
## No SubViewport input forwarding, no push_input: the page content is static
## layout, so a click is resolved by ARITHMETIC — BookHit local -> PageRight
## local (the SubViewportContainer is 1:1 with its viewport) -> Content ->
## section local -> JournalKnownSet.entry_at. Hit-testing happens in UNWARPED
## page space; the page warp displaces these rows by at most a few texels near
## the spine, which a 40x36 cell absorbs (accepted simplification, documented
## on entry_at).
##
## Purchases go through the scene's UnlockState (group lookup). Without one
## (preview tools, layout tests) every entry renders owned/full-ink and clicks
## fall through to nothing — the page behaves exactly as before the shop.
##
## HOVER runs through the identical arithmetic as the click, deliberately: the
## entry that lights up under the pointer and the entry a click would buy are
## computed by one code path, so they cannot disagree. What the hover DOES is
## JournalKnownSet's business (see HOVER_LIFT_PX there); this node only says where
## the pointer is.
##
## A hovered entry also gets two lines of mouse glyphs (JournalTooltip): left
## click and the price UNDER it, right click and info OVER it (a stub — nothing
## is wired to right click yet). They say the one thing the page cannot: the
## price is what it costs, but nothing on a book says a picture in it is a button
## or which button. The price travels with the click glyph rather than staying in
## the page, which is what took it out of the paper's warp blocks and cell widths.
##
## The BUY glyph runs through the same REFUSALS as the click, which is the other
## half of that claim: the tutorial gate is asked here as well as in _try_buy, and
## the section itself declines to react to an entry the player cannot afford. A
## swatch that lifts under a click glyph is a promise that a click will do
## something. The info half is not a promise about affording anything, so it shows
## over owned and unaffordable entries too.

## The right page's SubViewportContainer, whose local space equals its
## viewport's canvas space.
@export var page_right: Control = null
## PageRight/SubViewport/Content — the sections' parent inside the viewport.
@export var content: Control = null
## The shop sections, in any order. Their entry_ids name what they sell.
@export var sections: Array[JournalKnownSet] = []

const UNLOCKS_GROUP: StringName = &"unlocks"
const TOKENS: StringName = &"tokens"

var _unlocks: Node = null
## The "left click to buy" tag, built on first use — a journal that is never
## hovered never makes one.
var _tooltip: JournalTooltip = null


func _ready() -> void:
	ResourceLedger.resource_changed.connect(_on_resource_changed)
	_ready_hover()
	# Deferred: UnlockState joins its group in its own _ready, order unknown.
	_refresh_states.call_deferred()


func _ready_hover() -> void:
	# Nothing hovers what the pointer has left the book entirely for.
	mouse_exited.connect(_clear_hover)


func _gui_input(event: InputEvent) -> void:
	if page_right == null:
		return
	var motion := event as InputEventMouseMotion
	if motion != null:
		handle_hover(_to_page(motion.position))
		return
	var mb := event as InputEventMouseButton
	if mb == null or mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	if handle_click(_to_page(mb.position)):
		accept_event()


# BookHit-local -> canvas -> PageRight-local. Both live on the same CanvasLayer,
# so the global transforms are directly comparable.
func _to_page(local: Vector2) -> Vector2:
	var canvas_point: Vector2 = get_global_transform() * local
	return page_right.get_global_transform().affine_inverse() * canvas_point


## The hover path from PageRight-local space down, mirroring handle_click's
## arithmetic exactly so what lights up is always what a click would buy. Public
## for the same reason: tests drive it without synthesizing mouse events.
func handle_hover(pr_local: Vector2) -> void:
	var hit_section: JournalKnownSet = null
	var hit_index: int = -1
	# Gated exactly where _try_buy is gated, and for the same reason the sections
	# refuse to react to an unaffordable entry: during the FTUE the page is
	# READABLE before it is a shop, and a swatch that lifts under the pointer
	# promises a purchase the step has not unlocked yet.
	if TutorialGate.allows(TutorialGate.Action.SHOP) and content != null \
			and Rect2(Vector2.ZERO, page_right.size).has_point(pr_local):
		for section: JournalKnownSet in sections:
			if section == null:
				continue
			var idx: int = section.entry_at(
					pr_local - content.position - section.position)
			if idx >= 0:
				hit_section = section
				hit_index = idx
				break
	# Every section is told, not just the hit one: the pointer moving from one
	# section to another has to un-hover the entry it left.
	for section: JournalKnownSet in sections:
		if section != null:
			section.set_hovered(hit_index if section == hit_section else -1)
	_update_tooltip(hit_section, hit_index)


func _clear_hover() -> void:
	_update_tooltip(null, -1)
	for section: JournalKnownSet in sections:
		if section != null:
			section.set_hovered(-1)


## The click path from PageRight-local space down. Public so tests can drive
## it without synthesizing mouse events through the whole viewport stack.
func handle_click(pr_local: Vector2) -> bool:
	if content == null:
		return false
	if not Rect2(Vector2.ZERO, page_right.size).has_point(pr_local):
		return false
	for section: JournalKnownSet in sections:
		if section == null:
			continue
		var local: Vector2 = pr_local - content.position - section.position
		var idx: int = section.entry_at(local)
		if idx >= 0:
			return _try_buy(section, idx)
	return false


# --- the mouse-verb tag ------------------------------------------------------

## Whether a LEFT CLICK would do anything here: the entry is locked and
## affordable right now. Drives the click glyph alone — an owned entry has
## nothing to buy, and an unaffordable one is the case the whole hover path
## already declines to react to; a buy glyph over it would be the same false
## promise in pictures.
func _is_for_sale(section: JournalKnownSet, index: int) -> bool:
	return _is_locked(section, index) and _can_afford(section, index)


## Whether this entry is still to be bought. False with no economy in the tree,
## which is what makes a preview or a layout test render everything owned.
func _is_locked(section: JournalKnownSet, index: int) -> bool:
	if section == null or index < 0 or _unlocks_node() == null:
		return false
	var id: StringName = section.entry_id_at(index)
	if id == &"":
		return false
	return not bool(_unlocks.call(&"is_unlocked", id))


func _can_afford(section: JournalKnownSet, index: int) -> bool:
	if section == null or index < 0 or _unlocks_node() == null:
		return false
	var id: StringName = section.entry_id_at(index)
	return id != &"" and bool(_unlocks.call(&"can_afford_unlock", id))


## Whether the tag has anything at all to say: any entry that IS a shop entry.
## Broader than `_is_for_sale` because the right-click/info half of the tag is
## about the thing, not about the transaction — an owned frailejon is still
## something to read about, and a fence you cannot afford yet is the entry a
## player is most likely to want to read about.
func _has_verbs(section: JournalKnownSet, index: int) -> bool:
	return section != null and index >= 0 and section.entry_id_at(index) != &""


func _update_tooltip(section: JournalKnownSet, index: int) -> void:
	if not _has_verbs(section, index):
		if _tooltip != null and is_instance_valid(_tooltip):
			_tooltip.hide_tip()
		return
	var tip := _tooltip_node()
	if tip == null:
		return
	var parent := tip.get_parent() as Control
	# Section-local -> the glyph's parent, through the page. The SAME chain
	# handle_hover walks, run backwards: whatever the warp does to the page, the
	# glyph lands on the entry the arithmetic picked, not on the one next door.
	var offset: Vector2 = content.position + section.position
	var ink := section.entry_ink_rect(index)
	var to_local := parent.get_global_transform().affine_inverse() \
			* page_right.get_global_transform()
	var art := Rect2(to_local * (ink.position + offset),
			to_local.basis_xform(ink.size))
	# The ink COLOUR comes from the section too, so the glyphs and the page's own
	# lettering are the same palette entry by construction rather than by two edits.
	# So does the PRICE — the section is where the shop state was last written, and
	# reading it back is what keeps the number on screen equal to the number
	# try_unlock will charge.
	var locked: bool = _is_locked(section, index)
	tip.show_for(art, _tag_bounds(section, parent, to_local, offset),
			section.text_color, _is_for_sale(section, index),
			section.cost_of(index) if locked else 0,
			_can_afford(section, index))


# Where the tag is allowed to go: the book, with its TOP raised to the section's
# own swatch row.
#
# The row is what stops the glyphs landing on the heading's rule. A swatch sits a
# few texels down inside its cell, so a tag hung above the ART alone clears the
# art and lands squarely on the rule above it, in the same brown — measured, on
# the fence. Clamped to the cell top instead, it comes to rest on the upper part
# of the picture, which is where a cursor belongs anyway.
func _tag_bounds(section: JournalKnownSet, parent: Control, to_local: Transform2D,
		offset: Vector2) -> Rect2:
	var top: float = (to_local * (Vector2(0.0, section.header_row_px()) + offset)).y
	return Rect2(Vector2(0.0, top), Vector2(parent.size.x, parent.size.y - top))


# Parented to BookHit's PARENT (BookArt) rather than to BookHit, and that is a
# draw-order decision: BookHit comes BEFORE Pages in field_journal.tscn, so
# anything under it is painted UNDER the paper. Appended to BookArt it is the
# last child, and therefore on top of the book.
func _tooltip_node() -> JournalTooltip:
	if _tooltip != null and is_instance_valid(_tooltip):
		return _tooltip
	var host := get_parent() as Control
	if host == null:
		return null
	_tooltip = JournalTooltip.new()
	host.add_child(_tooltip)
	return _tooltip


func _try_buy(section: JournalKnownSet, index: int) -> bool:
	# Gated at the BUY, not at the click: the shop page is readable from the
	# moment the journal opens (that is the step before this one), it just
	# doesn't sell anything yet.
	if not TutorialGate.allows(TutorialGate.Action.SHOP):
		return false
	var id: StringName = section.entry_id_at(index)
	if id == &"" or _unlocks_node() == null:
		return false
	if bool(_unlocks.call(&"is_unlocked", id)):
		return false
	# Asked BEFORE the attempt, because try_unlock reports the same false for
	# "too poor" and "nothing happened" and only the first deserves a recoil.
	if not bool(_unlocks.call(&"can_afford_unlock", id)):
		# Two halves of one refusal: the swatch recoils where it sits, the price
		# reddens where IT sits — which is in the tag, not the page, since the
		# price moved there to travel with the click glyph.
		section.flash_denied(index)
		if _tooltip != null and is_instance_valid(_tooltip):
			_tooltip.flash_denied()
		return false
	var bought: bool = bool(_unlocks.call(&"try_unlock", id))
	# Bought or refused, the presentation may need updating (try_unlock's spend
	# also fires resource_changed, but a refusal does not).
	_refresh_states()
	# The pointer has not moved, so nothing else will re-ask: an entry just bought
	# is no longer for sale, and a purchase that leaves "buy" floating over it
	# reads as the click not having landed.
	_update_tooltip(section, index)
	return bought


func _on_resource_changed(id: StringName, _value: float, _delta: float) -> void:
	if id == TOKENS:
		_refresh_states()


## Repaints every section's lock/cost presentation from UnlockState + the
## ledger. With no UnlockState in the scene this is a no-op and the sections
## keep their default (everything owned) look.
func _refresh_states() -> void:
	if _unlocks_node() == null:
		return
	# Per ENTRY, not per page: prices differ by type (ladder 10, bridge 20,
	# fence 30), so both the printed number and the affordable/faded state have
	# to be asked about that entry's own type.
	for section: JournalKnownSet in sections:
		if section == null:
			continue
		for id_str: String in section.entry_ids:
			var id := StringName(id_str)
			var locked: bool = not bool(_unlocks.call(&"is_unlocked", id))
			var cost: int = int(_unlocks.call(&"unlock_cost_for", id))
			var affordable: bool = bool(_unlocks.call(&"can_afford_unlock", id))
			section.set_entry_state(id, locked, cost, affordable)


func _unlocks_node() -> Node:
	if _unlocks == null or not is_instance_valid(_unlocks):
		_unlocks = get_tree().get_first_node_in_group(UNLOCKS_GROUP)
		if _unlocks != null and _unlocks.has_signal(&"unlock_changed") \
				and not _unlocks.is_connected(&"unlock_changed", _on_unlock_changed):
			_unlocks.connect(&"unlock_changed", _on_unlock_changed)
	return _unlocks


func _on_unlock_changed(_type: StringName) -> void:
	_refresh_states()
