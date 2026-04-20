class_name TileInteractionController
extends Node

## Handles right-click tile interactions via a radial icon menu.

const GROUP_NAME: StringName = &"tile_interaction_controller"

@export var pathfinder: Pathfinder
@export var player: Player
@export var world: Node2D
@export var traversal_placement_controller: TraversalPlacementController

var _planted: Dictionary = {}  # Vector2i -> Node2D
var _pending_cell: Vector2i
var _menu: Control  # RadialMenu instance
var _menu_layer: CanvasLayer
var _radial_menu_script: GDScript

var _ux_overlay: Node2D  # UXOverlay
var _frailejon_scene: PackedScene
var _icons_texture: Texture2D
var _plants_texture: Texture2D


func _enter_tree() -> void:
	add_to_group(GROUP_NAME)


func _ready() -> void:
	if pathfinder == null:
		pathfinder = get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	if player == null:
		player = get_tree().get_first_node_in_group(&"player") as Player

	_ux_overlay = get_tree().get_first_node_in_group(UXOverlay.GROUP_NAME)
	if traversal_placement_controller == null:
		traversal_placement_controller = get_tree().get_first_node_in_group(
			TraversalPlacementController.GROUP_NAME
		) as TraversalPlacementController
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
	if traversal_placement_controller and traversal_placement_controller.is_placing():
		return
	if not (event is InputEventMouseButton):
		return

	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_RIGHT or not mb.pressed:
		return

	var global_pos := _event_global_position(mb)
	var cell := pathfinder.resolve_click(global_pos)

	if not is_interactable(cell):
		return

	# Skip the menu entirely when there are no valid actions for this cell
	# (e.g. clicking a bridge the player is standing on — remove_bridge is
	# suppressed and nothing else applies).
	var items: Array[Dictionary] = _build_menu_items(cell)
	if items.is_empty():
		return

	_pending_cell = cell
	var world_pos := pathfinder.cell_to_world(cell)
	var alt := pathfinder.altitude_center(cell)
	var tile_world := world_pos + Vector2(0.0, -alt * Pathfinder.HALF_STEP_PX)
	var tile_screen := get_viewport().get_canvas_transform() * tile_world
	_show_action_menu(tile_screen, items)
	get_viewport().set_input_as_handled()


## Read-only view of the cells currently occupied by planted objects (key set
## is what callers need; values are the Node2D instances). Used by other
## systems (e.g. bridge placement) to avoid building over plants.
func planted_cells() -> Dictionary:
	return _planted


## True iff `cell` is a right-clickable tile from the player's current position:
## resolved, walkable, and Chebyshev-adjacent to the player. Planted/bridge
## cells stay interactable — the menu offers removal instead of placement.
func is_interactable(cell: Vector2i) -> bool:
	if cell == Pathfinder.NO_CELL:
		return false
	if pathfinder == null or player == null:
		return false
	if not pathfinder.is_walkable(cell):
		return false
	var diff := cell - player.current_cell
	return maxi(abs(diff.x), abs(diff.y)) == 1


func _show_action_menu(screen_pos: Vector2, items: Array[Dictionary]) -> void:
	_close_menu()

	_menu = _radial_menu_script.new()
	_menu.center_icon_texture = _icons_texture
	_menu.center_icon_region = Rect2(0, 0, 16, 16)
	_menu_layer.add_child(_menu)
	_menu.item_selected.connect(_on_item_selected)
	_menu.closed.connect(_on_menu_closed)
	_menu.open(screen_pos, items)
	if _ux_overlay:
		_ux_overlay.lock_at(_pending_cell)


func _close_menu() -> void:
	if _menu and is_instance_valid(_menu):
		_menu.item_selected.disconnect(_on_item_selected)
		_menu.closed.disconnect(_on_menu_closed)
		_menu.queue_free()
		_menu = null
		if _ux_overlay:
			_ux_overlay.unlock()


