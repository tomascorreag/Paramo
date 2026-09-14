extends GutTest

# The walk reticle: while the player walks to a clicked cell, UXOverlay pins
# BaseX + Circle on that cell and ignores the mouse until Player.arrived.
# Runs on the handcrafted tileset test map, which carries the full
# gameplay_base stack (Pathfinder, ClickToMoveController, UXOverlay, Player).

const SCENE: String = "res://scenes/tools/tileset_test.tscn"

var _map: Node
var _ux: UXOverlay
var _player: Player
var _pf: Pathfinder
var _c2m: Node


func before_each() -> void:
	_map = load(SCENE).instantiate()
	add_child_autofree(_map)
	# StructureLayerManager builds the grid in _ready and the player snaps to
	# its cell a frame later; give the stack a moment.
	await wait_frames(25)
	_ux = get_tree().get_first_node_in_group(UXOverlay.GROUP_NAME) as UXOverlay
	_player = get_tree().get_first_node_in_group(&"player") as Player
	_pf = get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	_c2m = get_tree().get_first_node_in_group(&"click_to_move_controller")
	assert_not_null(_ux)
	assert_not_null(_player)
	assert_not_null(_pf)
	assert_not_null(_c2m)


# A short walk from where the player stands: the nearest walkable cell with a
# path of 2-4 steps. Returns the path (start cell dropped) or [].
func _short_path() -> Array[Vector2i]:
	var from: Vector2i = _player.current_cell
	for r in range(1, 4):
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var to: Vector2i = from + Vector2i(dx, dy)
				if to == from:
					continue
				var path := _pf.find_path(from, to)
				if path.size() >= 3 and path.size() <= 5:
					path.remove_at(0)
					return path
	return []


func _wait_until_still(max_frames: int = 900) -> void:
	for i in max_frames:
		if not _player.is_moving():
			await wait_frames(2)
			return
		await wait_frames(1)


func test_dispatch_pins_reticle_on_destination_until_arrival() -> void:
	var path := _short_path()
	assert_gt(path.size(), 0, "the test map must offer a short walk")
	if path.is_empty():
		return
	var dest: Vector2i = path[path.size() - 1]

	_player.follow_path(path)
	_c2m.path_dispatched.emit(path)
	assert_true(_ux.is_pinned(), "a user click pins the reticle")
	assert_eq(_ux.hovered_cell, dest, "on the destination")

	await wait_frames(5)
	assert_true(_ux.is_pinned(), "still pinned mid-walk whatever the mouse does")
	assert_eq(_ux.hovered_cell, dest)

	await _wait_until_still()
	assert_false(_player.is_moving())
	assert_false(_ux.is_pinned(), "arrival hands the reticle back to the mouse")


func test_new_click_repins_on_the_new_destination() -> void:
	var path := _short_path()
	if path.is_empty():
		return
	_player.follow_path(path)
	_c2m.path_dispatched.emit(path)
	var first: Vector2i = path[path.size() - 1]
	assert_eq(_ux.hovered_cell, first)
	# Redirect to the first step only.
	var shorter: Array[Vector2i] = [path[0]]
	_player.follow_path(shorter)
	_c2m.path_dispatched.emit(shorter)
	assert_true(_ux.is_pinned())
	assert_eq(_ux.hovered_cell, path[0], "the pin follows the latest click")
	await _wait_until_still()
	assert_false(_ux.is_pinned())


func test_lock_interrupts_and_unlock_resumes_the_pin() -> void:
	var path := _short_path()
	if path.is_empty():
		return
	_player.follow_path(path)
	_c2m.path_dispatched.emit(path)
	_ux.lock_at(path[0])
	assert_false(_ux.is_pinned(), "a lock takes precedence")
	_ux.unlock()
	assert_true(_ux.is_pinned(), "unlock mid-walk goes back to the pin, not the mouse")
	await _wait_until_still()
	assert_false(_ux.is_pinned())


func test_committed_pin_forces_the_solid_circle() -> void:
	var path := _short_path()
	if path.is_empty():
		return
	# Pick a step cell with no meaningful action, so a plain pin would be dim.
	var tic := get_tree().get_first_node_in_group(
		TileInteractionController.GROUP_NAME) as TileInteractionController
	var dest := Pathfinder.NO_CELL
	for c in path:
		if not tic.has_meaningful_action(c):
			dest = c
			break
	if dest == Pathfinder.NO_CELL:
		pending("every short-walk cell carries an action on this map")
		return
	_player.follow_path(path)
	_ux.pin_destination(dest)
	assert_eq(_ux._circle.texture, UXOverlay._CIRCLE_DIM, "control: a plain pin is dim here")
	_ux.pin_destination(dest, true)
	assert_true(_ux.is_pin_committed())
	assert_true(_ux._circle.visible)
	assert_eq(_ux._circle.texture, UXOverlay._CIRCLE_SOLID, "a committed pin is the live circle")
	_ux.lock_at(dest)
	_ux.unlock()
	assert_true(_ux.is_pin_committed(), "unlock mid-walk resumes the COMMITTED pin")
	await _wait_until_still()
	assert_false(_ux.is_pinned())
	assert_false(_ux.is_pin_committed(), "arrival clears the commitment")


func test_left_click_is_refused_during_walk_then_act() -> void:
	var path := _short_path()
	if path.is_empty():
		return
	var tic := get_tree().get_first_node_in_group(
		TileInteractionController.GROUP_NAME) as TileInteractionController
	var dest: Vector2i = path[path.size() - 1]
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = get_viewport().get_canvas_transform() * _ux.cell_visual_center(dest)
	watch_signals(_c2m)

	tic._pending_action = TileAction.new()
	_c2m._unhandled_input(ev)
	assert_signal_emit_count(_c2m, "path_dispatched", 0, "refused while an action walk is committed")
	assert_false(_player.is_moving())

	# Control: the same click walks once nothing is committed.
	tic._pending_action = null
	_c2m._unhandled_input(ev)
	assert_signal_emit_count(_c2m, "path_dispatched", 1, "control: the click itself is a valid move")
	_player.stop()
	await _wait_until_still()


func test_arrived_signal_fires_once_per_walk() -> void:
	var path := _short_path()
	if path.is_empty():
		return
	watch_signals(_player)
	_player.follow_path(path)
	await _wait_until_still()
	assert_signal_emit_count(_player, "arrived", 1)
