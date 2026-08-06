class_name RadialMenuItem
extends Control

signal clicked

const HOVER_SCALE: float = 1.12
const NORMAL_SCALE: float = 1.0
const MAX_FOLLOW_PX: float = 2.0
const FOLLOW_SPEED: float = 12.0
const SCALE_TWEEN_DURATION: float = 0.12

## Icon opacity when the action can't currently be paid for. Applied via
## self_modulate.a rather than a Color literal so no new RGB is authored — the
## palette rule stays satisfied without going through Palette at all.
const DISABLED_ALPHA: float = 0.4

var item_data: Dictionary

## False when the action is offered but unaffordable: drawn dimmed, and it
## swallows clicks instead of emitting `clicked`.
var enabled: bool = true

var _hovered: bool = false
var _icon: TextureRect
var _scale_tween: Tween


func setup(data: Dictionary) -> void:
	item_data = data
	enabled = data.get("enabled", true)

	var tex: Texture2D = data["icon"]
	_icon = PixelUI.make_icon_sized(tex)
	add_child(_icon)

	var icon_size := tex.get_size()
	custom_minimum_size = icon_size
	size = icon_size
	pivot_offset = icon_size / 2.0
	# STOP even when disabled: the item must absorb the click. MOUSE_FILTER_IGNORE
	# would let it fall through to the scrim behind, closing the whole menu — which
	# reads as a broken button rather than as an unaffordable one.
	mouse_filter = Control.MOUSE_FILTER_STOP

	if not enabled:
		_icon.self_modulate.a = DISABLED_ALPHA
		return

	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)


func _on_mouse_entered() -> void:
	_hovered = true
	_tween_scale(HOVER_SCALE)


func _on_mouse_exited() -> void:
	_hovered = false
	_tween_scale(NORMAL_SCALE)


func _tween_scale(target: float) -> void:
	if _scale_tween and _scale_tween.is_valid():
		_scale_tween.kill()
	_scale_tween = create_tween()
	_scale_tween.tween_property(self, "scale", Vector2(target, target), SCALE_TWEEN_DURATION) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)


func _process(delta: float) -> void:
	if _icon == null:
		return
	if _hovered:
		var mouse_offset := get_local_mouse_position() - size / 2.0
		var target := mouse_offset.limit_length(MAX_FOLLOW_PX)
		_icon.position = _icon.position.lerp(target, FOLLOW_SPEED * delta)
	else:
		_icon.position = _icon.position.lerp(Vector2.ZERO, FOLLOW_SPEED * delta)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			# Disabled items still consume the event (see mouse_filter in setup),
			# they just don't act on it.
			if enabled:
				clicked.emit()
			accept_event()
