class_name TileInteractionController
extends Node

## Handles right-click tile interactions via a radial icon menu driven by an
## ActionRegistry: every right-click builds an ActionContext, asks the
## registry which TileActions are available for that cell, groups them by
## `action.group` into submenus, and shows only the resulting entries.
## Empty availability -> no menu, UXOverlay flashes denied.

const GROUP_NAME: StringName = &"tile_interaction_controller"

# Prefix for submenu-group pseudo-ids. Keeps the group id namespace disjoint
# from TileAction.id so `_on_item_selected` can't mistake a stale submenu-
# parent click for a missing action (even if an action is ever registered
# with id == &"build").
const _GROUP_ID_PREFIX: String = "group:"

# Action scripts — preloaded so Godot's class_name global cache is populated
# before _ready(). Listing them explicitly here also makes the set of
# registered actions easy to audit in one place.
const _ACTION_INSPECT: GDScript = preload("res://scripts/systems/actions/action_inspect.gd")
const _ACTION_PLANT_FRAILEJON: GDScript = preload("res://scripts/systems/actions/action_plant_frailejon.gd")
const _ACTION_REMOVE_FRAILEJON: GDScript = preload("res://scripts/systems/actions/action_remove_frailejon.gd")
const _ACTION_BUILD_BRIDGE: GDScript = preload("res://scripts/systems/actions/action_build_bridge.gd")
const _ACTION_REMOVE_BRIDGE: GDScript = preload("res://scripts/systems/actions/action_remove_bridge.gd")
const _ACTION_BUILD_LADDER: GDScript = preload("res://scripts/systems/actions/action_build_ladder.gd")
const _ACTION_REMOVE_LADDER: GDScript = preload("res://scripts/systems/actions/action_remove_ladder.gd")

# Visuals for submenu group nodes — rendered as parent items on the wheel
# whose submenu children are the individual TileActions in that group.
const _GROUP_ICONS: Dictionary = {
	&"plant": preload("res://assets/sprites/UX/icons/group_plant.tres"),
	&"build": preload("res://assets/sprites/UX/icons/group_build.tres"),
}

const _CENTER_ICON: Texture2D = preload("res://assets/sprites/UX/icons/center.tres")


@export var pathfinder: Pathfinder
@export var player: Player
@export var world: Node2D
@export var traversal_placement_controller: TraversalPlacementController

var _planted: Dictionary = {}  # Vector2i -> Node2D
var _pending_cell: Vector2i
var _menu: Control  # RadialMenu instance
var _menu_layer: CanvasLayer
var _radial_menu_script: GDScript
var _registry: ActionRegistry

var _ux_overlay: Node2D  # UXOverlay
var _frailejon_scene: PackedScene

# --- Debug toast (used by ActionInspect) -----------------------------------
var _toast_layer: CanvasLayer
var _toast_label: Label
var _toast_tween: Tween


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

	_menu_layer = CanvasLayer.new()
	_menu_layer.layer = 101  # above PostProcessLayer (100)
	add_child(_menu_layer)

	_registry = ActionRegistry.new()
	_registry.register(_ACTION_INSPECT.new())
	_registry.register(_ACTION_PLANT_FRAILEJON.new())
	_registry.register(_ACTION_REMOVE_FRAILEJON.new())
	_registry.register(_ACTION_BUILD_BRIDGE.new())
	_registry.register(_ACTION_BUILD_LADDER.new())
	_registry.register(_ACTION_REMOVE_BRIDGE.new())
	_registry.register(_ACTION_REMOVE_LADDER.new())


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

	var ctx := _build_context(cell)
	var actions := _registry.available_for(ctx)
	if actions.is_empty():
		# Right-click landed on a reachable tile but nothing applies — signal
		# the no-op so the player doesn't wonder if the click registered.
		if _ux_overlay and _ux_overlay.has_method(&"flash_denied"):
			_ux_overlay.flash_denied(cell)
		get_viewport().set_input_as_handled()
		return

	var items := _assemble_menu_items(actions)

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
## cells stay interactable — the registry picks what (if anything) applies.
func is_interactable(cell: Vector2i) -> bool:
	if cell == Pathfinder.NO_CELL:
		return false
	if pathfinder == null or player == null:
		return false
	if not pathfinder.is_walkable(cell):
		return false
	var diff := cell - player.current_cell
	return maxi(abs(diff.x), abs(diff.y)) == 1


# ---------------------------------------------------------------------------
# Registry-driven menu assembly
# ---------------------------------------------------------------------------

func _build_context(cell: Vector2i) -> ActionContext:
	var ctx := ActionContext.new()
	ctx.cell = cell
	ctx.tile = pathfinder.get_tile(cell)
	ctx.player_cell = player.current_cell
	ctx.tile_interaction = self
	ctx.traversal = traversal_placement_controller
	ctx.pathfinder = pathfinder
	return ctx


# Partitions actions into top-level entries (group == &"") and submenu-wrapped
# groups (group != &""). Group order follows registration order; within a
# group, actions also keep registration order.
func _assemble_menu_items(actions: Array[TileAction]) -> Array[Dictionary]:
	var top: Array[Dictionary] = []
	var groups: Dictionary = {}            # StringName -> Array[Dictionary]
	var group_order: Array[StringName] = []
	for a in actions:
		var entry := {
			"id": String(a.id),
			"icon": a.icon,
		}
		if a.group == &"":
			top.append(entry)
		else:
			if not groups.has(a.group):
				groups[a.group] = []
				group_order.append(a.group)
			groups[a.group].append(entry)

	for group_id in group_order:
		var submenu: Array = groups[group_id]
		top.append({
			"id": _GROUP_ID_PREFIX + String(group_id),
			"icon": _GROUP_ICONS.get(group_id),
			"submenu": submenu,
		})
	return top


