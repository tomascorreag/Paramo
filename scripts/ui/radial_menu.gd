class_name RadialMenu
extends Control

## Animated radial icon wheel. Call open() with a screen position and an array
## of item dicts. Each dict: { "id": String, "icon": Texture2D,
## "submenu": Array[Dictionary] (optional) }.
##
## Set center_icon_texture before calling open() to display a hub icon at the
## center of every wheel level. The texture carries its own region
## (AtlasTexture / AnimatedTexture).

signal item_selected(id: String)
signal closed

const OPEN_DURATION: float = 0.18
const OPEN_STAGGER: float = 0.03
const CLOSE_DURATION: float = 0.10
const MIN_RADIUS: float = 12.0
const PARENT_DIM_ALPHA: float = 0.35
const OVERLAY_COLOR: Color = Color(0.0, 0.0, 0.0, 0.25)

var _item_script: GDScript = preload("res://scripts/ui/radial_menu_item.gd")

## Set before calling open() to show a center hub icon.
var center_icon_texture: Texture2D

var _center: Vector2
var _items: Array[Control] = []
var _center_icon: TextureRect
var _overlay: ColorRect
var _is_closing: bool = false
var _open_tween: Tween

# Stack of previous levels for back-navigation.
# Each entry: { "items": Array[Control], "center_icon": TextureRect, "center": Vector2 }
var _level_stack: Array[Dictionary] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_overlay = ColorRect.new()
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.color = Color(OVERLAY_COLOR, 0.0)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_overlay)


func open(center: Vector2, items_data: Array[Dictionary], start_angle: float = -PI / 2.0) -> void:
	_center = center
	_clear_active_items()
	_is_closing = false

	if _open_tween and _open_tween.is_valid():
		_open_tween.kill()

	var radius := MIN_RADIUS

	var count := items_data.size()
	_open_tween = create_tween().set_parallel(true)

	# Fade in overlay (only on first open, not on submenu re-opens).
	if _overlay.color.a < OVERLAY_COLOR.a:
		_open_tween.tween_property(_overlay, "color:a", OVERLAY_COLOR.a, OPEN_DURATION)

	_spawn_center_icon(center)

	for i in count:
		var item: Control = _item_script.new()
		item.setup(items_data[i])
		add_child(item)
		_items.append(item)
		item.clicked.connect(_on_item_clicked.bind(item))

		var angle: float
		if count == 1:
			angle = start_angle
		else:
			angle = TAU * i / count + start_angle
		var final_pos := _center + Vector2(cos(angle), sin(angle)) * radius - item.size / 2.0

		item.position = _center - item.size / 2.0
		item.scale = Vector2.ZERO
		item.modulate.a = 0.0

		var delay := i * OPEN_STAGGER
		_open_tween.tween_property(item, "position", final_pos, OPEN_DURATION) \
			.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK).set_delay(delay)
		_open_tween.tween_property(item, "scale", Vector2.ONE, OPEN_DURATION) \
			.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK).set_delay(delay)
		_open_tween.tween_property(item, "modulate:a", 1.0, OPEN_DURATION * 0.6) \
			.set_delay(delay)


func close() -> void:
	if _is_closing:
		return
	_is_closing = true

	if _open_tween and _open_tween.is_valid():
		_open_tween.kill()

	var tween := create_tween().set_parallel(true)

	# Gather all visuals from every level.
	var all_visuals: Array[Control] = []
	all_visuals.append_array(_items)
	if _center_icon:
		all_visuals.append(_center_icon)
	for level in _level_stack:
		var level_items: Array = level["items"]
		for item in level_items:
			all_visuals.append(item)
		var level_ci: TextureRect = level.get("center_icon")
		if level_ci:
			all_visuals.append(level_ci)

	for i in all_visuals.size():
		var node := all_visuals[i]
		var delay := i * 0.015
		tween.tween_property(node, "modulate:a", 0.0, CLOSE_DURATION * 0.7).set_delay(delay)
		tween.tween_property(node, "scale", Vector2.ZERO, CLOSE_DURATION) \
			.set_ease(Tween.EASE_IN).set_delay(delay)

	tween.tween_property(_overlay, "color:a", 0.0, CLOSE_DURATION)
	tween.chain().tween_callback(_on_close_finished)