func _on_item_selected(id: String) -> void:
	match id:
		"frailejon":
			_plant_frailejon(_pending_cell)
			# Per UX spec: square clears the moment the object is added,
			# not after the menu finishes its close animation.
			if _ux_overlay:
				_ux_overlay.unlock()
		"bridge":
			_begin_traversal(_pending_cell, &"bridge")
		"remove_frailejon":
			_remove_frailejon(_pending_cell)
			if _ux_overlay:
				_ux_overlay.unlock()
		"remove_bridge":
			_remove_bridge(_pending_cell)
			if _ux_overlay:
				_ux_overlay.unlock()


# Cell-state-aware menu: planted → trowel only; bridge cell → trash only;
# otherwise → the default plant+build submenus.
func _build_menu_items(cell: Vector2i) -> Array[Dictionary]:
	if _planted.has(cell):
		return [
			{
				"id": "remove_frailejon",
				"icon": _icons_texture,
				"region": Rect2(48, 32, 16, 16),
			},
		]

	if traversal_placement_controller:
		var t := traversal_placement_controller.find_traversal_at(cell)
		if t != null:
			# Suppress the option entirely when the player is anywhere on
			# this traversal — _remove_bridge would refuse the action, so
			# exposing it as a menu entry is just noise.
			if _is_player_on_traversal(t):
				return []
			return [
				{
					"id": "remove_bridge",
					"icon": _icons_texture,
					"region": Rect2(32, 32, 16, 16),
				},
			]

	return [
		{
			"id": "plant",
			"icon": _icons_texture,
			"region": Rect2(0, 32, 16, 16),
			"submenu": [
				{
					"id": "frailejon",
					"icon": _plants_texture,
					"region": Rect2(96, 0, 32, 32),
				},
			],
		},
		{
			"id": "build",
			"icon": _icons_texture,
			"region": Rect2(16, 32, 16, 16),
			"submenu": [
				{
					"id": "bridge",
					"icon": _icons_texture,
					"region": Rect2(16, 48, 16, 16),
				},
			],
		},
	]


func _begin_traversal(origin: Vector2i, kind: StringName) -> void:
	if traversal_placement_controller == null:
		push_warning("TileInteractionController: no TraversalPlacementController wired.")
		return
	traversal_placement_controller.begin(origin, kind)


func _on_menu_closed() -> void:
	_menu = null
	if _ux_overlay:
		_ux_overlay.unlock()


func _plant_frailejon(cell: Vector2i) -> void:
	var frailejon: Node2D = _frailejon_scene.instantiate()
	frailejon.cell = cell

	var base := pathfinder.cell_to_world(cell)
	var alt := pathfinder.altitude_center(cell)
	world.add_child(frailejon)
	frailejon.global_position = base + Vector2(0.0, -alt * Pathfinder.HALF_STEP_PX)
	_planted[cell] = frailejon
	if pathfinder and frailejon.pathfinding_penalty != 0.0:
		pathfinder.set_cell_penalty(cell, frailejon.pathfinding_penalty)


func _remove_frailejon(cell: Vector2i) -> void:
	var node: Node2D = _planted.get(cell)
	if node == null:
		return
	_planted.erase(cell)
	if pathfinder:
		pathfinder.clear_cell_penalty(cell)
	if is_instance_valid(node):
		node.queue_free()


func _remove_bridge(cell: Vector2i) -> void:
	if traversal_placement_controller == null:
		return
	var t: Traversal = traversal_placement_controller.find_traversal_at(cell)
	if t == null:
		return
	# Defense in depth — the menu should already hide this option when the
	# player is on the traversal (see _build_menu_items), but check again so
	# scripted callers or future input paths can't strand the player.
	if _is_player_on_traversal(t):
		push_warning("TileInteractionController: refusing to remove bridge — player stands on it.")
		return
	traversal_placement_controller.remove_traversal(t)


func _is_player_on_traversal(t: Traversal) -> bool:
	if player == null or t == null:
		return false
	for entry in t.painted_cells():
		if entry["cell"] == player.current_cell:
			return true
	return false


func _event_global_position(mb: InputEventMouseButton) -> Vector2:
	var viewport := get_viewport()
	var canvas_xform := viewport.get_canvas_transform()
	return canvas_xform.affine_inverse() * mb.position
