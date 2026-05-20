class_name RainLayer
extends CanvasLayer
## RainLayer — exposes `set_amount()` for the debug overlay and each frame
## pushes (a) the active camera's world top-left, so the rain pattern stays
## anchored to the world, and (b) the DayNight ambient tint (the same
## CanvasModulate that tints the world itself), so the rain reads as part of
## the scene's lighting at every time of day.

const GROUP: StringName = &"rain_layer"
const AMBIENT_GROUP: StringName = &"ambient_modulate"
const LANTERN_GROUP: StringName = &"player_lantern"

const PARAM_AMOUNT: StringName = &"rain_amount"
const PARAM_STREAK_ANGLE: StringName = &"streak_angle"
const PARAM_CAMERA: StringName = &"camera_offset"
const PARAM_VIEWPORT: StringName = &"viewport_size"
const PARAM_TINT: StringName = &"tint_color"
const PARAM_LANTERN_POS: StringName = &"lantern_pos_view"
const PARAM_LANTERN_RADIUS: StringName = &"lantern_radius_px"
const PARAM_LANTERN_ENERGY: StringName = &"lantern_energy"
const PARAM_LANTERN_COLOR: StringName = &"lantern_color"

const LANTERN_FAR_OFFSCREEN := Vector2(-100000.0, -100000.0)

@onready var _rect: ColorRect = $RainRect
var _mat: ShaderMaterial
var _vp_size: Vector2 = Vector2(480, 270)
var _ambient: CanvasModulate
var _lantern: PlayerLightController
var _lantern_lookup_done: bool = false


func _ready() -> void:
	add_to_group(GROUP)
	_mat = _rect.material as ShaderMaterial
	if _mat != null:
		var v: Variant = _mat.get_shader_parameter(PARAM_VIEWPORT)
		if v is Vector2:
			_vp_size = v
	# The CanvasModulate that tints the World canvas. Same tint applied to the
	# world — using the BG rect instead darkens rain (BG is HSV-halved to avoid
	# double-tinting). If absent (e.g. rain instanced outside a gameplay map)
	# the tint stays at its inspector default.
	_ambient = get_tree().get_first_node_in_group(AMBIENT_GROUP) as CanvasModulate
	# Lantern lookup deferred so Player._ready (which mounts the controller and
	# adds it to LANTERN_GROUP) has run first.
	call_deferred(&"_resolve_lantern")


func _resolve_lantern() -> void:
	_lantern = get_tree().get_first_node_in_group(LANTERN_GROUP) as PlayerLightController
	_lantern_lookup_done = true


func _process(_delta: float) -> void:
	if _mat == null:
		return

	var cam_off: Vector2 = Vector2.ZERO
	var cam: Camera2D = get_viewport().get_camera_2d()
	if cam != null:
		var center: Vector2 = cam.get_screen_center_position()
		cam_off = center - _vp_size * 0.5
		_mat.set_shader_parameter(PARAM_CAMERA, cam_off)

	if _ambient != null:
		_mat.set_shader_parameter(PARAM_TINT, _ambient.color)

	_update_lantern(cam_off)


# Pushes the active lantern's view-space position, elliptical radius, energy,
# and color to the shader. Lookup happens once after _ready (deferred); maps
# without a player just leave lantern_energy at 0 and rain renders unchanged.
func _update_lantern(cam_off: Vector2) -> void:
	if not _lantern_lookup_done:
		return
	if _lantern == null or not is_instance_valid(_lantern) or not _lantern.enabled:
		_mat.set_shader_parameter(PARAM_LANTERN_ENERGY, 0.0)
		_mat.set_shader_parameter(PARAM_LANTERN_POS, LANTERN_FAR_OFFSCREEN)
		return

	var r: float = _lantern.get_effective_radius_px()
	var gscale: Vector2 = _lantern.global_scale
	var radius_px := Vector2(r * absf(gscale.x), r * absf(gscale.y))
	var norm_energy: float = _lantern.get_current_energy() / maxf(0.0001, _lantern.max_energy)

	_mat.set_shader_parameter(PARAM_LANTERN_POS, _lantern.global_position - cam_off)
	_mat.set_shader_parameter(PARAM_LANTERN_RADIUS, radius_px)
	_mat.set_shader_parameter(PARAM_LANTERN_ENERGY, clampf(norm_energy, 0.0, 1.0))
	_mat.set_shader_parameter(PARAM_LANTERN_COLOR, _lantern.color)


func set_amount(amount: float) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter(PARAM_AMOUNT, clamp(amount, 0.0, 1.0))


func get_amount() -> float:
	if _mat == null:
		return 0.0
	return float(_mat.get_shader_parameter(PARAM_AMOUNT))


## Driven by DayNightSceneController as
## angle = profile.rain_max_angle * rain_current * wind_current. Clamped to the
## shader's hint_range so values outside [-0.6, 0.6] don't make streaks miss
## the SPLASH_X_RADIUS neighborhood.
func set_streak_angle(angle: float) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter(PARAM_STREAK_ANGLE, clamp(angle, -0.6, 0.6))
