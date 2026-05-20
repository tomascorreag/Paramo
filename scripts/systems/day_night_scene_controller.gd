class_name DayNightSceneController
extends Node

## Bridges TimeManager (the clock) and the visual nodes in the scene tree.
## Samples the DayNightProfile every frame and drives CanvasModulate,
## post-process shader, player shadow, and player light.
##
## NOTE: The post-process ColorRect should live on a high CanvasLayer (e.g. 100).
## This intentionally grades the entire screen including UI — matching Dome Keeper's
## aesthetic. If ungraded UI is needed later, move UI above that layer.
##
## Also owns the rain weather state machine: probability rolls on
## TimeManager.period_changed (six per day), curves drawn from the active
## DayNightProfile, intensity ramped/noised each _process, and the resulting
## rain_amount + streak_angle written to the RainLayer found via group lookup.
## The debug overlay can grab control with set_rain_override / clear_rain_override.

const _DEFAULT_PROFILE: Resource = preload("res://resources/day_night/default_profile.tres")

## Other nodes (e.g. debug overlay) find us via this group rather than walking
## the scene tree by type.
const GROUP: StringName = &"day_night_controller"

enum _RainState { IDLE, RAMPING_UP, ACTIVE, RAMPING_DOWN }

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

# --- Rain weather state ---
# Most recent wind_intensity sample, cached so _process can multiply it into
# the streak angle without re-sampling the curve. Stays valid even when
# wind_materials is empty.
var _last_wind_val: float = 0.0
var _rain_layer: RainLayer
var _rain_state: int = _RainState.IDLE
# Real-time seconds spent in the current state (used for ramp progress and as
# the input to the intensity noise wave).
var _rain_state_t: float = 0.0
# In-game time (fractions of a day) spent in the current state. Drives the
# post-start / post-stop cooldowns and the max-event-duration force-stop, so
# they pause with the clock and scale with seconds_per_game_day. Initialized
# to INF so the boot roll out of IDLE isn't blocked by the post-stop cooldown.
var _rain_state_game_t: float = INF
# Target the most recent rain event ramped UP to (the "held" intensity).
var _rain_target: float = 0.0
# What rain_current was at the moment a ramp began. RAMPING_UP starts from 0
# (or wherever we already were if rolled mid-fade); RAMPING_DOWN starts from
# whatever intensity was being held when the stop roll fired.
var _rain_ramp_from: float = 0.0
# Smoothed, noise-modulated value pushed to the shader.
var _rain_current: float = 0.0
# Debug-only manual override. >=0 disables the state machine and snaps
# rain_current to this value. <0 means "no override, run events".
var _rain_override: float = -1.0


func _ready() -> void:
	add_to_group(GROUP)

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
	# Weather rolls — six per simulated day, naturally pause with TimeManager.
	_time_manager.period_changed.connect(_on_period_changed)
	# RainLayer lookup deferred so its _ready (which adds it to the group)
	# has fired. Maps without a RainLayer simply skip all rain logic.
	call_deferred(&"_resolve_rain_layer")
	# Force one evaluation now for the initial paint. If a peer's _ready hasn't
	# run yet we'll re-grade when they emit; the dedup gate in _apply_grading
	# makes the redundant call free.
	_apply_grading(_time_manager.time_of_day)


func _resolve_rain_layer() -> void:
	_rain_layer = get_tree().get_first_node_in_group(&"rain_layer") as RainLayer
	# Boot roll: give the first launch a chance to start raining immediately
	# instead of forcing the player to wait for the first period boundary.
	# Uses the same P(start) = base * curve formula, so dry-day-time-of-day
	# launches still usually start dry.
	_roll_rain_start_if_idle()


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
	# Sampled even when wind_materials is empty, because the rain controller
	# multiplies the cached value into streak_angle each frame.
	if profile.wind_intensity_curve:
		_last_wind_val = profile.wind_intensity_curve.sample(t)
		for mat: ShaderMaterial in wind_materials:
			mat.set_shader_parameter(&"wind_intensity", _last_wind_val)

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


# -----------------------------------------------------------------------------
# Rain weather
# -----------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _rain_layer == null or profile == null:
		return
	# Weather pauses with the game clock. Visual ramp continues smoothly if
	# the user un-pauses mid-fade because _rain_state_t only advances here.
	if _time_manager != null and _time_manager.paused:
		return

	# In-game time tick for cooldowns + max-event-duration. Mirrors how
	# TimeManager advances time_of_day. Skipping when seconds_per_game_day <= 0
	# matches TimeManager's own guard (frozen clock = frozen weather timers).
	if _time_manager != null and _time_manager.seconds_per_game_day > 0.0:
		_rain_state_game_t += delta * (
			_time_manager.time_scale / _time_manager.seconds_per_game_day)

	if _rain_override >= 0.0:
		_rain_current = _rain_override
	else:
		_evolve_rain(delta)

	_push_rain_to_shader()


