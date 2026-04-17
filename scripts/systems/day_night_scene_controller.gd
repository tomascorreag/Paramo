class_name DayNightSceneController
extends Node

## Bridges TimeManager (the clock) and the visual nodes in the scene tree.
## Samples the DayNightProfile every frame and drives CanvasModulate,
## post-process shader, player shadow, and player light.
##
## NOTE: The post-process ColorRect should live on a high CanvasLayer (e.g. 100).
## This intentionally grades the entire screen including UI — matching Dome Keeper's
## aesthetic. If ungraded UI is needed later, move UI above that layer.

const _DEFAULT_PROFILE: Resource = preload("res://resources/day_night/default_profile.tres")

@export var profile: DayNightProfile
@export var canvas_modulate: CanvasModulate
@export var post_process_rect: ColorRect

## Future: assign a second profile and weight to blend/override for seasons or weather.
@export_group("Wind")
@export var wind_materials: Array[ShaderMaterial]

@export_group("Water")
@export var water_materials: Array[ShaderMaterial]

@export_group("Overlay")
@export var overlay_profile: DayNightProfile
@export var overlay_weight: float = 0.0

var _post_process_material: ShaderMaterial
var _time_manager: Node  # TimeManager autoload


func _ready() -> void:
	_time_manager = get_node_or_null("/root/TimeManager")
	if _time_manager == null:
		push_error("DayNightSceneController: TimeManager autoload not found.")
		return

	if profile == null:
		profile = _DEFAULT_PROFILE as DayNightProfile

	if post_process_rect and post_process_rect.material:
		_post_process_material = post_process_rect.material as ShaderMaterial


func _process(_delta: float) -> void:
	if _time_manager == null or profile == null:
		return

	var t: float = _time_manager.time_of_day

	# --- Ambient tint ---
	if canvas_modulate and profile.ambient_gradient:
		canvas_modulate.color = profile.ambient_gradient.sample(t)

	# --- Post-process shader ---
	if _post_process_material:
		if profile.temperature_curve:
			_post_process_material.set_shader_parameter(
				&"color_temperature", profile.temperature_curve.sample(t))
		if profile.contrast_curve:
			_post_process_material.set_shader_parameter(
				&"contrast", profile.contrast_curve.sample(t))
		if profile.saturation_curve:
			_post_process_material.set_shader_parameter(
				&"saturation", profile.saturation_curve.sample(t))
		if profile.brightness_curve:
			_post_process_material.set_shader_parameter(
				&"brightness", profile.brightness_curve.sample(t))
		if profile.vignette_strength_curve:
			_post_process_material.set_shader_parameter(
				&"vignette_strength", profile.vignette_strength_curve.sample(t))
		if profile.tint_gradient:
			_post_process_material.set_shader_parameter(
				&"tint_color", profile.tint_gradient.sample(t))
		if profile.tint_strength_curve:
			_post_process_material.set_shader_parameter(
				&"tint_strength", profile.tint_strength_curve.sample(t))

	# --- Wind ---
	if profile.wind_intensity_curve and not wind_materials.is_empty():
		var wind_val: float = profile.wind_intensity_curve.sample(t)
		for mat: ShaderMaterial in wind_materials:
			mat.set_shader_parameter(&"wind_intensity", wind_val)

	# --- Water ---
	if profile.water_intensity_curve and not water_materials.is_empty():
		var water_val: float = profile.water_intensity_curve.sample(t)
		for mat: ShaderMaterial in water_materials:
			mat.set_shader_parameter(&"water_intensity", water_val)

	# --- All shadows ---
	var shadow_nodes := get_tree().get_nodes_in_group(&"shadow")
	for node: Node in shadow_nodes:
		var mat := (node as CanvasItem).material as ShaderMaterial
		if mat == null:
			continue
		var scale: float = node.get_meta(&"shadow_scale", 1.0)
		if profile.shadow_opacity_curve:
			mat.set_shader_parameter(
				&"shadow_opacity", profile.shadow_opacity_curve.sample(t))
		if profile.shadow_length_curve:
			# Round to integer so the tail grows/shrinks in whole-pixel steps
			# instead of having taper-edge pixels toggle at close fractional
			# thresholds (which reads as sub-pixel motion).
			mat.set_shader_parameter(
				&"shadow_length",
				roundf(profile.shadow_length_curve.sample(t) * scale))
