extends GutTest

# DayLog answers "what did the mountain GIVE me on day N", which the journal's
# calendar prints beside each day's stamp. Three things make it easy to get wrong,
# and each has a test here:
#
#   * OBTAINED, not net. A day you spent 20 water dousing still gave you the 6 the
#     fog nets caught. Summing signed deltas would print a negative yield on
#     exactly the days the player was most active.
#   * The DAY BOUNDARY. VisitorFlow banks the day's token lump from inside
#     TimeManager's day_completed emission. If DayLog closed its bucket on that
#     same signal it would race the connection order and drop that income into the
#     following day — so it closes on time_changed, which TimeManager emits
#     immediately AFTER every day_completed handler has run.
#   * VISITORS are not a ledger resource. They are a source tag that mints tokens,
#     so the count only exists on VisitorFlow's own signal.

const WATER: StringName = &"water"
const TOKENS: StringName = &"tokens"
const VISITORS: StringName = &"visitors"


func before_each() -> void:
	ResourceLedger.reset()
	TimeManager.reset_clock()
	# season_started(0) is DayLog's own reset edge, the same one UnlockState clears
	# its purchases on.
	SeasonManager.season_started.emit(0, null)


func after_each() -> void:
	ResourceLedger.reset()
	TimeManager.reset_clock()
	SeasonManager.season_started.emit(0, null)


# Rolls the clock forward one whole day the way a frame does, so day_completed and
# time_changed both fire in their real order.
func _end_day() -> void:
	TimeManager.advance(TimeManager.seconds_per_game_day / TimeManager.time_scale)


func test_records_what_was_obtained_not_the_net() -> void:
	ResourceLedger.add(WATER, 6.0, &"rainfall")
	ResourceLedger.try_spend(WATER, 4.0, &"extinguish_fire")
	_end_day()
	assert_eq(DayLog.day(0).get(WATER), 6,
		"a day that also SPENT water still yielded what it caught")


func test_a_days_yield_closes_at_the_day_boundary() -> void:
	ResourceLedger.add(WATER, 3.0, &"rainfall")
	_end_day()
	ResourceLedger.add(WATER, 5.0, &"rainfall")
	_end_day()
	assert_eq(DayLog.day(0).get(WATER), 3, "day 0 keeps its own yield")
	assert_eq(DayLog.day(1).get(WATER), 5, "day 1 must not inherit day 0's")


func test_income_banked_during_day_completed_lands_on_that_day() -> void:
	# The ordering trap. Anything added by a day_completed handler belongs to the
	# day that just ENDED, not the one starting.
	var banked := func(_d: int) -> void:
		ResourceLedger.add(TOKENS, 4.0, &"visitors")
	TimeManager.day_completed.connect(banked)
	_end_day()
	TimeManager.day_completed.disconnect(banked)
	assert_eq(DayLog.day(0).get(TOKENS), 4,
		"end-of-day income must close INTO the day it was earned")


func test_visitors_come_from_the_flow_not_the_ledger() -> void:
	var flow := VisitorFlow.new()
	add_child_autofree(flow)
	flow.visitors_arrived.emit(3)
	_end_day()
	assert_eq(DayLog.day(0).get(VISITORS), 3)


func test_a_day_not_yet_lived_reads_as_zeros() -> void:
	var d := DayLog.day(99)
	assert_eq(d.get(WATER), 0)
	assert_eq(d.get(TOKENS), 0)
	assert_eq(d.get(VISITORS), 0)


func test_fractional_yield_floors() -> void:
	# Same reason the supplies row floors: the page's numbers have to mean whole
	# usable units, never a rounded-up promise.
	ResourceLedger.add(WATER, 2.9, &"fog_capture")
	_end_day()
	assert_eq(DayLog.day(0).get(WATER), 2)


func test_a_fresh_run_clears_the_log() -> void:
	ResourceLedger.add(WATER, 5.0, &"rainfall")
	_end_day()
	assert_eq(DayLog.day_count(), 1)
	SeasonManager.season_started.emit(0, null)
	assert_eq(DayLog.day_count(), 0, "season 0 starts a new run with an empty log")
