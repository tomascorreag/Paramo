extends GutTest

# Guards WeatherModel — the rain state machine extracted from
# DayNightSceneController so the game and the headless balance simulator run
# the same code. The subtle rules pinned here are the ones the extraction must
# not lose: the two-clock split (ramps in real seconds, cooldowns in game
# days), state_game_t resetting on ENTERING ACTIVE/IDLE but never at ramp
# start, the INF boot value defeating the post-stop cooldown, and the climate
# scale multiplying the START roll only.
#
# RNG-dependent branches are tested at probability 1 and 0 (base/curve
# corners) — GDScript cannot shadow the native randf(), so certainty corners
# replace a scripted stub.

const _EPS: float = 0.0001


# A profile with a CONSTANT probability curve at `p`, plus tight, readable
# rain timings. Defaults everywhere else.
func _profile(p_curve: float, base: float = 1.0) -> DayNightProfile:
	var prof := DayNightProfile.new()
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, p_curve))
	curve.add_point(Vector2(1.0, p_curve))
	prof.rain_probability_curve = curve
	prof.rain_base_probability = base
	prof.rain_ramp_up_seconds = 2.0
	prof.rain_ramp_down_seconds = 4.0
	prof.rain_target_intensity_min = 0.5
	prof.rain_target_intensity_max = 0.5  # deterministic target
	prof.rain_noise_amplitude = 0.0       # hold exactly at target
	prof.rain_post_start_cooldown = 0.08
	prof.rain_post_stop_cooldown = 0.20
	prof.rain_max_event_duration = 0.5
	return prof


func _rng(s: int = 7) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = s
	return r


# --- boot + start roll --------------------------------------------------------

func test_boots_idle_dry_with_inf_game_clock() -> void:
	var m := WeatherModel.new()
	assert_eq(m.state, WeatherModel.State.IDLE)
	assert_eq(m.current, 0.0)
	assert_eq(m.state_game_t, INF, "INF boot defeats the post-stop cooldown")


func test_certain_start_roll_enters_ramp_up() -> void:
	var m := WeatherModel.new()
	m.roll(_profile(1.0), 0.5, 1.0, _rng())
	assert_eq(m.state, WeatherModel.State.RAMPING_UP)
	assert_almost_eq(m.target, 0.5, _EPS, "min == max pins the rolled target")
	assert_eq(m.current, 0.0, "intensity ramps from 0, not snaps")


func test_zero_scale_kills_a_certain_start() -> void:
	# The climate hook: scale multiplies the START probability.
	var m := WeatherModel.new()
	m.roll(_profile(1.0), 0.5, 0.0, _rng())
	assert_eq(m.state, WeatherModel.State.IDLE)


func test_post_stop_cooldown_blocks_the_start_roll() -> void:
	var m := WeatherModel.new()
	m.state_game_t = 0.1  # < rain_post_stop_cooldown 0.20
	m.roll(_profile(1.0), 0.5, 1.0, _rng())
	assert_eq(m.state, WeatherModel.State.IDLE, "dry buffer after a stop")
	m.state_game_t = 0.25
	m.roll(_profile(1.0), 0.5, 1.0, _rng())
	assert_eq(m.state, WeatherModel.State.RAMPING_UP)


func test_null_curve_never_rolls() -> void:
	var m := WeatherModel.new()
	var prof := _profile(1.0)
	prof.rain_probability_curve = null
	m.roll(prof, 0.5, 1.0, _rng())
	assert_eq(m.state, WeatherModel.State.IDLE)


# --- ramps and clock resets ---------------------------------------------------

func test_ramp_up_lerps_then_enters_active_and_resets_game_clock() -> void:
	var m := WeatherModel.new()
	var prof := _profile(1.0)
	m.roll(prof, 0.5, 1.0, _rng())
	assert_eq(m.state_game_t, INF, "ramp start must NOT reset the game clock")

	m.evolve(prof, 1.0, 0.01)  # half of rain_ramp_up_seconds = 2.0
	assert_almost_eq(m.current, 0.25, _EPS, "halfway up the 0 -> 0.5 ramp")
	assert_eq(m.state, WeatherModel.State.RAMPING_UP)

	m.evolve(prof, 1.0, 0.01)
	assert_eq(m.state, WeatherModel.State.ACTIVE)
	assert_almost_eq(m.current, 0.5, _EPS)
	assert_eq(m.state_game_t, 0.0, "game clock resets on ENTERING ACTIVE")
	assert_eq(m.state_t_real, 0.0)


