extends GutTest

# Guards the water economy's generator: the rate model itself (pure static, no
# tree needed), the run-phase gating, and the source split the end-screen
# breakdown depends on.
#
# The rate math is tested through gain_for() rather than by running _process for
# a wall-clock interval — a frame-timing-dependent assertion would be flaky, and
# the conversion from real delta to game-day delta is one line that the phase
# tests already exercise.

const WATER: StringName = &"water"

var _cycle: WaterCycle


# Stands in for DayNightSceneController: the only thing WaterCycle asks it is
# how hard it is raining. Joins the group the real controller registers under.
class RainStub:
	extends Node

	var intensity: float = 0.0

	func _ready() -> void:
		add_to_group(&"day_night_controller")

	func get_rain_current_intensity() -> float:
		return intensity


var _rain: RainStub
var _phase_before: int
var _paused_before: bool


func before_each() -> void:
	_phase_before = SeasonManager.phase
	_paused_before = TimeManager.paused
	# Hold the real clock still so its own _process can't advance the season or
	# race the assertions.
	TimeManager.paused = true
	SeasonManager.phase = SeasonManager.Phase.ACTIVE
	ResourceLedger.reset()

	_rain = RainStub.new()
	add_child_autofree(_rain)
	_cycle = WaterCycle.new()
	add_child_autofree(_cycle)


func after_each() -> void:
	SeasonManager.phase = _phase_before
	TimeManager.paused = _paused_before
	ResourceLedger.reset()


# --- rate model (pure) ------------------------------------------------------

func test_gain_is_linear_in_elapsed_time() -> void:
	var one := WaterCycle.gain_for(1.0, 0.0, 4.0, 0.0)
	var half := WaterCycle.gain_for(0.5, 0.0, 4.0, 0.0)
	assert_eq(one, 4.0, "the base rate is per whole in-game day")
	assert_eq(half, 2.0)


func test_dry_weather_yields_the_base_rate_only() -> void:
	assert_eq(WaterCycle.gain_for(1.0, 0.0, 2.0, 30.0), 2.0)


func test_full_rain_adds_the_rain_rate() -> void:
	assert_eq(WaterCycle.gain_for(1.0, 1.0, 2.0, 30.0), 32.0)


func test_rain_scales_linearly_between() -> void:
	assert_eq(WaterCycle.gain_for(1.0, 0.5, 2.0, 30.0), 17.0)


func test_rain_intensity_is_clamped() -> void:
	# The shader uniform is documented 0..1, but the debug overlay's rain
	# override can be driven by hand — a stray 5.0 must not mint 5x the water.
	assert_eq(WaterCycle.gain_for(1.0, 5.0, 2.0, 30.0), 32.0, "above 1.0 clamps")
	assert_eq(WaterCycle.gain_for(1.0, -1.0, 2.0, 30.0), 2.0, "below 0.0 clamps")


# --- rain wiring ------------------------------------------------------------

func test_reads_live_rain_from_the_day_night_controller() -> void:
	_rain.intensity = 1.0
	assert_eq(_cycle.rain_intensity(), 1.0)
	_rain.intensity = 0.25
	assert_eq(_cycle.rain_intensity(), 0.25)


func test_rate_reflects_the_weather() -> void:
	_cycle.base_per_game_day = 2.0
	_cycle.rain_per_game_day_at_full = 30.0

	_rain.intensity = 0.0
	assert_eq(_cycle.rate_per_game_day(), 2.0)
	_rain.intensity = 1.0
	assert_eq(_cycle.rate_per_game_day(), 32.0,
		"rain must dominate the trickle, or the mechanic isn't legible")


# --- phase gating -----------------------------------------------------------

func test_no_accrual_outside_an_active_run() -> void:
	# The gameplay scene is also up behind the title screen (IDLE) and after the
	# run ends — neither may fill the reserve.
	for phase: int in [SeasonManager.Phase.IDLE, SeasonManager.Phase.RUN_OVER]:
		SeasonManager.phase = phase
		_cycle._process(1.0)
		_cycle.flush()
		assert_eq(ResourceLedger.get_amount(WATER), 0.0,
			"phase %d must not accrue" % phase)


func test_no_accrual_while_the_clock_is_paused() -> void:
	TimeManager.paused = true
	_cycle._process(1.0)
	_cycle.flush()
	assert_eq(ResourceLedger.get_amount(WATER), 0.0)


func test_accrues_while_active() -> void:
	TimeManager.paused = false
	_cycle._process(1.0)
	_cycle.flush()
	assert_gt(ResourceLedger.get_amount(WATER), 0.0)


# --- source split -----------------------------------------------------------

func test_fog_and_rain_are_banked_under_separate_sources() -> void:
	# source_breakdown() is what the loss-naming end screen reads; capturing the
	# split as it happens is the whole reason there are two accumulators.
	TimeManager.paused = false
	_rain.intensity = 1.0
	_cycle._process(1.0)
	_cycle.flush()

	var fog := ResourceLedger.source_total(WATER, WaterCycle.SOURCE_FOG)
	var rain := ResourceLedger.source_total(WATER, WaterCycle.SOURCE_RAIN)
	assert_gt(fog, 0.0, "fog capture runs in all weather")
	assert_gt(rain, 0.0, "rain must be attributed separately")
	assert_almost_eq(fog + rain, ResourceLedger.get_amount(WATER), 0.0001,
		"the two sources must account for the whole balance")


func test_no_rain_source_when_it_is_dry() -> void:
	TimeManager.paused = false
	_rain.intensity = 0.0
	_cycle._process(1.0)
	_cycle.flush()

	assert_eq(ResourceLedger.source_total(WATER, WaterCycle.SOURCE_RAIN), 0.0)
	assert_gt(ResourceLedger.source_total(WATER, WaterCycle.SOURCE_FOG), 0.0)


func test_flush_is_idempotent() -> void:
	# The commit beat calls flush() on a timer; a second call with nothing
	# accrued must not re-bank the same water.
	TimeManager.paused = false
	_cycle._process(1.0)
	_cycle.flush()
	var banked := ResourceLedger.get_amount(WATER)
	_cycle.flush()
	assert_eq(ResourceLedger.get_amount(WATER), banked)
