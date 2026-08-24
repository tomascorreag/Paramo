extends GutTest

# SeasonManager is wired to the TimeManager / ResourceLedger autoloads, so we
# drive the real autoload singleton rather than a fresh instance (a fresh one
# would double-connect to TimeManager.day_completed). before_each force-resets
# it to IDLE and configures a short run for determinism.

const SEASONS: int = 3
const DAYS: int = 2


func before_each() -> void:
	SeasonManager.phase = SeasonManager.Phase.IDLE
	# Force a known 2-season cycle: days_per_season is derived as
	# days_per_year / cycle.size(), and the year boundary lands every cycle.size()
	# seasons. With size 2 + days_per_year = DAYS*2, days_per_season == DAYS and a
	# year turns every 2 seasons (what test_year_changes_after_full_cycle asserts).
	SeasonManager.season_cycle = [
		load("res://resources/seasons/dry.tres"),
		load("res://resources/seasons/wet.tres"),
	]
	SeasonManager.days_per_year = DAYS * SeasonManager.season_cycle.size()
	SeasonManager.season_count = SEASONS
	SeasonManager.starting_water = 0.0  # opt out of the water seed unless a test sets it


func after_each() -> void:
	# Leave the singleton stopped so a stray real-clock day can't fire handlers.
	SeasonManager.phase = SeasonManager.Phase.IDLE
	TimeManager.paused = true


func _start() -> void:
	SeasonManager.start_run()
	TimeManager.paused = true  # drive days manually; freeze the real clock


func _advance_one_day() -> void:
	TimeManager.day_count += 1
	TimeManager.day_completed.emit(TimeManager.day_count)


func _advance_days(n: int) -> void:
	for i: int in range(n):
		_advance_one_day()


# --- start_run --------------------------------------------------------------

func test_start_run_enters_active_season_zero() -> void:
	_start()
	assert_eq(SeasonManager.phase, SeasonManager.Phase.ACTIVE)
	assert_eq(SeasonManager.season_index, 0)
	assert_eq(SeasonManager.year, 1)


func test_start_run_emits_season_started() -> void:
	SeasonManager.phase = SeasonManager.Phase.IDLE
	watch_signals(SeasonManager)
	_start()
	assert_signal_emitted(SeasonManager, "season_started")


func test_start_run_resets_ledger() -> void:
	ResourceLedger.set_amount(&"water", 99.0)
	_start()
	assert_eq(ResourceLedger.get_amount(&"water"), 0.0)


func test_start_run_seeds_starting_water() -> void:
	SeasonManager.starting_water = 50.0
	_start()
	assert_eq(ResourceLedger.get_amount(&"water"), 50.0)


# --- season boundary --------------------------------------------------------

func test_season_does_not_end_before_n_days() -> void:
	_start()
	watch_signals(SeasonManager)
	_advance_days(DAYS - 1)
	assert_eq(SeasonManager.phase, SeasonManager.Phase.ACTIVE)
	assert_signal_not_emitted(SeasonManager, "season_ended")


func test_season_ends_after_n_days_and_rolls_straight_on() -> void:
	_start()
	watch_signals(SeasonManager)
	_advance_days(DAYS)
	assert_signal_emitted(SeasonManager, "season_ended")
	assert_signal_emitted(SeasonManager, "season_started")
	assert_eq(SeasonManager.season_index, 1)
	assert_eq(SeasonManager.phase, SeasonManager.Phase.ACTIVE)


## The regression the planning phase caused: the boundary parked the run with
## the clock paused, waiting on a call nothing in the game ever made.
func test_season_boundary_does_not_pause_clock() -> void:
	_start()
	TimeManager.paused = false
	_advance_days(DAYS)
	assert_false(TimeManager.paused)


func test_year_changes_after_full_cycle() -> void:
	# Cycle length 2: reaching season_index 2 starts year 2.
	_start()
	_advance_days(DAYS)  # -> season 1, still year 1
	assert_eq(SeasonManager.year, 1)
	watch_signals(SeasonManager)
	_advance_days(DAYS)  # -> season 2, year 2
	assert_eq(SeasonManager.year, 2)
	assert_signal_emitted(SeasonManager, "year_changed")


# --- run completion ---------------------------------------------------------

func test_run_completes_after_final_season() -> void:
	_start()  # season 0
	watch_signals(SeasonManager)
	# Seasons 0 and 1 roll straight on; season 2 ending completes the run.
	_advance_days(DAYS * SEASONS)
	assert_signal_emitted_with_parameters(SeasonManager, "run_completed", [&"survived"])
	assert_eq(SeasonManager.phase, SeasonManager.Phase.RUN_OVER)


func test_final_season_does_not_start_another() -> void:
	_start()
	_advance_days(DAYS * (SEASONS - 1))  # into the final season
	assert_eq(SeasonManager.season_index, SEASONS - 1)
	watch_signals(SeasonManager)
	_advance_days(DAYS)
	assert_signal_not_emitted(SeasonManager, "season_started")
	assert_eq(SeasonManager.season_index, SEASONS - 1)


func test_end_run_idempotent() -> void:
	_start()
	watch_signals(SeasonManager)
	SeasonManager.end_run(&"laguna_dead")
	SeasonManager.end_run(&"laguna_dead")
	assert_signal_emit_count(SeasonManager, "run_completed", 1)


func test_seasons_remaining_counts_down() -> void:
	_start()
	assert_eq(SeasonManager.seasons_remaining(), SEASONS)
	_advance_days(DAYS)
	assert_eq(SeasonManager.seasons_remaining(), SEASONS - 1)
