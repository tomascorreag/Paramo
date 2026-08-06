class_name WeatherModel
extends RefCounted

## The rain weather state machine, extracted from DayNightSceneController so
## the SAME logic drives both the game (via that controller, which keeps the
## scene work: shader pushes, RainLayer lookup, debug override) and the
## headless balance simulator. Pure state + math: no scene tree, no autoloads,
## no global RNG — `roll` draws only from the injected RandomNumberGenerator.
##
## Two clocks, deliberately:
##  - `state_t_real` REAL seconds in the current state — drives the ramp
##    lerps and the intensity-noise phase (visual speeds don't scale with
##    time_scale).
##  - `state_game_t` IN-GAME days in the current state — drives the post-
##    start/post-stop cooldowns and the max-event-duration force stop (they
##    pause with the clock and scale with seconds_per_game_day).
## `state_game_t` resets on ENTERING ACTIVE and IDLE, never at ramp start,
## and boots at INF so the first start roll isn't blocked by the post-stop
## cooldown. Fast-forward compresses cooldowns but not ramps — the simulator
## must feed both deltas separately or its weather statistics won't match the
## game's.

enum State { IDLE, RAMPING_UP, ACTIVE, RAMPING_DOWN }

var state: int = State.IDLE
## Real-time seconds spent in the current state (ramp progress + noise phase).
var state_t_real: float = 0.0
## In-game days spent in the current state (cooldowns + max duration).
var state_game_t: float = INF
## Target the most recent rain event ramped UP to (the "held" intensity).
var target: float = 0.0
## What `current` was at the moment a ramp began.
var ramp_from: float = 0.0
## Smoothed, noise-modulated intensity — the single published value.
var current: float = 0.0


## Advance the in-game clock. Split from evolve() because the game advances
## this even while the debug rain override suspends the state machine.
func advance_game_time(game_day_delta: float) -> void:
	state_game_t += game_day_delta


## One deterministic step: both clocks + the state machine. Zero RNG.
func evolve(profile: DayNightProfile, delta_real: float,
		game_day_delta: float) -> void:
	advance_game_time(game_day_delta)
	evolve_real(profile, delta_real)


## The real-seconds half of a step (ramps, hold noise, forced stop). The game
## calls this directly when it has already advanced the game clock.
func evolve_real(profile: DayNightProfile, delta_real: float) -> void:
	state_t_real += delta_real
	match state:
		State.IDLE:
			current = 0.0
		State.RAMPING_UP:
			var dur: float = maxf(0.01, profile.rain_ramp_up_seconds)
			var a: float = clampf(state_t_real / dur, 0.0, 1.0)
			current = lerpf(ramp_from, target, a)
			if a >= 1.0:
				state = State.ACTIVE
				state_t_real = 0.0
				state_game_t = 0.0
		State.ACTIVE:
			# Hold near target with low-amplitude flutter so the visual doesn't
			# read as frozen at a fixed value.
			current = clampf(
					target + intensity_noise(profile, state_t_real), 0.0, 1.0)
			# Force a stop if the storm has run past its max in-game duration.
			# Bypasses the random stop roll so a streak of unlucky rolls can't
			# pin the player in permanent rain.
			if profile.rain_max_event_duration > 0.0 \
					and state_game_t >= profile.rain_max_event_duration:
				stop_event()
		State.RAMPING_DOWN:
			var dur: float = maxf(0.01, profile.rain_ramp_down_seconds)
			var a: float = clampf(state_t_real / dur, 0.0, 1.0)
			current = lerpf(ramp_from, 0.0, a)
			if a >= 1.0:
				state = State.IDLE
				state_t_real = 0.0
				state_game_t = 0.0
				target = 0.0


## The period-boundary probability roll — the ONLY RNG consumer in the model.
## Rolls only matter at the two stable states; ramps are never interrupted.
func roll(profile: DayNightProfile, time_of_day: float,
		rain_probability_scale: float, rng: RandomNumberGenerator) -> void:
	if profile == null or profile.rain_probability_curve == null:
		return
	if state != State.IDLE and state != State.ACTIVE:
		return

	var p_curve: float = clampf(
			profile.rain_probability_curve.sample(time_of_day), 0.0, 1.0)
	var base: float = clampf(profile.rain_base_probability, 0.0, 1.0)

	if state == State.IDLE:
		# Post-stop cooldown: a stop that just happened needs a dry buffer
		# before the next start roll, otherwise the curve makes rain restart
		# on the very next period boundary.
		if state_game_t < profile.rain_post_stop_cooldown:
			return
		# The climate scale multiplies the START roll only: it must make rain
		# rarer, and the stop roll uses base * (1 - curve), so scaling `base`
		# itself would also make storms harder to STOP — the opposite effect.
		if rng.randf() < base * p_curve * rain_probability_scale:
			start_event(profile, rng)
	else: # ACTIVE
		# Post-start cooldown: a fresh storm gets at least this much in-game
		# time before it's eligible to stop, so a brief unlucky roll doesn't
		# kill an event seconds after the visuals ramped up.
		if state_game_t < profile.rain_post_start_cooldown:
			return
		if rng.randf() < base * (1.0 - p_curve):
			stop_event()


func start_event(profile: DayNightProfile, rng: RandomNumberGenerator) -> void:
	var lo: float = clampf(profile.rain_target_intensity_min, 0.0, 1.0)
	var hi: float = maxf(lo, clampf(profile.rain_target_intensity_max, 0.0, 1.0))
	ramp_from = current
	target = rng.randf_range(lo, hi)
	state = State.RAMPING_UP
	state_t_real = 0.0
	# state_game_t deliberately NOT reset here — it resets on entering ACTIVE.


func stop_event() -> void:
	ramp_from = current
	state = State.RAMPING_DOWN
	state_t_real = 0.0


## Force a clean, dry state. game_t = INF mirrors the boot init, so the next
## start roll isn't throttled by the post-stop cooldown.
func reset_dry() -> void:
	state = State.IDLE
	state_t_real = 0.0
	state_game_t = INF
	target = 0.0
	ramp_from = 0.0
	current = 0.0


## Boot snap: a start rolled while the clock is paused leaves RAMPING_UP at
## current = 0; snap to the held target so a paused first frame shows steady
## rain iff the roll fired. No-op unless mid-ramp-up.
func snap_active_to_target() -> void:
	if state != State.RAMPING_UP:
		return
	current = target
	state = State.ACTIVE
	state_t_real = 0.0
	state_game_t = 0.0


## Layered sin waves (irrational frequency ratio = non-repeating pattern).
## Cheaper than a noise allocation and visually indistinguishable at this
## amplitude. Deterministic — no RNG.
static func intensity_noise(profile: DayNightProfile, t: float) -> float:
	if profile.rain_noise_amplitude <= 0.0:
		return 0.0
	var f: float = profile.rain_noise_frequency
	var s: float = sin(t * TAU * f) * 0.6 + sin(t * TAU * f * 1.71 + 1.3) * 0.4
	return s * profile.rain_noise_amplitude
