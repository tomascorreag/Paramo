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

# Last shadow curve samples actually APPLIED to the shadow group. The node loop
# in _apply_grading is skipped while both are unchanged within epsilon and the
# node list hasn't changed — see the gate there. -INF forces the first pass.
var _last_shadow_opacity: float = -INF
var _last_shadow_length: float = -INF

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
# The rain state machine itself lives in WeatherModel (shared with the
# headless balance simulator — same logic, one source of truth). This node
# keeps only the scene-facing duties: clock/pause gating, the debug override,
# and pushing the published intensity to the RainLayer shader.
var _weather: WeatherModel = WeatherModel.new()
# Weather's own RNG stream: the model's roll() draws only from here, so
# unrelated global randf() consumers (VFX flame layouts, dirt-variant picks)
# can never perturb when it rains. Randomized per scene load; the simulator
# instead seeds its own model per run.
var _rain_rng: RandomNumberGenerator = RandomNumberGenerator.new()
# Debug-only manual override. >=0 disables the state machine and snaps
# rain_current to this value. <0 means "no override, run events".
var _rain_override: float = -1.0
# Climate-change scale on the rain START probability (never the stop roll —
# see _roll_weather). 1.0 = the profile as authored; ClimateController lowers
# it each season. Lives here rather than on DayNightProfile because profiles
# are shared .tres — mutating one at runtime would leak into the editor and
# every later run.
var rain_probability_scale: float = 1.0


## Climate hook: scales how often rain STARTS (clamped >= 0). Set by
## ClimateController at season boundaries; a fresh scene resets it to 1.0.
func set_rain_probability_scale(scale: float) -> void:
	rain_probability_scale = maxf(0.0, scale)


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


## Swap the active day/night look (Dry → Wet at a season boundary) and re-grade
## immediately at the current time. Null is ignored, so a season without an
## authored profile leaves the current look untouched. Resets the time dedup so
## the re-grade isn't skipped when the clock hasn't moved since the swap.
func set_profile(new_profile: DayNightProfile) -> void:
	if new_profile == null or new_profile == profile:
		return
	profile = new_profile
	if _time_manager != null:
		_last_time = -1.0
		# Different curves may coincidentally sample equal at the swap instant,
		# but the has-curve booleans can flip — force one full shadow pass.
		_last_shadow_opacity = -INF
		_last_shadow_length = -INF
		_apply_grading(_time_manager.time_of_day)


func _resolve_rain_layer() -> void:
	_rain_layer = get_tree().get_first_node_in_group(&"rain_layer") as RainLayer
	# Boot roll: give the first launch a chance to start raining immediately
	# instead of forcing the player to wait for the first period boundary.
	# Uses the same P(start) = base * curve formula, so dry-day-time-of-day
	# launches still usually start dry.
	_roll_rain_start_if_idle()
	# The boot roll runs during the title gate, when TimeManager is paused and
	# _process is suppressed. A rolled start leaves us in RAMPING_UP with
	# rain_current = 0, so the paused pre-title lake shot would show no rain even
	# though it "is" raining. Snap to the held target and push once here (this
	# path has no pause guard) so the gate shows steady rain iff the roll fired.
	# The title intro clears this back to dry at the camera snap
	# (see reset_weather_dry) so gameplay still begins without rain.
	_weather.snap_active_to_target()
	if _rain_layer != null:
		_push_rain_to_shader()


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

	# Blob fire leans downwind in two parts, both scaled by wind INTENSITY (not
	# rain amount, so flames lean on a dry windy day too) and pushed once to the
	# fire_blobs global uniforms (like shader_debug) rather than per-material — a
	# busy fire has ~160 duplicated blob materials:
	#   wind_lean  the STEADY mean, sharing RAIN's wind DIRECTION. rain_max_angle
	#              is the only signed wind signal in the profile (its sign IS the
	#              wind direction, per _push_rain_to_shader); fire takes just that
	#              sign and its own conservative magnitude.
	#   wind_gust  the amplitude of a zero-mean gust the shader rides on the same
	#              scrolling noise the grass sways on (unsigned — the shader noise
	#              carries the oscillation's sign).
	# mean + gust peak is MAX_WIND_LEAN, which the quad bound is sized for; the
	# shader does not clamp, so keeping the pushed magnitudes within these caps is
	# what stops a gust clipping a leaning blob at the quad edge.
	var wind_dir: float = signf(profile.rain_max_angle)
	RenderingServer.global_shader_parameter_set(&"wind_lean",
			FireBlobTuning.MAX_WIND_MEAN * wind_dir * _last_wind_val)
	RenderingServer.global_shader_parameter_set(&"wind_gust",
			FireBlobTuning.MAX_WIND_GUST * _last_wind_val)

	# --- Water ---
	if profile.water_intensity_curve and not water_materials.is_empty():
		var water_val: float = profile.water_intensity_curve.sample(t)
		for mat: ShaderMaterial in water_materials:
			mat.set_shader_parameter(&"water_intensity", water_val)

	# --- All shadows ---
	# `t` is identical for every shadow node, so sample the time-driven curves
	# once here rather than per node (otherwise N redundant Curve binary searches
	# each frame, scaling with how many plants/structures the player has built).
	# Per-node `scale` is applied to the length result inside the loop.
	var has_shadow_opacity: bool = profile.shadow_opacity_curve != null
	var has_shadow_length: bool = profile.shadow_length_curve != null
	var shadow_opacity_val: float = (
		profile.shadow_opacity_curve.sample(t) if has_shadow_opacity else 0.0)
	var shadow_length_base: float = (
		profile.shadow_length_curve.sample(t) if has_shadow_length else 0.0)
	# Skip the whole node loop while both samples sit on a flat curve segment
	# (opacity is exactly 0 for ~40% of the cycle) and no shadow joined or left
	# the tree. Epsilons: opacity multiplies an 8-bit alpha, so 0.001 is below
	# one quantum; length is written as roundf(base * scale), so a 0.1 base
	# delta can't move the rounded result at scale 1. Skips do NOT update
	# _last_*, so drift accumulates and eventually passes the gate — no
	# permanent staleness. Known bounded staleness: a growing frailejon's
	# shadow_scale meta change re-applies only on the next gate pass — during
	# flat-opacity night its shadow is hidden anyway, and day curves are sloped
	# so the gate passes every few frames.
	var shadows_changed: bool = (
		absf(shadow_opacity_val - _last_shadow_opacity) > 0.001
		or absf(shadow_length_base - _last_shadow_length) > 0.1
	)
	if not _shadows_dirty and not shadows_changed:
		return
	if _shadows_dirty:
		_shadows_dirty = false
		_shadow_nodes = get_tree().get_nodes_in_group(&"shadow")
	_last_shadow_opacity = shadow_opacity_val
	_last_shadow_length = shadow_length_base
	for node: Node in _shadow_nodes:
		var item := node as CanvasItem
		var mat := item.material as ShaderMaterial
		if mat == null:
			continue
		var scale: float = node.get_meta(&"shadow_scale", 1.0)
		if has_shadow_opacity:
			mat.set_shader_parameter(&"shadow_opacity", shadow_opacity_val)
			# A zero-opacity shadow blends to nothing — shadow_oval declares no
			# render_mode (so default blend_mix) and writes
			# shadow_color.a * shadow_opacity — so hiding the CanvasItem is
			# pixel-identical to shading a fully transparent quad, and skips the
			# fragment shader instead. The opacity curve sits at exactly 0 for
			# ~40% of the cycle (tileset_test_profile: 0 at t<=0.2 and t>=0.8).
			#
			# Guarded on has_shadow_opacity: with no curve driving it the
			# material keeps its authored opacity and must stay visible.
			#
			# The uniform writes above/below deliberately still run while hidden.
			# player.gd reads shadow_length back off this material to place its
			# cutoff; skipping the write would feed it a stale value on the frame
			# the shadow reappears, depending on node order.
			item.visible = shadow_opacity_val > 0.0
		if has_shadow_length:
			# Round to integer so the tail grows/shrinks in whole-pixel steps
			# instead of having taper-edge pixels toggle at close fractional
			# thresholds (which reads as sub-pixel motion).
			mat.set_shader_parameter(
				&"shadow_length", roundf(shadow_length_base * scale))


