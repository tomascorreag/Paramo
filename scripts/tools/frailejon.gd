class_name Frailejon
extends Node2D

const MAX_GROWTH_STAGE: int = 3

# Player sprite dimensions (baseline for shadow proportions).
# Player: cap_width=6, max_height=4, ~16px wide, ~25px tall.
const REF_WIDTH: float = 16.0
const REF_HEIGHT: float = 25.0
const REF_CAP_WIDTH: float = 6.0
const REF_MAX_HEIGHT: float = 4.0

## Chance to grow each in-game hour. 1.0 = always, 0.5 = 50%.
@export var growth_chance: float = 0.6

## Extra pathfinding cost charged to agents stepping onto this cell. Values
## below 1.0 nudge (paths prefer a clear tie-equivalent); higher values force
## detours. Frailejones are meant to be stepped-over, not walls.
@export var pathfinding_penalty: float = 0.4

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _shadow: Sprite2D = $Shadow

var cell: Vector2i
var growth_stage: int = 0
var _shadow_scale: float = 1.0

var _time_manager: Node
var _last_hour: int = -1


func _ready() -> void:
	_sprite.flip_h = randf() < 0.5
	_sprite.position = Vector2(randi_range(-4, 4), randi_range(-4, 0))

	_shadow.frame = _sprite.frame
	_update_shadow_params()
	_update_shadow_roughness()

	# Reparent shadow for independent y-sorting (same pattern as Player).
	remove_child(_shadow)
	get_parent().add_child.call_deferred(_shadow)
	_shadow.add_to_group(&"shadow")
	call_deferred(&"_position_shadow")

	_time_manager = get_node_or_null("/root/TimeManager")
	if _time_manager:
		_last_hour = int(_time_manager.time_of_day * 24.0) % 24


func _exit_tree() -> void:
	if is_instance_valid(_shadow):
		_shadow.queue_free()


func _process(_delta: float) -> void:
	if growth_stage >= MAX_GROWTH_STAGE or _time_manager == null:
		return
	var hour: int = int(_time_manager.time_of_day * 24.0) % 24
	if hour != _last_hour:
		_last_hour = hour
		if randf() <= growth_chance:
			set_growth_stage(growth_stage + 1)


func set_growth_stage(stage: int) -> void:
	growth_stage = clampi(stage, 0, MAX_GROWTH_STAGE)
	if _sprite:
		_sprite.frame = growth_stage
	if is_instance_valid(_shadow):
		_shadow.frame = growth_stage
		_update_shadow_params()


func _update_shadow_params() -> void:
	if not is_instance_valid(_shadow) or _sprite == null or _sprite.texture == null:
		return
	var dims: Vector2 = _measure_frame_dimensions()
	var w_ratio: float = dims.x / REF_WIDTH if REF_WIDTH > 0.0 else 1.0
	var h_ratio: float = dims.y / REF_HEIGHT if REF_HEIGHT > 0.0 else 1.0

	var mat: ShaderMaterial = _shadow.material as ShaderMaterial
	if mat:
		mat.set_shader_parameter(&"cap_width", REF_CAP_WIDTH * w_ratio)
		mat.set_shader_parameter(&"max_height", REF_MAX_HEIGHT * w_ratio)

	_shadow_scale = h_ratio
	_shadow.set_meta(&"shadow_scale", _shadow_scale)


func _update_shadow_roughness() -> void:
	# Stationary entity: sample once at spawn. Frailejones don't move, and
	# growth-stage changes don't relocate them, so a single set is enough.
	if not is_instance_valid(_shadow):
		return
	var mat: ShaderMaterial = _shadow.material as ShaderMaterial
	if mat == null:
		return
	var pathfinder := get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	var r: float = pathfinder.roughness_at(cell) if pathfinder != null else 0.0
	mat.set_shader_parameter(&"roughness", r)
	var nm: Vector4 = (
		pathfinder.neighbor_altitude_match(cell) if pathfinder != null
		else Vector4.ONE
	)
	mat.set_shader_parameter(&"neighbor_match", nm)


func _measure_frame_dimensions() -> Vector2:
	var img: Image = _sprite.texture.get_image()
	if img == null:
		return Vector2(REF_WIDTH, REF_HEIGHT)
	var fw: int = img.get_width() / _sprite.hframes
	var fh: int = img.get_height() / _sprite.vframes
	var col: int = _sprite.frame % _sprite.hframes
	var row: int = _sprite.frame / _sprite.hframes
	var ox: int = col * fw
	var oy: int = row * fh

	var top: int = fh
	var bottom: int = 0
	var left: int = fw
	var right: int = 0
	for y in range(fh):
		for x in range(fw):
			if img.get_pixel(ox + x, oy + y).a > 0.01:
				top = mini(top, y)
				bottom = maxi(bottom, y)
				left = mini(left, x)
				right = maxi(right, x)
	if top > bottom:
		return Vector2(1.0, 1.0)
	return Vector2(float(right - left + 1), float(bottom - top + 1))


func _position_shadow() -> void:
	if is_instance_valid(_shadow):
		_shadow.global_position = Vector2(
			roundf(global_position.x + _sprite.position.x),
			roundf(global_position.y + _sprite.position.y - 1.0))
