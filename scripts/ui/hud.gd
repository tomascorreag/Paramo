class_name HUD
extends CanvasLayer

## In-game HUD scaffolding. Top-right minimap placeholder + bottom-left
## equipped-item slot. Clicking the slot fans out a 2-column item picker
## from the corner. Not wired to gameplay — selecting an item updates the
## slot icon and emits `item_equipped`; downstream systems will hook in
## later via that signal and `set_items`.
##
## Frames use a hand-built 3x3 ImageTexture applied as a StyleBoxTexture
## with `texture_margin = 1`. Source layout (T=transparent corner,
## B=border, F=fill) gives a 1-texel chamfer that snaps to the viewport
## texel grid — no anti-aliasing, no curve math, no sub-pixel smear.
##   T B T
##   B F B
##   T B T

signal item_equipped(id: StringName)

const _ITEM_CELL: int = 16
const _MENU_COLS: int = 2
const _SLOT_SIZE: int = 32
const _MENU_GAP_PX: int = 2

const _OPEN_DURATION: float = 0.20
const _OPEN_STAGGER: float = 0.030
const _CLOSE_DURATION: float = 0.10

## Modals the corner buttons drive, wired by NodePath on the HUD instance in
## gameplay_base.tscn (../PauseMenu, ../FieldJournal). Direct typed refs — no group
## traversal or stringly-typed dispatch. Null-guarded so a standalone hud.tscn
## (no siblings) doesn't crash.
@export var pause_menu: PauseMenu
@export var field_journal: FieldJournal

@onready var _slot: Button = %EquippedSlot
@onready var _slot_icon: TextureRect = %EquippedIcon
@onready var _menu_root: Control = %ItemMenu
@onready var _pause_button: Button = %PauseButton
@onready var _journal_button: Button = %JournalButton
var _pause_bars: Array[NinePatchRect] = []

var _items: Array[Dictionary] = []
var _item_buttons: Array[Button] = []
var _equipped_id: StringName = &""
var _menu_open: bool = false
var _tween: Tween


func _ready() -> void:
	# TitleIntro finds and hides the HUD via this group for the duration of the
	# opening cinematic (see title_intro.gd _gate_gameplay_ux), so it isn't
	# visible over the pre-title lake shot.
	add_to_group(&"hud")
	_setup_pause_button()
	_setup_journal_button()
	_items = _placeholder_items()
	_slot.pressed.connect(_on_slot_pressed)
	_build_menu()
	_menu_root.visible = false
	_menu_root.modulate.a = 0.0
	if not _items.is_empty():
		set_equipped(_items[0]["id"])


## Replace the placeholder roster. Each entry must contain `id: StringName`
## and `icon: Texture2D`. Safe to call at any time; rebuilds the picker.
func set_items(items: Array[Dictionary]) -> void:
	_items = items
	for b in _item_buttons:
		b.queue_free()
	_item_buttons.clear()
	_build_menu()
	if _menu_open:
		_close_menu()
	if not _items.is_empty():
		set_equipped(_items[0]["id"])


func set_equipped(id: StringName) -> void:
	for it in _items:
		if it["id"] == id:
			_equipped_id = id
			_slot_icon.texture = it["icon"]
			_punch_icon()
			_refresh_equipped_highlight()
			item_equipped.emit(id)
			return


func _setup_pause_button() -> void:
	# Frameless: two solid-sprite bars form the pause glyph directly on the button.
	var empty := StyleBoxEmpty.new()
	for state: StringName in [&"normal", &"hover", &"pressed", &"focus"]:
		_pause_button.add_theme_stylebox_override(state, empty)
	_pause_bars.clear()
	for x: int in [3, 9]:
		var bar := PixelUI.make_solid_ninepatch(Palette.TEXT)
		bar.position = Vector2(x, 3)
		bar.size = Vector2(4, 10)
		_pause_button.add_child(bar)
		_pause_bars.append(bar)
	_pause_button.mouse_entered.connect(_tint_pause_bars.bind(Palette.ACCENT))
	_pause_button.mouse_exited.connect(_tint_pause_bars.bind(Palette.TEXT))
	_pause_button.pressed.connect(func() -> void:
		if pause_menu != null:
			pause_menu.toggle()
	)


func _tint_pause_bars(c: Color) -> void:
	for bar in _pause_bars:
		bar.self_modulate = c


func _setup_journal_button() -> void:
	# Frameless, mirroring the pause button; the journal glyph is the icon sprite
	# (pause uses two drawn bars). Opens the FieldJournal (bottom-right, left of pause).
	var empty := StyleBoxEmpty.new()
	for state: StringName in [&"normal", &"hover", &"pressed", &"focus"]:
		_journal_button.add_theme_stylebox_override(state, empty)
	var icon := PixelUI.make_icon_fill(preload("res://assets/sprites/UX/icons/journal.tres"))
	icon.self_modulate = Palette.TEXT
	_journal_button.add_child(icon)
	_journal_button.mouse_entered.connect(func() -> void: icon.self_modulate = Palette.ACCENT)
	_journal_button.mouse_exited.connect(func() -> void: icon.self_modulate = Palette.TEXT)
	_journal_button.pressed.connect(func() -> void:
		if field_journal != null:
			field_journal.toggle()
	)


