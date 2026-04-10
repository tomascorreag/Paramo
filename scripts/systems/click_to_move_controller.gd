class_name ClickToMoveController
extends Node

# ============================================================================
# ClickToMoveController
# ============================================================================
#
# Input glue between mouse clicks and the path-following Player. Listens for
# left-click in _unhandled_input, resolves the click to a walkable cell via
# the Pathfinder, computes a path, and hands it to the Player.
#
# Deliberately kept as a small standalone node so:
#   - The Pathfinder stays input-agnostic (threats/NPCs can query it).
#   - Replacing click input with keyboard-select or gamepad-select later
#     only swaps this one script.
#   - A pure visual test scene can disable click-to-move by unchecking
#     `enabled` or deleting this node, without touching anything else.
#
# Scene setup:
#   1. Add a ClickToMoveController node anywhere in the scene.
#   2. Optionally drag the Pathfinder and Player into the inspector exports.
#      If left blank, the controller finds them via groups "pathfinder" and
#      "player" on _ready().
#
# ============================================================================


@export var pathfinder: Pathfinder
@export var player: Player
@export var enabled: bool = true
@export var debug_log_clicks: bool = false


signal path_dispatched(cells: Array[Vector2i])
signal click_rejected(global_pos: Vector2, reason: String)


func _ready() -> void:
	# Pathfinder and Player both register their groups in _enter_tree, so by
	# the time any node's _ready fires, the groups are populated regardless
	# of sibling order.
	if pathfinder == null:
		pathfinder = get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	if player == null:
		player = get_tree().get_first_node_in_group(&"player") as Player

	if pathfinder == null:
		push_error("ClickToMoveController: no Pathfinder wired and none found in group '%s'." % Pathfinder.GROUP_NAME)
	if player == null:
		push_error("ClickToMoveController: no Player wired and none found in group 'player'.")


func _unhandled_input(event: InputEvent) -> void:
	if not enabled:
		return
	if pathfinder == null or player == null:
		return
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return

	var global_pos := _event_global_position(mb)
	var target := pathfinder.resolve_click(global_pos)

	if debug_log_clicks:
		print("ClickToMoveController: click at %s -> cell %s" % [global_pos, target])

	if target == Pathfinder.NO_CELL:
		click_rejected.emit(global_pos, "no_walkable_cell_under_cursor")
		return

	var from := player.current_cell
	if target == from:
		click_rejected.emit(global_pos, "already_at_target")
		return

	var path := pathfinder.find_path(from, target)
	# AStar2D.get_id_path includes both endpoints. An empty return OR a
	# one-cell return (only the start) means no viable path.
	if path.size() < 2:
		click_rejected.emit(global_pos, "no_path")
		return

	# Drop the starting cell — player already stands there. follow_path
	# consumes cells as "next destinations."
	path.remove_at(0)
	player.follow_path(path)
	path_dispatched.emit(path)

	# Consume the event so lower-priority input handlers don't also react.
	get_viewport().set_input_as_handled()


# Resolve the click's global position. InputEventMouseButton.position is in
# viewport coords; we map through Viewport.canvas_transform so the result
# respects any Camera2D zoom/offset on the scene.
func _event_global_position(mb: InputEventMouseButton) -> Vector2:
	var viewport := get_viewport()
	var canvas_xform := viewport.get_canvas_transform()
	return canvas_xform.affine_inverse() * mb.position
