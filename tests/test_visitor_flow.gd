extends GutTest

# Guards the tourism economy: the daily visitor model (pure static), the
# one-lump-per-day banking discipline, and the appeal/rain wiring.
#
# day_completed is driven by calling the handler directly — emitting the real
# TimeManager signal would also advance SeasonManager mid-test.

const TOKENS: StringName = &"tokens"

var _flow: VisitorFlow


class RainStub:
	extends Node

	var intensity: float = 0.0

	func _ready() -> void:
		add_to_group(&"day_night_controller")

	func get_rain_current_intensity() -> float:
		return intensity


class AppealStub:
	extends Node

	var appeal: float = 1.0

	func _ready() -> void:
		add_to_group(&"regrowth")

	func get_appeal_factor() -> float:
		return appeal


var _rain: RainStub
var _appeal: AppealStub
var _phase_before: int
var _paused_before: bool


func before_each() -> void:
	_phase_before = SeasonManager.phase
	_paused_before = TimeManager.paused
	TimeManager.paused = true
	SeasonManager.phase = SeasonManager.Phase.ACTIVE
	ResourceLedger.reset()

	_rain = RainStub.new()
	add_child_autofree(_rain)
	_appeal = AppealStub.new()
	add_child_autofree(_appeal)
	_flow = VisitorFlow.new()
	add_child_autofree(_flow)


func after_each() -> void:
	SeasonManager.phase = _phase_before
	TimeManager.paused = _paused_before
	ResourceLedger.reset()


# --- daily model (pure) -------------------------------------------------------

func test_a_perfect_day_brings_the_base_count() -> void:
	assert_eq(VisitorFlow.visitors_for(0.0, 1.0, 4), 4)


func test_full_rain_brings_nobody() -> void:
	assert_eq(VisitorFlow.visitors_for(1.0, 1.0, 4), 0)


func test_char_scares_visitors_off() -> void:
	assert_eq(VisitorFlow.visitors_for(0.0, 0.5, 4), 2)
	assert_eq(VisitorFlow.visitors_for(0.0, 0.0, 4), 0)


func test_counts_are_whole_visitors() -> void:
	# 4 * 0.7 * 1.0 = 2.8 -> 3. Half-visitors don't pay half-tokens.
	assert_eq(VisitorFlow.visitors_for(0.3, 1.0, 4), 3)


func test_out_of_range_inputs_clamp() -> void:
	assert_eq(VisitorFlow.visitors_for(-2.0, 5.0, 4), 4,
			"negative rain / inflated appeal must not mint extra visitors")


# --- banking ------------------------------------------------------------------

func test_a_completed_day_banks_one_lump() -> void:
	_rain.intensity = 0.0
	_appeal.appeal = 1.0
	_flow._on_day_completed(1)
	var perfect_day: float = _flow.base_visitors_per_day * _flow.tokens_per_visitor
	assert_eq(ResourceLedger.get_amount(TOKENS), perfect_day,
			"%d visitors x %d tokens, in ONE deposit" \
					% [_flow.base_visitors_per_day, _flow.tokens_per_visitor])
	assert_eq(ResourceLedger.source_total(TOKENS, VisitorFlow.SOURCE), perfect_day)


func test_a_rained_out_day_banks_nothing() -> void:
	_rain.intensity = 1.0
	_flow._on_day_completed(1)
	assert_eq(ResourceLedger.get_amount(TOKENS), 0.0)


func test_no_income_outside_an_active_run() -> void:
	for phase: int in [SeasonManager.Phase.IDLE, SeasonManager.Phase.RUN_OVER]:
		SeasonManager.phase = phase
		_flow._on_day_completed(1)
		assert_eq(ResourceLedger.get_amount(TOKENS), 0.0,
				"phase %d must not pay" % phase)


func test_m_key_burst_banks_once_per_emission_without_error() -> void:
	# The debug fast-forward emits day_completed synchronously in a loop; the
	# rain integral is empty every time and the instantaneous fallback carries.
	_rain.intensity = 0.0
	for i in 6:
		_flow._on_day_completed(i)
	# Derived from the exports, not hardcoded: this test is about the BURST
	# banking once per emission, so a retune of the daily count must not fail it.
	var per_day: float = _flow.base_visitors_per_day * _flow.tokens_per_visitor
	assert_eq(ResourceLedger.get_amount(TOKENS), 6.0 * per_day,
			"6 perfect days x %d tokens" % per_day)


func test_day_average_rain_comes_from_the_process_integral() -> void:
	TimeManager.paused = false
	var half_day: float = TimeManager.seconds_per_game_day * 0.5 \
			/ maxf(TimeManager.time_scale, 0.001)
	_rain.intensity = 1.0
	_flow._process(half_day)
	_rain.intensity = 0.0
	_flow._process(half_day)

	# avg 0.5 -> HALF the base count even though it is bone dry RIGHT NOW.
	_flow._on_day_completed(1)
	var half_day_pay: float = VisitorFlow.visitors_for(
			0.5, 1.0, _flow.base_visitors_per_day) * _flow.tokens_per_visitor
	assert_eq(ResourceLedger.get_amount(TOKENS), half_day_pay,
			"the morning's storm must count against the evening's payout")


func test_appeal_falls_back_to_pristine_without_a_regrowth_node() -> void:
	_appeal.remove_from_group(&"regrowth")
	_flow._regrowth = null
	assert_eq(_flow.appeal(), 1.0)
