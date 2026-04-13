extends GutTest

# TimeManager has no class_name (autoload restriction). Load the script directly.
const TimeManagerScript: GDScript = preload("res://scripts/systems/time_manager.gd")

# Mirror period constants for readability.
const NIGHT: StringName = &"night"
const DAWN: StringName = &"dawn"
const MORNING: StringName = &"morning"
const NOON: StringName = &"noon"
const AFTERNOON: StringName = &"afternoon"
const DUSK: StringName = &"dusk"

var tm: Node


func before_each() -> void:
	tm = TimeManagerScript.new()
	# Don't call add_child yet — some tests want to set state before _ready.


func after_each() -> void:
	if tm.is_inside_tree():
		tm.queue_free()
	else:
		tm.free()


func _add_tm() -> void:
	add_child_autofree(tm)


# ===========================================================================
# _evaluate_period
# ===========================================================================

func test_evaluate_period_midnight() -> void:
	assert_eq(tm._evaluate_period(0.0), NIGHT)


func test_evaluate_period_pre_dawn() -> void:
	assert_eq(tm._evaluate_period(0.21), NIGHT)


func test_evaluate_period_boundary_0_22() -> void:
	# 0.22 is NOT < 0.22 -> skips NIGHT entry, matches DAWN (0.22 < 0.30).
	assert_eq(tm._evaluate_period(0.22), DAWN)


func test_evaluate_period_dawn() -> void:
	assert_eq(tm._evaluate_period(0.25), DAWN)


func test_evaluate_period_boundary_0_30() -> void:
	# 0.30 is NOT < 0.30 -> skips DAWN, matches MORNING (0.30 < 0.45).
	assert_eq(tm._evaluate_period(0.30), MORNING)


func test_evaluate_period_morning() -> void:
	assert_eq(tm._evaluate_period(0.35), MORNING)


func test_evaluate_period_noon() -> void:
	assert_eq(tm._evaluate_period(0.50), NOON)


func test_evaluate_period_afternoon() -> void:
	assert_eq(tm._evaluate_period(0.60), AFTERNOON)


func test_evaluate_period_dusk() -> void:
	assert_eq(tm._evaluate_period(0.75), DUSK)


func test_evaluate_period_late_night() -> void:
	assert_eq(tm._evaluate_period(0.90), NIGHT)


func test_evaluate_period_beyond_1() -> void:
	# Fallback: no entry matches -> NIGHT.
	assert_eq(tm._evaluate_period(1.5), NIGHT)


# ===========================================================================
# set_time
# ===========================================================================

func test_set_time_updates_time_of_day() -> void:
	_add_tm()
	tm.set_time(0.5)
	assert_eq(tm.time_of_day, 0.5)


func test_set_time_wraps() -> void:
	_add_tm()
	tm.set_time(1.75)
	assert_almost_eq(tm.time_of_day, 0.75, 0.001)


func test_set_time_emits_time_changed() -> void:
	_add_tm()
	watch_signals(tm)
	tm.set_time(0.5)
	assert_signal_emitted(tm, "time_changed")


func test_set_time_emits_period_changed_on_transition() -> void:
	tm.time_of_day = 0.25  # dawn
	_add_tm()  # _ready sets _current_period to DAWN
	watch_signals(tm)
	tm.set_time(0.50)  # noon
	assert_signal_emitted(tm, "period_changed")


func test_set_time_no_period_signal_if_same() -> void:
	tm.time_of_day = 0.25  # dawn
	_add_tm()
	watch_signals(tm)
	tm.set_time(0.26)  # still dawn
	assert_signal_not_emitted(tm, "period_changed")


# ===========================================================================
# _process (time advancement)
# ===========================================================================

func test_process_advances_time() -> void:
	tm.time_of_day = 0.0
	tm.seconds_per_game_day = 100.0
	tm.time_scale = 1.0
	tm.paused = false
	_add_tm()
	tm._process(10.0)
	assert_almost_eq(tm.time_of_day, 0.1, 0.001)


func test_process_respects_time_scale() -> void:
	tm.time_of_day = 0.0
	tm.seconds_per_game_day = 100.0
	tm.time_scale = 2.0
	tm.paused = false
	_add_tm()
	tm._process(10.0)
	assert_almost_eq(tm.time_of_day, 0.2, 0.001)


func test_process_paused_no_advance() -> void:
	tm.time_of_day = 0.0
	tm.paused = true
	_add_tm()
	tm._process(10.0)
	assert_eq(tm.time_of_day, 0.0)


func test_process_day_rollover() -> void:
	tm.time_of_day = 0.95
	tm.seconds_per_game_day = 100.0
	tm.time_scale = 1.0
	tm.paused = false
	_add_tm()
	watch_signals(tm)
	tm._process(10.0)  # adds 0.1 -> 1.05 -> wraps to 0.05
	assert_almost_eq(tm.time_of_day, 0.05, 0.001)
	assert_eq(tm.day_count, 1)
	assert_signal_emitted(tm, "day_completed")


func test_process_zero_seconds_per_day_no_advance() -> void:
	tm.time_of_day = 0.5
	tm.seconds_per_game_day = 0.0
	_add_tm()
	tm._process(1.0)
	assert_eq(tm.time_of_day, 0.5)


func test_get_period_after_ready() -> void:
	tm.time_of_day = 0.50
	_add_tm()
	assert_eq(tm.get_period(), NOON)