func _go_back() -> void:
	if _level_stack.is_empty():
		close()
		return

	if _open_tween and _open_tween.is_valid():
		_open_tween.kill()

	# Fade out current items.
	var fade_tween := create_tween().set_parallel(true)
	for item in _items:
		fade_tween.tween_property(item, "modulate:a", 0.0, 0.08)
		fade_tween.tween_property(item, "scale", Vector2(0.5, 0.5), 0.08)
	if _center_icon:
		fade_tween.tween_property(_center_icon, "modulate:a", 0.0, 0.08)
		fade_tween.tween_property(_center_icon, "scale", Vector2(0.5, 0.5), 0.08)

	fade_tween.chain().tween_callback(func() -> void:
		# Remove current items.
		for item in _items:
			item.queue_free()
		_items.clear()
		if _center_icon:
			_center_icon.queue_free()
			_center_icon = null

		# Restore previous level from stack.
		var level: Dictionary = _level_stack.pop_back()
		_items.assign(level["items"])
		_center_icon = level.get("center_icon")
		_center = level["center"]

		# Re-enable and fade parent items back in.
		var restore_tween := create_tween().set_parallel(true)
		for item in _items:
			item.mouse_filter = Control.MOUSE_FILTER_STOP
			restore_tween.tween_property(item, "modulate:a", 1.0, 0.12)
		if _center_icon:
			restore_tween.tween_property(_center_icon, "modulate:a", 1.0, 0.12)
	)


func _on_close_finished() -> void:
	closed.emit()
	queue_free()


func _on_item_clicked(item: Control) -> void:
	var data: Dictionary = item.item_data
	if data.has("submenu") and not data["submenu"].is_empty():
		_open_submenu(item.position + item.size / 2.0, data["submenu"])
	else:
		item_selected.emit(data["id"])
		close()


func _open_submenu(sub_center: Vector2, submenu_data: Array) -> void:
	if _open_tween and _open_tween.is_valid():
		_open_tween.kill()

	# Push current level onto the stack.
	_level_stack.append({
		"items": _items.duplicate(),
		"center_icon": _center_icon,
		"center": _center,
	})

	# Dim current items and disable their input.
	var tween := create_tween().set_parallel(true)
	for item in _items:
		item.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tween.tween_property(item, "modulate:a", PARENT_DIM_ALPHA, 0.12)
	if _center_icon:
		tween.tween_property(_center_icon, "modulate:a", PARENT_DIM_ALPHA, 0.12)

	# Outward direction from parent center to the clicked item — submenu fans out from here.
	var outward_angle := (sub_center - _center).angle() if sub_center != _center else -PI / 2.0

	# Clear references (they're now owned by the stack) and open submenu.
	tween.chain().tween_callback(func() -> void:
		_items.clear()
		_center_icon = null

		var typed: Array[Dictionary] = []
		for d in submenu_data:
			typed.append(d)
		open(sub_center, typed, outward_angle)
	)


func _spawn_center_icon(center: Vector2) -> void:
	if center_icon_texture == null:
		return

	var icon_size := center_icon_texture.get_size()

	_center_icon = TextureRect.new()
	_center_icon.texture = center_icon_texture
	_center_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_center_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_center_icon.position = center - icon_size / 2.0
	_center_icon.pivot_offset = icon_size / 2.0
	_center_icon.scale = Vector2.ZERO
	_center_icon.modulate.a = 0.0
	add_child(_center_icon)

	if _open_tween:
		_open_tween.tween_property(_center_icon, "scale", Vector2.ONE, OPEN_DURATION) \
			.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
		_open_tween.tween_property(_center_icon, "modulate:a", 1.0, OPEN_DURATION * 0.6)


func _clear_active_items() -> void:
	for item in _items:
		item.queue_free()
	_items.clear()
	if _center_icon:
		_center_icon.queue_free()
		_center_icon = null


func _gui_input(event: InputEvent) -> void:
	if _is_closing:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			if not _level_stack.is_empty():
				_go_back()
			else:
				close()
			accept_event()
