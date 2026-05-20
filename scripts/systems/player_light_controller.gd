class_name PlayerLightController
extends PointLight2D

## Player lantern visuals. Handles range, falloff texture, and animated
## energy transitions driven by activate() / deactivate().

const GROUP: StringName = &"player_lantern"

# Half-extent (in source-texture pixels) of the radial gradient before
# texture_scale is applied. The baked GradientTexture2D is 128 px square
# with FILL_RADIAL from center, so its visual radius is 64 px.
const _BASE_RADIUS_PX: float = 64.0

@export var light_range: float = 4.0
@export var falloff: Curve

@export_group("Energy")
## Peak energy when fully active.
@export var max_energy: float = 1.0
## Curve mapping transition progress [0..1] to energy multiplier [0..1].
## If unset, falls back to linear interpolation.
@export var energy_curve: Curve
## How long (seconds) the activate / deactivate fade takes.
@export var transition_duration: float = 0.5

# 0 = off, 1 = fully on. Driven toward _target via _process.
var _transition_t: float = 0.0
var _target_active: bool = false


func _ready() -> void:
	add_to_group(GROUP)
	energy = 0.0
	enabled = false
	texture_scale = light_range
	# Defer texture replacement so the old SubResource is fully released first.
	if falloff:
		call_deferred(&"_bake_falloff")
	else:
		call_deferred(&"_create_default_falloff")


func activate() -> void:
	if _target_active:
		return
	_target_active = true
	enabled = true


func deactivate() -> void:
	_target_active = false


func _process(delta: float) -> void:
	if not _target_active and not enabled:
		return

	if transition_duration <= 0.0:
		_transition_t = 1.0 if _target_active else 0.0
		if not _target_active:
			enabled = false
	elif _target_active:
		_transition_t = minf(_transition_t + delta / transition_duration, 1.0)
	else:
		_transition_t = maxf(_transition_t - delta / transition_duration, 0.0)
		if _transition_t <= 0.0:
			enabled = false

	if enabled:
		var curve_val: float = energy_curve.sample(_transition_t) if energy_curve else _transition_t
		energy = curve_val * max_energy


## Visible radius of the gradient texture in world pixels, before the node's
## own `scale` is applied. Multiply by `global_scale.{x,y}` for the elliptical
## extent (lantern uses scale.y = 0.5 for isometric squash).
func get_effective_radius_px() -> float:
	return _BASE_RADIUS_PX * texture_scale


## Current (already-lerped) energy. Useful for external systems that want to
## react to the activate/deactivate fade without duplicating the curve sample.
func get_current_energy() -> float:
	return energy


func _create_default_falloff() -> void:
	falloff = Curve.new()
	falloff.min_value = 0.0
	falloff.max_value = 1.0
	falloff.add_point(Vector2(0.0, 0.6))
	falloff.add_point(Vector2(0.2, 0.4))
	falloff.add_point(Vector2(0.5, 0.15))
	falloff.add_point(Vector2(0.8, 0.03))
	falloff.add_point(Vector2(1.0, 0.0))
	_bake_falloff()


func _bake_falloff() -> void:
	var steps: int = 32
	var grad := Gradient.new()
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for i: int in range(steps + 1):
		var d: float = float(i) / float(steps)
		offsets.append(d)
		colors.append(Color(1.0, 1.0, 1.0, falloff.sample(d)))
	grad.offsets = offsets
	grad.colors = colors

	var tex := GradientTexture2D.new()
	tex.width = 128
	tex.height = 128
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.gradient = grad
	texture = tex
