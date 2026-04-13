class_name TileInteractionController
extends Node

## Handles right-click tile interactions via a radial icon menu.

@export var pathfinder: Pathfinder
@export var player: Player
@export var world: Node2D

var _planted: Dictionary = {}  # Vector2i -> Node2D
var _pending_cell: Vector2i
var _menu: Control  # RadialMenu instance
var _menu_layer: CanvasLayer
var _radial_menu_script: GDScript

var _ux_overlay: Node2D  # UXOverlay
var _frailejon_scene: PackedScene
var _icons_texture: Texture2D
var _plants_texture: Texture2D


func _ready() -> void:
	if pathfinder == null:
		pathfinder = get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	if player == null:
		player = get_tree().get_first_node_in_group(&"player") as Player

	_ux_overlay = get_tree().get_first_node_in_group(UXOverlay.GROUP_NAME)
	_radial_menu_script = load("res://scripts/ui/radial_menu.gd")
	_frailejon_scene = load("res://scenes/tools/frailejon.tscn")
	_icons_texture = load("res://assets/sprites/UX/icons.png")
	_plants_texture = load("res://assets/sprites/objects/ISO_Plants.png")

	_menu_layer = CanvasLayer.new()
	_menu_layer.layer = 101  # above PostProcessLayer (100)
	add_child(_menu_layer)


func _unhandled_input(event: InputEvent) -> void:
	if pathfinder == null or player == null:
		return
	if not (event is InputEventMouseButton):
		return

	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_RIGHT or not mb.pressed:
		return

	var global_pos := _event_global_position(mb)
	var cell := pathfinder.resolve_click(global_pos)

	if cell == Pathfinder.NO_CELL:
		return
	if not pathfinder.is_walkable(cell):
		return
	if _planted.has(cell):
		return

	# Adjacent check: Chebyshev distance == 1 (includes diagonals)
	var diff := cell - player.current_cell
	if maxi(abs(diff.x), abs(diff.y)) != 1:
		return

	_pending_cell = cell
	var world_pos := pathfinder.cell_to_world(cell)
	var alt := pathfinder.altitude_center(cell)
	var tile_world := world_pos + Vector2(0.0, -alt * Pathfinder.HALF_STEP_PX)
	var tile_screen := get_viewport().get_canvas_transform() * tile_world
	_show_action_menu(tile_screen)
	get_viewport().set_input_as_handled()


func _show_action_menu(screen_pos: Vector2) -> void:
	_close_menu()

	var items: Array[Dictionary] = [
		{
			"id": "plant",
			"icon": _icons_texture,
			"region": Rect2(0, 0, 16, 16),
			"submenu": [
				{
					"id": "frailejon",
					"icon": _plants_texture,
					"region": Rect2(96, 0, 32, 32),
				},
			],
		},
	]

	_menu = _radial_menu_script.new()
	_menu.center_icon_texture = _icons_texture
	_menu.center_icon_region = Rect2(16, 0, 16, 16)
	_menu_layer.add_child(_menu)
	_menu.item_selected.connect(_on_item_selected)
	_menu.closed.connect(_on_menu_closed)
	_menu.open(screen_pos, items)
	if _ux_overlay:
		_ux_overlay.suspended = true


func _close_menu() -> void:
	if _menu and is_instance_valid(_menu):
		_menu.item_selected.disconnect(_on_item_selected)
		_menu.closed.disconnect(_on_menu_closed)
		_menu.queue_free()
		_menu = null
		if _ux_overlay:
			_ux_overlay.suspended = false


func _on_item_selected(id: String) -> void:
	match id:
		"frailejon":
			_plant_frailejon(_pending_cell)


func _on_menu_closed() -> void:
	_menu = null
	if _ux_overlay:
		_ux_overlay.suspended = false


func _plant_frailejon(cell: Vector2i) -> void:
	var frailejon: Node2D = _frailejon_scene.instantiate()
	frailejon.cell = cell

	var base := pathfinder.cell_to_world(cell)
	var alt := pathfinder.altitude_center(cell)
	world.add_child(frailejon)
	frailejon.global_position = base + Vector2(0.0, -alt * Pathfinder.HALF_STEP_PX)
	_planted[cell] = frailejon


func _event_global_position(mb: InputEventMouseButton) -> Vector2:
	var viewport := get_viewport()
	var canvas_xform := viewport.get_canvas_transform()
	return canvas_xform.affine_inverse() * mb.position
