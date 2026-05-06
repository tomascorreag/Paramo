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
## Sky/background fill that reads the ambient gradient directly.
## Place on a CanvasLayer outside the world canvas so CanvasModulate
## does not multiply it a second time.
@export var background_rect: ColorRect

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

# Last time-of-day sampled. _process is gated on this changing so paused or
# debug-slider-frozen states don't re-evaluate every curve and re-write
# every uniform every frame.
var _last_time: float = -INF

# Cached node list for the "shadow" group. Refreshed lazily after any tree
# change so the per-frame loop doesn't allocate via get_nodes_in_group.
var _shadow_nodes: Array[Node] = []
var _shadows_dirty: bool = true

# Whether the post-process shader is currently doing visible work. When all
# parameters are at neutral (no grading, no vignette, no tint) we hide the
# ColorRect entirely so the back-buffer copy + fragment pass don't run.
# Cheaper on the Compatibility renderer / WebGL2 / low-end GPUs.
var _post_process_active: bool = true
const _POST_NEUTRAL_EPSILON: float = 0.001


func _ready() -> void:
	_time_manager = get_node_or_null("/root/TimeManager")
	if _time_manager == null:
		push_error("DayNightSceneController: TimeManager autoload not found.")
		return

	if profile == null:
		profile = _DEFAULT_PROFILE as DayNightProfile

	if post_process_rect and post_process_rect.material:
		_post_process_material = post_process_rect.material as ShaderMaterial

	var tree := get_tree()
	if tree:
		tree.node_added.connect(_on_scene_tree_changed)
		tree.node_removed.connect(_on_scene_tree_changed)

	# Drive grading from the time_changed signal instead of polling _process.
	# This removes ordering coupling: any node that mutates time_of_day in its
	# own _ready (e.g. TitleIntro forcing night before first paint) triggers an
	# immediate re-grade, regardless of which controller's _ready ran first.
	# TimeManager emits time_changed every _process tick anyway, so cadence is
	# unchanged for the running clock.
	_time_manager.time_changed.connect(_on_time_changed)
	# Force one evaluation now for the initial paint. If a peer's _ready hasn't
	# run yet we'll re-grade when they emit; the dedup gate in _apply_grading
	# makes the redundant call free.
	_apply_grading(_time_manager.time_of_day)


func _on_scene_tree_changed(_n: Node) -> void:
	_shadows_dirty = true


func _on_time_changed(t: float) -> void:
	_apply_grading(t)


func _apply_grading(t: float) -> void:
	if profile == null:
		return

	# Curves are functions of time-of-day only; if the clock hasn't moved,
	# every uniform we'd write would be identical to last frame. Skip the
	# whole pass — paused gameplay and frozen debug-slider states cost zero.
	if absf(t - _last_time) < 0.0001:
		return
	_last_time = t

	# --- Ambient tint ---
	if profile.ambient_gradient:
		var ambient: Color = profile.ambient_gradient.sample(t)
		if canvas_modulate:
			canvas_modulate.color = ambient
		if background_rect:
			background_rect.color = Color.from_hsv(
				ambient.h, ambient.s, ambient.v * 0.5, ambient.a)

	# --- Post-process shader ---
	if _post_process_material:
		var temp_v: float = profile.temperature_curve.sample(t) if profile.temperature_curve else 0.0
		var contrast_v: float = profile.contrast_curve.sample(t) if profile.contrast_curve else 1.0
		var sat_v: float = profile.saturation_curve.sample(t) if profile.saturation_curve else 1.0
		var bright_v: float = profile.brightness_curve.sample(t) if profile.brightness_curve else 0.0
		var vig_v: float = profile.vignette_strength_curve.sample(t) if profile.vignette_strength_curve else 0.0
		var tint_s: float = profile.tint_strength_curve.sample(t) if profile.tint_strength_curve else 0.0

		# Only update uniforms when the pass is actually going to run. When all
		# values are at neutral the ColorRect is hidden below; skipping the
		# uniform writes keeps that path totally idle.
		var active: bool = (
			absf(temp_v) > _POST_NEUTRAL_EPSILON
			or absf(contrast_v - 1.0) > _POST_NEUTRAL_EPSILON
			or absf(sat_v - 1.0) > _POST_NEUTRAL_EPSILON
			or absf(bright_v) > _POST_NEUTRAL_EPSILON
			or vig_v > _POST_NEUTRAL_EPSILON
			or tint_s > _POST_NEUTRAL_EPSILON
		)
		if active:
			_post_process_material.set_shader_parameter(&"color_temperature", temp_v)
			_post_process_material.set_shader_parameter(&"contrast", contrast_v)
			_post_process_material.set_shader_parameter(&"saturation", sat_v)
			_post_process_material.set_shader_parameter(&"brightness", bright_v)
			_post_process_material.set_shader_parameter(&"vignette_strength", vig_v)
			if profile.tint_gradient:
				_post_process_material.set_shader_parameter(
					&"tint_color", profile.tint_gradient.sample(t))
			_post_process_material.set_shader_parameter(&"tint_strength", tint_s)
		if active != _post_process_active:
			_post_process_active = active
			if post_process_rect:
				post_process_rect.visible = active

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
	if _shadows_dirty:
		_shadows_dirty = false
		_shadow_nodes = get_tree().get_nodes_in_group(&"shadow")
	for node: Node in _shadow_nodes:
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
