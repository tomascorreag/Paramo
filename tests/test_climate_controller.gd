extends GutTest

# Guards the dryness integrator (pure static), the gentle climate ramp, and the
# two consumer hooks: the rain-start scale pushed into the day-night controller
# and the ignition multiplier FireManager reads.
#
# The integrator is tested through dryness_step() with hand-picked deltas, not
# by running _process over wall-clock time — same reasoning as test_water_cycle.

var _climate: ClimateController

const DRY_PROFILE: SeasonProfile = preload("res://resources/seasons/dry.tres")


# Stands in for DayNightSceneController: reports rain, records the climate
# scale pushes. Joins the group the real controller registers under.
class DayNightStub:
	extends Node

	var intensity: float = 0.0
	var received_scale: float = -1.0

	func _ready() -> void:
		add_to_group(&"day_night_controller")

	func get_rain_current_intensity() -> float:
		return intensity

	func set_rain_probability_scale(scale: float) -> void:
		received_scale = scale


var _day_night: DayNightStub
var _phase_before: int
var _paused_before: bool
var _season_index_before: int


func before_each() -> void:
	_phase_before = SeasonManager.phase
	_paused_before = TimeManager.paused
	_season_index_before = SeasonManager.season_index
	TimeManager.paused = true
	SeasonManager.phase = SeasonManager.Phase.ACTIVE
	SeasonManager.season_index = 0

	_day_night = DayNightStub.new()
	add_child_autofree(_day_night)
	_climate = ClimateController.new()
	add_child_autofree(_climate)
	FireManager._climate = null


func after_each() -> void:
	SeasonManager.phase = _phase_before
	SeasonManager.season_index = _season_index_before
	TimeManager.paused = _paused_before
	FireManager._climate = null


# --- dryness integrator (pure) ----------------------------------------------

func test_clear_sky_pulls_toward_the_equilibrium() -> void:
	var d := ClimateController.dryness_step(0.2, 0.75, 0.0, 0.5, 0.35, 1.2)
	assert_gt(d, 0.2, "no rain, below equilibrium: dryness must rise")
	assert_lt(d, 0.75, "one step must not overshoot the equilibrium")


func test_clear_sky_falls_toward_a_lower_equilibrium() -> void:
	# Entering the wet season with drought-level dryness: even without rain the
	# scalar must relax DOWN toward the wetter season's equilibrium.
	var d := ClimateController.dryness_step(0.9, 0.3, 0.0, 0.5, 0.35, 1.2)
	assert_lt(d, 0.9)
	assert_gt(d, 0.3)


func test_rain_pushes_dryness_down() -> void:
	var d := ClimateController.dryness_step(0.75, 0.75, 1.0, 0.5, 0.35, 1.2)
	assert_lt(d, 0.75, "a storm must re-soak the mountain")


func test_one_full_rain_day_undoes_days_of_drying() -> void:
	# wet_rate 1.2/day at full rain wipes out the whole scale in under a day —
	# the asymmetry (soaking fast, drying slow) is the tuning intent.
	var d := ClimateController.dryness_step(1.0, 1.0, 1.0, 1.0, 0.35, 1.2)
	assert_eq(d, 0.0, "clamped at 0, not negative")


func test_dryness_is_clamped_to_unit_range() -> void:
	assert_between(ClimateController.dryness_step(1.0, 1.0, 0.0, 100.0, 0.35, 1.2),
			0.0, 1.0)
	assert_between(ClimateController.dryness_step(0.0, 0.0, 5.0, 100.0, 0.35, 1.2),
			0.0, 1.0)


# --- climate ramp (pure) -----------------------------------------------------

func test_season_zero_uses_the_authored_rain_probability() -> void:
	assert_eq(ClimateController.rain_scale_for(0, 0.05), 1.0)


func test_rain_scale_decays_gently_per_season() -> void:
	var s1 := ClimateController.rain_scale_for(1, 0.05)
	var s3 := ClimateController.rain_scale_for(3, 0.05)
	assert_almost_eq(s1, 0.95, 0.0001)
	assert_almost_eq(s3, 0.857375, 0.0001)
	assert_lt(s3, s1, "later seasons must be drier")


func test_negative_season_index_does_not_inflate_rain() -> void:
	assert_eq(ClimateController.rain_scale_for(-2, 0.05), 1.0)


# --- season application ------------------------------------------------------

func test_season_start_pushes_the_rain_scale_to_the_weather_machine() -> void:
	_climate._apply_season(2, DRY_PROFILE)
	assert_almost_eq(_day_night.received_scale, 0.95 * 0.95, 0.0001)


func test_equilibrium_drifts_up_with_the_seasons() -> void:
	_climate._apply_season(0, DRY_PROFILE)
	var eq0: float = _climate._equilibrium
	_climate._apply_season(2, DRY_PROFILE)
	assert_almost_eq(eq0, 0.75, 0.0001, "season 0 is the authored equilibrium")
	assert_almost_eq(_climate._equilibrium, 0.85, 0.0001,
			"+0.05 drift per season elapsed")


# --- fire coupling -----------------------------------------------------------

func test_ignition_multiplier_tracks_dryness() -> void:
	_climate.dryness = 0.0
	assert_eq(_climate.get_ignition_multiplier(), _climate.ignition_mult_at_zero)
	_climate.dryness = 1.0
	assert_eq(_climate.get_ignition_multiplier(), _climate.ignition_mult_at_one)


func test_fire_manager_reads_the_climate_node() -> void:
	_climate.dryness = 1.0
	assert_eq(FireManager._climate_ignition_multiplier(),
			_climate.ignition_mult_at_one)


func test_fire_manager_falls_back_to_one_without_a_climate_node() -> void:
	# Bare test scenes and tools have no ClimateController; fire must behave
	# exactly as before the climate pass.
	_climate.remove_from_group(&"climate")
	FireManager._climate = null
	assert_eq(FireManager._climate_ignition_multiplier(), 1.0)


# --- accrual gating ----------------------------------------------------------

func test_process_holds_dryness_while_paused() -> void:
	# TimeManager.paused is true from before_each.
	_climate.dryness = 0.4
	_climate._process(1.0)
	assert_eq(_climate.dryness, 0.4)


func test_process_moves_dryness_while_active() -> void:
	TimeManager.paused = false
	_climate._apply_season(SeasonManager.season_index, DRY_PROFILE)
	_climate.dryness = 0.4
	_climate._process(1.0)
	assert_gt(_climate.dryness, 0.4,
			"clear-sky ACTIVE time must dry the mountain toward 0.75")