func _evolve_rain(delta: float) -> void:
	_rain_state_t += delta
	match _rain_state:
		_RainState.IDLE:
			_rain_current = 0.0
		_RainState.RAMPING_UP:
			var dur: float = maxf(0.01, profile.rain_ramp_up_seconds)
			var a: float = clampf(_rain_state_t / dur, 0.0, 1.0)
			_rain_current = lerpf(_rain_ramp_from, _rain_target, a)
			if a >= 1.0:
				_rain_state = _RainState.ACTIVE
				_rain_state_t = 0.0
				_rain_state_game_t = 0.0
		_RainState.ACTIVE:
			# Hold near target with low-amplitude flutter so the visual doesn't
			# read as frozen at a fixed value.
			_rain_current = clampf(
				_rain_target + _sample_intensity_noise(_rain_state_t),
				0.0, 1.0)
			# Force a stop if the storm has run past its max in-game duration.
			# Bypasses the random stop roll so a streak of unlucky rolls can't
			# pin the player in permanent rain.
			if profile.rain_max_event_duration > 0.0 \
					and _rain_state_game_t >= profile.rain_max_event_duration:
				_stop_rain_event()
		_RainState.RAMPING_DOWN:
			var dur: float = maxf(0.01, profile.rain_ramp_down_seconds)
			var a: float = clampf(_rain_state_t / dur, 0.0, 1.0)
			_rain_current = lerpf(_rain_ramp_from, 0.0, a)
			if a >= 1.0:
				_rain_state = _RainState.IDLE
				_rain_state_t = 0.0
				_rain_state_game_t = 0.0
				_rain_target = 0.0


# Layered sin waves (irrational frequency ratio = non-repeating pattern).
# Cheaper than a noise allocation and visually indistinguishable at this
# amplitude.
func _sample_intensity_noise(t: float) -> float:
	if profile.rain_noise_amplitude <= 0.0:
		return 0.0
	var f: float = profile.rain_noise_frequency
	var s: float = sin(t * TAU * f) * 0.6 + sin(t * TAU * f * 1.71 + 1.3) * 0.4
	return s * profile.rain_noise_amplitude


func _push_rain_to_shader() -> void:
	_rain_layer.set_amount(_rain_current)
	# Sign + magnitude both live in profile.rain_max_angle. Wind has no
	# direction in the data model — only intensity — so a single signed scalar
	# on the profile is sufficient.
	var angle: float = profile.rain_max_angle * _rain_current * _last_wind_val
	_rain_layer.set_streak_angle(angle)


func _on_period_changed(_new: StringName, _old: StringName) -> void:
	_roll_weather()


# Single-shot version of the period roll used at boot. Only rolls a START
# from IDLE; never tries to stop existing rain (the scene was just loaded).
func _roll_rain_start_if_idle() -> void:
	if _rain_state == _RainState.IDLE:
		_roll_weather()


func _roll_weather() -> void:
	if profile == null or profile.rain_probability_curve == null:
		return
	if _rain_override >= 0.0:
		return
	# Don't interrupt a ramp mid-fade. Rolls only matter at the two stable
	# states (IDLE / ACTIVE); the next period boundary catches the result.
	if _rain_state != _RainState.IDLE and _rain_state != _RainState.ACTIVE:
		return

	var t: float = _time_manager.time_of_day
	var p_curve: float = clampf(profile.rain_probability_curve.sample(t), 0.0, 1.0)
	var base: float = clampf(profile.rain_base_probability, 0.0, 1.0)

	if _rain_state == _RainState.IDLE:
		# Post-stop cooldown: a stop that just happened needs a dry buffer
		# before the next start roll, otherwise the curve makes rain restart
		# on the very next period boundary.
		if _rain_state_game_t < profile.rain_post_stop_cooldown:
			return
		if randf() < base * p_curve:
			_start_rain_event()
	else: # ACTIVE
		# Post-start cooldown: a fresh storm gets at least this much in-game
		# time before it's eligible to stop, so a brief unlucky roll doesn't
		# kill an event seconds after the visuals ramped up.
		if _rain_state_game_t < profile.rain_post_start_cooldown:
			return
		if randf() < base * (1.0 - p_curve):
			_stop_rain_event()


func _start_rain_event() -> void:
	var lo: float = clampf(profile.rain_target_intensity_min, 0.0, 1.0)
	var hi: float = maxf(lo, clampf(profile.rain_target_intensity_max, 0.0, 1.0))
	_rain_ramp_from = _rain_current
	_rain_target = randf_range(lo, hi)
	_rain_state = _RainState.RAMPING_UP
	_rain_state_t = 0.0


func _stop_rain_event() -> void:
	_rain_ramp_from = _rain_current
	_rain_state = _RainState.RAMPING_DOWN
	_rain_state_t = 0.0


# --- Debug overlay API ---

## Snap rain to `value` and suspend the event state machine. Clear with
## clear_rain_override() to resume auto rolls.
func set_rain_override(value: float) -> void:
	_rain_override = clampf(value, 0.0, 1.0)


func clear_rain_override() -> void:
	_rain_override = -1.0
	# The state machine continues from wherever it was. If the override held a
	# value > 0 mid-IDLE the next _process tick will snap rain back to 0 (or
	# to wherever the ramp says it should be). That's a deliberately abrupt
	# debug behavior — production weather only uses the event path.


func get_rain_current_intensity() -> float:
	return _rain_current