func _on_slot_pressed() -> void:
	if _menu_open:
		_close_menu()
	else:
		_open_menu()


func _open_menu() -> void:
	_menu_open = true
	_menu_root.visible = true
	_refresh_equipped_highlight()

	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = create_tween().set_parallel(true)
	_tween.tween_property(_menu_root, "modulate:a", 1.0, _OPEN_DURATION * 0.5)

	# Items burst outward from the slot's center to their grid rest positions.
	var slot_center_in_menu: Vector2 = (
		_slot.global_position + _slot.size / 2.0 - _menu_root.global_position
	)
	for i in _item_buttons.size():
		var btn := _item_buttons[i]
		var rest: Vector2 = btn.get_meta(&"rest_pos")
		btn.position = slot_center_in_menu - btn.size / 2.0
		btn.modulate.a = 0.0
		btn.scale = Vector2(0.6, 0.6)
		var delay := i * _OPEN_STAGGER
		_tween.tween_property(btn, "position", rest, _OPEN_DURATION) \
			.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK).set_delay(delay)
		_tween.tween_property(btn, "scale", Vector2.ONE, _OPEN_DURATION) \
			.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK).set_delay(delay)
		_tween.tween_property(btn, "modulate:a", 1.0, _OPEN_DURATION * 0.6) \
			.set_delay(delay)


func _close_menu() -> void:
	if not _menu_open:
		return
	_menu_open = false
	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = create_tween().set_parallel(true)
	_tween.tween_property(_menu_root, "modulate:a", 0.0, _CLOSE_DURATION)
	for btn in _item_buttons:
		_tween.tween_property(btn, "scale", Vector2(0.85, 0.85), _CLOSE_DURATION) \
			.set_ease(Tween.EASE_IN)
	_tween.chain().tween_callback(func() -> void:
		_menu_root.visible = false
	)


func _build_menu() -> void:
	if _items.is_empty():
		return
	var rows: int = ceili(_items.size() / float(_MENU_COLS))
	var menu_w: int = _MENU_COLS * _ITEM_CELL
	var menu_h: int = rows * _ITEM_CELL
	_menu_root.size = Vector2(menu_w, menu_h)
	# Anchor menu just above the slot, left edges aligned.
	_menu_root.position = _slot.position + Vector2(0, -menu_h - _MENU_GAP_PX)

	for i in _items.size():
		var col: int = i % _MENU_COLS
		var row: int = i / _MENU_COLS
		var btn := _make_item_button(_items[i])
		_menu_root.add_child(btn)
		var pos := Vector2(col * _ITEM_CELL, row * _ITEM_CELL)
		btn.position = pos
		btn.set_meta(&"rest_pos", pos)
		_item_buttons.append(btn)


func _make_item_button(item: Dictionary) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(_ITEM_CELL, _ITEM_CELL)
	b.size = Vector2(_ITEM_CELL, _ITEM_CELL)
	b.focus_mode = Control.FOCUS_NONE
	b.pivot_offset = Vector2(_ITEM_CELL, _ITEM_CELL) / 2.0
	# Fills come from the global Button theme; a frame overlay draws the outline
	# and is retinted per equipped state (_refresh_equipped_highlight).
	var frame := PixelUI.make_frame_ninepatch(Palette.BORDER)
	frame.name = "Frame"
	b.add_child(frame)

	var icon := PixelUI.make_icon_fill(item["icon"])
	b.add_child(icon)

	b.pressed.connect(func() -> void:
		set_equipped(item["id"])
		_close_menu()
	)
	return b


func _refresh_equipped_highlight() -> void:
	for i in _item_buttons.size():
		var equipped: bool = _items[i]["id"] == _equipped_id
		var frame := _item_buttons[i].get_node_or_null(^"Frame")
		if frame != null:
			frame.self_modulate = Palette.ACCENT if equipped else Palette.BORDER


func _punch_icon() -> void:
	if _slot_icon == null:
		return
	_slot_icon.pivot_offset = _slot_icon.size / 2.0
	_slot_icon.scale = Vector2(1.18, 1.18)
	var t := create_tween()
	t.tween_property(_slot_icon, "scale", Vector2.ONE, 0.18) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)


func _input(event: InputEvent) -> void:
	if not _menu_open:
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed:
		return
	var pos := mb.position
	var slot_rect := Rect2(_slot.global_position, _slot.size)
	var menu_rect := Rect2(_menu_root.global_position, _menu_root.size)
	if slot_rect.has_point(pos) or menu_rect.has_point(pos):
		return
	_close_menu()
	get_viewport().set_input_as_handled()


func _placeholder_items() -> Array[Dictionary]:
	return [
		{ "id": &"frailejon", "icon": preload("res://assets/sprites/UX/icons/frailejon.tres") },
		{ "id": &"trowel", "icon": preload("res://assets/sprites/UX/icons/trowel.tres") },
		{ "id": &"pickaxe", "icon": preload("res://assets/sprites/UX/icons/pickaxe.tres") },
		{ "id": &"ladder", "icon": preload("res://assets/sprites/UX/icons/ladder.tres") },
		{ "id": &"bridge", "icon": preload("res://assets/sprites/UX/icons/bridge.tres") },
		{ "id": &"inspect", "icon": preload("res://assets/sprites/UX/icons/inspect.tres") },
	]
