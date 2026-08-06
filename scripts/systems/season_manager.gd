extends Node
## Autoload registered as "SeasonManager" in project.godot.
## Cannot use class_name — Godot disallows class_name matching an autoload name.

## The run's spine. Owns the season clock, year counter, and run phase. Every
## downstream system (threats, climate, laguna drain, funding events) hangs off
## these signals, so this is built and de-risked first.
##
## Clock model (decided 2026-06-22): the year is `days_per_year` full day/night
## cycles, split evenly across the seasons of the bimodal páramo calendar
## (`season_cycle`), so a season spans `days_per_year / season_cycle.size()`
## days. SeasonManager does NOT run its own timer — it counts
## TimeManager.day_completed and rolls the season when that quota is reached. The
## existing day/night atmosphere becomes the season's texture for free.
##
## Calendar (decided 2026-06-22): Colombian Andes rainfall is bimodal (Urrea et
## al. 2019, Water Resources Research) — two dry windows (~Dec-Feb, ~Jun-Aug) and
## two wet (~Mar-May, ~Sep-Nov), each ~a quarter of the year. The default cycle
## is therefore Dry-Wet-Dry-Wet (4 equal seasons per year).
##
## Lifecycle: IDLE until start_run() (the autoload is alive on the title screen
## too and must not tick there). Run begins ACTIVE in season 0. Planning sits
## BETWEEN seasons: season_ended -> PLANNING (clock paused) -> begin_next_season()
## -> next season_started. The final season ending completes the run.
##
## NOTE (spine scope): planning currently pauses only TimeManager (halts the day
## clock). Full get_tree().paused + walk-to-station gating arrives with the
## PlanningPhaseScreen in a later step; method/signal calls work regardless.

signal season_started(index: int, profile: SeasonProfile)
signal season_ended(index: int, profile: SeasonProfile)
signal planning_phase_entered(next_index: int)
signal planning_phase_exited(index: int)
signal year_changed(year: int)
## reason: &"survived" | &"laguna_dead" | &"funding_zero" | ...
signal run_completed(reason: StringName)

enum Phase { IDLE, ACTIVE, PLANNING, RUN_OVER }

# --- Configuration (tunable; migrate to a RunConfig .tres in the balance pass) ---

## Length of a full year in day/night cycles. The bimodal calendar splits this
## evenly across `season_cycle`, so each season runs `days_per_year /
## season_cycle.size()` days. N=24 -> 6 days per season for the default 4-season
## (Dry-Wet-Dry-Wet) year. Run length = days_per_season * seconds_per_game_day *
## season_count.
@export var days_per_year: int = 24

## Day/night cycles per season — derived from days_per_year and the number of
## seasons in a year (= season_cycle length). Read-only; set days_per_year to
## retune. Falls back to treating the whole year as one season if the cycle is
## empty (start_run loads the default before this matters).
var days_per_season: int:
	get:
		return maxi(1, days_per_year / maxi(1, season_cycle.size()))

## Total seasons in a run — one full bimodal year (Dry-Wet-Dry-Wet). Equal to
## season_cycle.size(), so a run never crosses a year boundary and year stays 1.
@export var season_count: int = 4

## Water the run starts with. Firefighting costs 1 per cell doused and WaterCycle
## refills continuously (fast while it rains), so this is the buffer that decides
## how big a fire you can survive before the weather has to bail you out — small
## on purpose. Migrate to a RunConfig .tres in the balance pass.
@export var starting_water: float = 10.0

## Tokens the run starts with. Everything placeable begins LOCKED (10 to
## unlock a type + 5 per placement), so 15 buys exactly one unlock and one
## placement — the opening has a verb without waiting for the first visitors.
## Set to 0 for the barren opening. Migrate to a RunConfig .tres later.
@export var starting_tokens: float = 15.0

## One full bimodal year, applied by index modulo its length: Dry, Wet, Dry, Wet.
## Its length doubles as seasons-per-year — it drives both the days_per_season
## split and the year counter (year increments every season_cycle.size() seasons).
@export var season_cycle: Array[SeasonProfile] = []

