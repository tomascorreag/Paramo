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
	if content != null and Rect2(Vector2.ZERO, page_right.size).has_point(pr_local):
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


func _clear_hover() -> void:
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


func _try_buy(section: JournalKnownSet, index: int) -> bool:
	var id: StringName = section.entry_id_at(index)
	if id == &"" or _unlocks_node() == null:
		return false
	if bool(_unlocks.call(&"is_unlocked", id)):
		return false
	# Asked BEFORE the attempt, because try_unlock reports the same false for
	# "too poor" and "nothing happened" and only the first deserves a recoil.
	if not bool(_unlocks.call(&"can_afford_unlock")):
		section.flash_denied(index)
		return false
	var bought: bool = bool(_unlocks.call(&"try_unlock", id))
	# Bought or refused, the presentation may need updating (try_unlock's spend
	# also fires resource_changed, but a refusal does not).
	_refresh_states()
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
	var cost: int = int(_unlocks.get(&"unlock_cost"))
	var affordable: bool = bool(_unlocks.call(&"can_afford_unlock"))
	for section: JournalKnownSet in sections:
		if section == null:
			continue
		for id_str: String in section.entry_ids:
			var id := StringName(id_str)
			var locked: bool = not bool(_unlocks.call(&"is_unlocked", id))
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
