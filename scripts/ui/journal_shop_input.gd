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
	# Deferred: UnlockState joins its group in its own _ready, order unknown.
	_refresh_states.call_deferred()


func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	if page_right == null:
		return
	# BookHit-local -> canvas -> PageRight-local. Both live on the same
	# CanvasLayer, so the global transforms are directly comparable.
	var canvas_point: Vector2 = get_global_transform() * mb.position
	var pr_local: Vector2 = \
			page_right.get_global_transform().affine_inverse() * canvas_point
	if handle_click(pr_local):
		accept_event()


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
			return _try_buy(section.entry_id_at(idx))
	return false


func _try_buy(id: StringName) -> bool:
	if id == &"" or _unlocks_node() == null:
		return false
	if bool(_unlocks.call(&"is_unlocked", id)):
		return false
	var bought: bool = bool(_unlocks.call(&"try_unlock", id))
	# Bought or refused-broke, the presentation may need updating (try_unlock's
	# spend also fires resource_changed, but a refusal does not).
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