# --- State ---

var phase: Phase = Phase.IDLE
var season_index: int = 0
var year: int = 1

var _day_at_season_start: int = 0
var _time_paused_before: bool = false


func _ready() -> void:
	# Stay responsive if the tree pauses during planning later on.
	process_mode = Node.PROCESS_MODE_ALWAYS
	TimeManager.day_completed.connect(_on_day_completed)
	_load_default_cycle_if_empty()


## Kicked once by the level's RunController after world generation. Resets the
## ledger and clock, then opens season 0.
func start_run() -> void:
	if phase != Phase.IDLE and phase != Phase.RUN_OVER:
		push_warning("SeasonManager.start_run() while a run is active; ignoring")
		return
	ResourceLedger.reset()
	ResourceLedger.set_amount(&"water", starting_water, &"initial")
	ResourceLedger.set_amount(&"tokens", starting_tokens, &"initial")
	season_index = 0
	year = 1
	TimeManager.reset_clock()
	TimeManager.paused = false
	_day_at_season_start = 0
	phase = Phase.ACTIVE
	_apply_profile(current_profile())
	season_started.emit(season_index, current_profile())


## The currently active (or just-ended) season's profile.
func current_profile() -> SeasonProfile:
	if season_cycle.is_empty():
		return null
	return season_cycle[season_index % season_cycle.size()]


## Full day/night cycles elapsed in the current season (0 on the first day).
## Reaches days_per_season exactly as the season ends.
func days_into_season() -> int:
	return TimeManager.day_count - _day_at_season_start


## Seasons remaining including the current one. 0 once the run is over.
func seasons_remaining() -> int:
	if phase == Phase.RUN_OVER or phase == Phase.IDLE:
		return 0
	return season_count - season_index


## Called by the planning UI (or debug) to leave planning and start the next
## season. No-op outside PLANNING.
func begin_next_season() -> void:
	if phase != Phase.PLANNING:
		return
	season_index += 1
	var new_year: int = (season_index / maxi(1, season_cycle.size())) + 1
	if new_year != year:
		year = new_year
		year_changed.emit(year)
	phase = Phase.ACTIVE
	TimeManager.paused = _time_paused_before
	_day_at_season_start = TimeManager.day_count
	_apply_profile(current_profile())
	planning_phase_exited.emit(season_index)
	season_started.emit(season_index, current_profile())


## Force the run to end (loss conditions call this). Idempotent.
func end_run(reason: StringName) -> void:
	if phase == Phase.RUN_OVER:
		return
	phase = Phase.RUN_OVER
	TimeManager.paused = true
	run_completed.emit(reason)


func _on_day_completed(_day_count: int) -> void:
	if phase != Phase.ACTIVE:
		return
	if TimeManager.day_count - _day_at_season_start < days_per_season:
		return
	_end_current_season()


func _end_current_season() -> void:
	season_ended.emit(season_index, current_profile())
	if season_index + 1 >= season_count:
		end_run(&"survived")
		return
	# Enter planning between seasons.
	phase = Phase.PLANNING
	_time_paused_before = TimeManager.paused
	TimeManager.paused = true
	planning_phase_entered.emit(season_index + 1)


func _apply_profile(profile: SeasonProfile) -> void:
	if profile == null:
		return
	# Day/night look swap is a no-op until profiles are authored; the season
	# boundary is the right hook for it. DayNightSceneController will read the
	# active profile here in a later step.


func _load_default_cycle_if_empty() -> void:
	if not season_cycle.is_empty():
		return
	var dry: Resource = load("res://resources/seasons/dry.tres")
	var wet: Resource = load("res://resources/seasons/wet.tres")
	if dry != null and wet != null:
		# Bimodal year: two dry windows (Dec-Feb, Jun-Aug) alternating with two
		# wet (Mar-May, Sep-Nov). Profiles are reused until DJF/JJA need to differ.
		season_cycle = [dry, wet, dry, wet]
