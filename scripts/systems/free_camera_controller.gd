class_name FreeCameraController
extends Camera2D

# ============================================================================
# FreeCameraController
# ============================================================================
#
# Debug-only Camera2D that pans on WASD when `Debug.free_movement` is on.
# Sits dormant otherwise — its `current` flag mirrors the toggle, so the
# player's camera resumes ownership the moment free mode is disabled.
#
# Lives at scene-root level (sibling of World/Player) so its transform is
# the world-space pan position directly. No smoothing, so input feels
# immediate; the player camera's smoothing kicks back in on toggle off.
#
# ============================================================================


## Pan speed in world pixels per second when a WASD axis is held.
@export var pan_speed: float = 400.0


func _ready() -> void:
	Debug.free_movement_changed.connect(_on_free_movement_changed)
	# Late-arrival safety: if the toggle was already on (e.g. via console)
	# before this node entered the tree, take over now.
	if Debug.free_movement:
		_take_over()


func _process(delta: float) -> void:
	if not Debug.free_movement:
		return
	var dir: Vector2 = Input.get_vector(
		&"move_left", &"move_right", &"move_up", &"move_down"
	)
	if dir != Vector2.ZERO:
		global_position += dir * pan_speed * delta


# ----------------------------------------------------------------------------
# Toggle handling
# ----------------------------------------------------------------------------

func _on_free_movement_changed(is_enabled: bool) -> void:
	if is_enabled:
		_take_over()
	else:
		_release_to_player()


func _take_over() -> void:
	# Seed our position from the camera that's currently rendering so the view
	# doesn't jump on toggle-on. get_screen_center_position returns the world
	# point under the screen center, which is what we want as our pan origin.
	var prev: Camera2D = get_viewport().get_camera_2d()
	if prev != null and prev != self:
		global_position = prev.get_screen_center_position()
	make_current()


func _release_to_player() -> void:
	var player_cam: Camera2D = _find_player_camera()
	if player_cam != null:
		player_cam.make_current()
	# else: leave us current — debug-only path, no player to hand back to.


func _find_player_camera() -> Camera2D:
	var player: Node = get_tree().get_first_node_in_group(&"player")
	if player == null:
		return null
	return player.get_node_or_null(^"Camera2D") as Camera2D
