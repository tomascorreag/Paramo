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
## too and must not tick there). Run begins ACTIVE in season 0. Seasons roll
## STRAIGHT into one another — season_ended is immediately followed by the next
## season_started, with the clock never stopping. The final season ending
## completes the run.
##
## NOTE (removed 2026-08-09): there was a PLANNING phase between seasons that
## paused TimeManager and waited for a begin_next_season() call. Nothing in the
## game ever made that call — the PlanningPhaseScreen it was waiting on was never
## built — so the run deadlocked at the first season boundary with the clock
## frozen at midnight and every ACTIVE-gated system inert. Reinstating it means
## reinstating the screen in the same change, not before it.

signal season_started(index: int, profile: SeasonProfile)
## Emitted before the next season starts (or before the run completes, on the
## final season). This is the only "between seasons" moment there is now that
## planning is gone — anything that used to hang off planning_phase_entered
## hangs off this.
signal season_ended(index: int, profile: SeasonProfile)
signal year_changed(year: int)
## reason: &"survived" | &"laguna_dead" | &"funding_zero" | ...
signal run_completed(reason: StringName)

enum Phase { IDLE, ACTIVE, RUN_OVER }

# --- Configuration (tunable; migrate to a RunConfig .tres in the balance pass) ---

## Length of a full year in day/night cycles. The calendar splits this evenly
## across `season_cycle`, so each season runs `days_per_year /
## season_cycle.size()` days. N=24 -> 4 days per season for the default
## 6-season (Wet-Dry x3) year. Run length = days_per_season *
## seconds_per_game_day * season_count.
@export var days_per_year: int = 24

## Day/night cycles per season — derived from days_per_year and the number of
## seasons in a year (= season_cycle length). Read-only; set days_per_year to
## retune. Falls back to treating the whole year as one season if the cycle is
## empty (start_run loads the default before this matters).
var days_per_season: int:
	get:
		return maxi(1, days_per_year / maxi(1, season_cycle.size()))

## Total seasons in a run. Equal to season_cycle.size(), so a run never
## crosses a year boundary and year stays 1.
@export var season_count: int = 6

## Water the run starts with. Firefighting costs 1 per cell doused and WaterCycle
## refills continuously (fast while it rains), so this is the buffer that decides
## how big a fire you can survive before the weather has to bail you out — small
## on purpose. Migrate to a RunConfig .tres in the balance pass.
@export var starting_water: float = 10.0

## Tokens the run starts with. Everything placeable begins LOCKED (10-30 to
## unlock a type — see UnlockState.unlock_costs — then 1 per tile placed).
##
## Was 10 — deliberately half an unlock, so day one bought nothing and the
## opening move was to survive a day of visitors first. The FTUE overrides that
## call (2026-08-13): its last step is "buy a tool, then build it", and a player
## who cannot complete the tutorial on day one has no smooth first day.
##
## 15 buys the cheap end of the shop (a ladder or a frailejon at 10) and leaves
## 5 tiles of placement, but NOT a bridge or a fence — so the opening choice is
## still a real one, and the expensive verbs still cost a day of visitors.
## Roughly one perfect day's income (6 visitors x 2 tokens) handed over at
## spawn: rerun sim/balance_sim.gd against the old arm before treating any
## downstream number as unchanged. Migrate to a RunConfig .tres later.
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


## Roll into the next season. Called only from _end_current_season, which has
## already checked there IS a next season.
func _begin_next_season() -> void:
	season_index += 1
	var new_year: int = (season_index / maxi(1, season_cycle.size())) + 1
	if new_year != year:
		year = new_year
		year_changed.emit(year)
	_day_at_season_start = TimeManager.day_count
	_apply_profile(current_profile())
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
	_begin_next_season()


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
		# Wet-first alternation (balance decision 2026-08-06): opening wet keeps
		# the run's first day from being a map-wide cold-start burn — the whole
		# map is contiguous fuel at day 1, and sim sweeps showed a dry opening
		# chars ~45% of it before the player can matter. Departs from the strict
		# bimodal-calendar framing (which had 2 dry + 2 wet per year).
		season_cycle = [wet, dry, wet, dry, wet, dry]