# -----------------------------------------------------------------------------
# Rain weather
# -----------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _rain_layer == null or profile == null:
		return
	# Weather pauses with the game clock. Visual ramp continues smoothly if
	# the user un-pauses mid-fade because the model's real clock only advances here.
	if _time_manager != null and _time_manager.paused:
		return

	# In-game time tick for cooldowns + max-event-duration. Mirrors how
	# TimeManager advances time_of_day. Skipping when seconds_per_game_day <= 0
	# matches TimeManager's own guard (frozen clock = frozen weather timers).
	# Advances even under the debug override, exactly as before the extraction.
	if _time_manager != null and _time_manager.seconds_per_game_day > 0.0:
		_weather.advance_game_time(delta * (
			_time_manager.time_scale / _time_manager.seconds_per_game_day))

	if _rain_override >= 0.0:
		_weather.current = _rain_override
	else:
		_weather.evolve_real(profile, delta)

	_push_rain_to_shader()


func _push_rain_to_shader() -> void:
	_rain_layer.set_amount(_weather.current)
	# Sign + magnitude both live in profile.rain_max_angle. Wind has no
	# direction in the data model — only intensity — so a single signed scalar
	# on the profile is sufficient.
	var angle: float = profile.rain_max_angle * _weather.current * _last_wind_val
	_rain_layer.set_streak_angle(angle)


func _on_period_changed(_new: StringName, _old: StringName) -> void:
	_roll_weather()


# Single-shot version of the period roll used at boot. Only rolls a START
# from IDLE; never tries to stop existing rain (the scene was just loaded).
func _roll_rain_start_if_idle() -> void:
	if _weather.state == WeatherModel.State.IDLE:
		_roll_weather()


func _roll_weather() -> void:
	if _rain_override >= 0.0:
		return
	_weather.roll(profile, _time_manager.time_of_day,
			rain_probability_scale, _rain_rng)


## Force a clean, dry weather state and push it to the shader immediately.
## Called by the title intro once the navy curtain is fully opaque, so gameplay
## is revealed without rain even when the boot roll showed rain over the
## pre-title lake shot. Normal rolls resume unthrottled from the next period
## boundary (game_t = INF mirrors the boot init, so no post-stop cooldown).
func reset_weather_dry() -> void:
	_weather.reset_dry()
	if _rain_layer != null:
		_push_rain_to_shader()


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
	return _weather.current


## Current ambient brightness — the HSV value of the CanvasModulate tint, in
## [0,1]. Roughly 0.9 in full daylight, ~0.2 at deep night. Other systems (e.g.
## fire light) scale against this to dim themselves when the scene is already
## bright. Returns 1.0 if no CanvasModulate is wired (treat as full daylight).
func get_ambient_value() -> float:
	if canvas_modulate:
		return canvas_modulate.color.v
	return 1.0
