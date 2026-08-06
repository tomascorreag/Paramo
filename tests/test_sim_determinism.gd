extends GutTest

# The balance simulator's foundational property: a run is a pure function of
# (run_seed, scenario). Runs the REAL stack — SimWorld terrain + paint, the
# Pathfinder, FireManager, weather model, economy — twice at the same seed
# through SimRunner (the same code path the CLI uses) and requires identical
# run rows. Uses the short_run scenario shape (4-day year, 1 day/season) so
# the full-run loop, season rollovers and planning pass-through are all
# exercised without the full 24-day cost.

var _world: SimWorld = null
var _runner: SimRunner = null

var _saved_phase: int
var _saved_season_index: int
var _saved_paused: bool
var _saved_day_count: int
var _saved_time_of_day: float
var _saved_cycle: Array[SeasonProfile]
var _saved_season_count: int


func before_each() -> void:
	_saved_phase = SeasonManager.phase
	_saved_season_index = SeasonManager.season_index
	_saved_paused = TimeManager.paused
	_saved_day_count = TimeManager.day_count
	_saved_time_of_day = TimeManager.time_of_day
	_saved_cycle = SeasonManager.season_cycle
	_saved_season_count = SeasonManager.season_count

	# Pin the season shape — earlier suite tests may leave the autoload with a
	# different cycle/count, and the 4-day expectation depends on 4 seasons of
	# (days_per_year 4) / (cycle size 4) = 1 day each.
	var dry: SeasonProfile = load("res://resources/seasons/dry.tres")
	var wet: SeasonProfile = load("res://resources/seasons/wet.tres")
	SeasonManager.season_cycle = [dry, wet, dry, wet] as Array[SeasonProfile]
	SeasonManager.season_count = 4

	_world = SimWorld.new()
	add_child_autofree(_world)
	_runner = SimRunner.new()
	_runner.world = _world
	add_child_autofree(_runner)


func after_each() -> void:
	# The runner leaves the autoloads at RUN_OVER; put everything back so the
	# rest of the suite sees the state it expects, and detach FireManager from
	# the about-to-be-freed sim world so its _process can't touch stale layers.
	FireManager._wipe_all_fires()
	FireManager._pathfinder = null
	FireManager._grid = null
	FireManager.spawn_vfx = true
	SeasonManager.phase = _saved_phase
	SeasonManager.season_index = _saved_season_index
	SeasonManager.season_cycle = _saved_cycle
	SeasonManager.season_count = _saved_season_count
	TimeManager.paused = _saved_paused
	TimeManager.day_count = _saved_day_count
	TimeManager.time_of_day = _saved_time_of_day
	ResourceLedger.reset()


func test_same_seed_same_scenario_identical_run_rows() -> void:
	var scenario: Dictionary = {
		"name": "determinism_fixture",
		"balance": {"SeasonManager": {"days_per_year": 4}},
	}
	var a: Dictionary = _runner.run_one(4242, scenario, true)
	var b: Dictionary = _runner.run_one(4242, scenario, true)

	assert_eq(a["run"], b["run"],
			"same (seed, scenario) must produce a byte-identical run row")
	assert_eq(a["days"], b["days"], "and identical per-day rows")
	assert_eq(int(a["run"]["days"]), 4, "the 4-day fixture ran to completion")


func test_different_seeds_diverge() -> void:
	# Not a strict requirement per-pair (two seeds can coincide by chance on a
	# single metric), so compare the whole row — collision odds across every
	# float column are negligible.
	var scenario: Dictionary = {
		"name": "determinism_fixture",
		"balance": {"SeasonManager": {"days_per_year": 4}},
	}
	var a: Dictionary = _runner.run_one(1, scenario, false)
	var b: Dictionary = _runner.run_one(2, scenario, false)
	assert_ne(a["run"], b["run"], "different seeds should produce different runs")