func _show_action_menu(screen_pos: Vector2, items: Array[Dictionary]) -> void:
	_close_menu()

	_menu = _radial_menu_script.new()
	_menu.center_icon_texture = _CENTER_ICON
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
	# Submenu-parent pseudo-ids should never reach here (RadialMenu only emits
	# item_selected for leaves), but guard in case the contract changes.
	if id.begins_with(_GROUP_ID_PREFIX):
		return
	var action := _registry.find(StringName(id))
	if action == null:
		return
	var ctx := _build_context(_pending_cell)
	# State may have shifted between menu open and item click (player moved,
	# a structure got removed externally, etc.). Re-check availability against
	# fresh context before executing.
	if not action.is_available(ctx):
		if _ux_overlay and _ux_overlay.has_method(&"flash_denied"):
			_ux_overlay.flash_denied(_pending_cell)
		if _ux_overlay:
			_ux_overlay.unlock()
		return
	action.execute(ctx)
	# Per UX spec: the lock square should clear the instant a placement
	# commits, not wait for the menu's close animation. Placement/removal
	# actions carry no residual state, so unlock unconditionally here.
	if _ux_overlay:
		_ux_overlay.unlock()


func _on_menu_closed() -> void:
	_menu = null
	if _ux_overlay:
		_ux_overlay.unlock()


# ---------------------------------------------------------------------------
# Actions called via ActionContext (previously private)
# ---------------------------------------------------------------------------

func plant_frailejon(cell: Vector2i) -> void:
	var frailejon: Node2D = _frailejon_scene.instantiate()
	frailejon.cell = cell

	var base := pathfinder.cell_to_world(cell)
	var alt := pathfinder.altitude_center(cell)
	world.add_child(frailejon)
	frailejon.global_position = base + Vector2(0.0, -alt * Pathfinder.HALF_STEP_PX)
	_planted[cell] = frailejon
	if pathfinder and frailejon.pathfinding_penalty != 0.0:
		pathfinder.set_cell_penalty(cell, frailejon.pathfinding_penalty)


func remove_frailejon(cell: Vector2i) -> void:
	var node: Node2D = _planted.get(cell)
	if node == null:
		return
	_planted.erase(cell)
	if pathfinder:
		pathfinder.clear_cell_penalty(cell)
	if is_instance_valid(node):
		node.queue_free()


func begin_traversal(origin: Vector2i, kind: StringName) -> void:
	if traversal_placement_controller == null:
		push_warning("TileInteractionController: no TraversalPlacementController wired.")
		return
	traversal_placement_controller.begin(origin, kind)


## Remove whatever Traversal (bridge, ladder, future kinds) covers `cell`.
## Refuses to remove while the player stands on the traversal — matches the
## ActionRemove* is_available() guards but also protects scripted callers.
func remove_traversal_at(cell: Vector2i) -> void:
	if traversal_placement_controller == null:
		return
	var t: Traversal = traversal_placement_controller.find_traversal_at(cell)
	if t == null:
		return
	if is_player_on_traversal(t):
		push_warning(
			"TileInteractionController: refusing to remove traversal at %s — player stands on it."
			% cell
		)
		return
	traversal_placement_controller.remove_traversal(t)


func is_player_on_traversal(t: Traversal) -> bool:
	if player == null or t == null:
		return false
	for entry in t.painted_cells():
		if entry["cell"] == player.current_cell:
			return true
	return false


# ---------------------------------------------------------------------------
# Debug toast (used by ActionInspect)
# ---------------------------------------------------------------------------

## Shows `text` as a bottom-screen label for `duration` seconds, then fades.
## Cheap stand-in for a proper tile-info panel; tied to ActionInspect for now.
func show_debug_toast(text: String, duration: float) -> void:
	_ensure_toast()
	_toast_label.text = text
	_toast_label.modulate.a = 1.0
	_toast_label.visible = true
	if _toast_tween and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(duration)
	_toast_tween.tween_property(_toast_label, "modulate:a", 0.0, 0.35)
	_toast_tween.tween_callback(func() -> void: _toast_label.visible = false)
	# Also echo to stdout so the info is visible when UI is off.
	print("[inspect] ", text)


func _ensure_toast() -> void:
	if _toast_layer != null and is_instance_valid(_toast_layer):
		return
	_toast_layer = CanvasLayer.new()
	_toast_layer.layer = 100  # below the radial menu's 101
	add_child(_toast_layer)
	_toast_label = Label.new()
	_toast_label.add_theme_color_override(&"font_color", Color.WHITE)
	_toast_label.add_theme_color_override(&"font_shadow_color", Color(0, 0, 0, 0.85))
	_toast_label.add_theme_constant_override(&"shadow_offset_x", 1)
	_toast_label.add_theme_constant_override(&"shadow_offset_y", 1)
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_toast_label.offset_top = -28.0
	_toast_label.offset_bottom = -8.0
	_toast_label.visible = false
	_toast_layer.add_child(_toast_label)


func _event_global_position(mb: InputEventMouseButton) -> Vector2:
	var viewport := get_viewport()
	var canvas_xform := viewport.get_canvas_transform()
	return canvas_xform.affine_inverse() * mb.position