func test_active_holds_target_with_zero_noise() -> void:
	var m := WeatherModel.new()
	var prof := _profile(1.0)
	m.roll(prof, 0.5, 1.0, _rng())
	m.evolve(prof, 2.0, 0.01)  # complete the ramp
	m.evolve(prof, 3.0, 0.01)
	assert_almost_eq(m.current, 0.5, _EPS)
	assert_eq(m.state, WeatherModel.State.ACTIVE)


func test_max_event_duration_forces_a_stop_without_a_roll() -> void:
	var m := WeatherModel.new()
	var prof := _profile(1.0)
	m.roll(prof, 0.5, 1.0, _rng())
	m.evolve(prof, 2.0, 0.0)          # -> ACTIVE, game clock 0
	m.evolve(prof, 0.1, 0.6)          # past rain_max_event_duration 0.5
	assert_eq(m.state, WeatherModel.State.RAMPING_DOWN,
			"unlucky stop rolls can't pin permanent rain")


func test_ramp_down_reaches_idle_and_clears_target() -> void:
	var m := WeatherModel.new()
	var prof := _profile(1.0)
	m.roll(prof, 0.5, 1.0, _rng())
	m.evolve(prof, 2.0, 0.0)          # ACTIVE at 0.5
	m.stop_event()
	m.evolve(prof, 2.0, 0.01)         # half of rain_ramp_down_seconds = 4.0
	assert_almost_eq(m.current, 0.25, _EPS)
	m.evolve(prof, 2.0, 0.01)
	assert_eq(m.state, WeatherModel.State.IDLE)
	assert_eq(m.current, 0.0)
	assert_eq(m.target, 0.0)
	assert_eq(m.state_game_t, 0.0, "game clock resets on ENTERING IDLE")


# --- stop roll ----------------------------------------------------------------

func test_certain_stop_roll_after_cooldown() -> void:
	# curve 0 -> stop probability = base * (1 - curve) = 1.
	var m := WeatherModel.new()
	var prof := _profile(0.0)
	m.start_event(prof, _rng())
	m.evolve(prof, 2.0, 0.0)          # ACTIVE, game clock 0
	m.roll(prof, 0.5, 1.0, _rng())
	assert_eq(m.state, WeatherModel.State.ACTIVE,
			"post-start cooldown protects a fresh storm")
	m.advance_game_time(0.1)          # past rain_post_start_cooldown 0.08
	m.roll(prof, 0.5, 1.0, _rng())
	assert_eq(m.state, WeatherModel.State.RAMPING_DOWN)


func test_rolls_never_interrupt_a_ramp() -> void:
	var m := WeatherModel.new()
	var prof := _profile(1.0)
	m.roll(prof, 0.5, 1.0, _rng())
	assert_eq(m.state, WeatherModel.State.RAMPING_UP)
	m.roll(_profile(0.0), 0.5, 1.0, _rng())
	assert_eq(m.state, WeatherModel.State.RAMPING_UP, "mid-fade rolls ignored")


# --- reset + boot snap --------------------------------------------------------

func test_reset_dry_restores_boot_semantics() -> void:
	var m := WeatherModel.new()
	var prof := _profile(1.0)
	m.roll(prof, 0.5, 1.0, _rng())
	m.evolve(prof, 2.0, 0.01)
	m.reset_dry()
	assert_eq(m.state, WeatherModel.State.IDLE)
	assert_eq(m.current, 0.0)
	assert_eq(m.state_game_t, INF, "no post-stop throttle after a hard reset")


func test_snap_active_to_target_only_from_ramp_up() -> void:
	var m := WeatherModel.new()
	m.snap_active_to_target()
	assert_eq(m.state, WeatherModel.State.IDLE, "no-op from IDLE")
	m.start_event(_profile(1.0), _rng())
	m.snap_active_to_target()
	assert_eq(m.state, WeatherModel.State.ACTIVE)
	assert_almost_eq(m.current, 0.5, _EPS)
	assert_eq(m.state_game_t, 0.0)


# --- determinism --------------------------------------------------------------

func test_same_seed_same_timeline() -> void:
	# Drive two models with identically-seeded rngs through a mixed schedule
	# of rolls and evolves at a mid probability; every published intensity
	# must match. This is the property the Monte Carlo simulator rests on.
	var prof := _profile(0.5, 0.5)
	var a := WeatherModel.new()
	var b := WeatherModel.new()
	var rng_a := _rng(1234)
	var rng_b := _rng(1234)
	for i in 200:
		if i % 10 == 0:
			a.roll(prof, fmod(i * 0.017, 1.0), 0.8, rng_a)
			b.roll(prof, fmod(i * 0.017, 1.0), 0.8, rng_b)
		a.evolve(prof, 0.25, 0.001)
		b.evolve(prof, 0.25, 0.001)
		assert_eq(a.current, b.current, "diverged at step %d" % i)
		assert_eq(a.state, b.state)
