extends Node
## Autoload registered as "DayLog" in project.godot.
## Cannot use class_name — Godot disallows class_name matching an autoload name.

## What the mountain GAVE the player on each day of the run, so the journal's
## calendar can print a day's yield beside its stamp.
##
## Nothing recorded this before. ResourceLedger keeps a lifetime-of-run cumulative
## net per SOURCE (see its `_by_source`), which cannot answer "what came in on day
## 9" — a spend and an earn on the same source cancel, and there is no day
## dimension at all. VisitorFlow computed the day's visitor count and threw it away.
## The only per-day series in the project lived in the headless simulator
## (sim_runner.gd) and never runs in game.
##
## OBTAINED, not net: only POSITIVE deltas are accumulated. That is the question
## the calendar asks — a day you spent 20 water dousing a fire still "gave" you the
## 6 the fog nets caught. Reading the net would print a negative yield on the days
## the player was most active, which is exactly backwards.
##
## Deltas are taken straight off ResourceLedger.resource_changed, so no source
## whitelist has to be maintained: a new water or token source starts being counted
## the day it is added.
##
## VISITORS are not a ledger resource — they are a source TAG that mints tokens
## (VisitorFlow.SOURCE). They get their own channel via VisitorFlow's
## `visitors_arrived` signal. Deriving the count from the token delta would work
## today and silently break the moment `tokens_per_visitor` stops being 1.0.
##
## Passive and RNG-free: it observes signals and adds floats, drawing from no
## random stream, so it cannot perturb a simulated run (tests/test_sim_determinism.gd).

## Resource ids tracked, in the order the calendar prints them.
const WATER: StringName = &"water"
const TOKENS: StringName = &"tokens"
const VISITORS: StringName = &"visitors"

# day index -> {water, tokens, visitors}. Index 0 is the run's first day, matching
# RunCalendar's cell order.
var _days: Array[Dictionary] = []
# The day currently being lived, still accumulating.
var _today: Dictionary = {}
var _bucket_day: int = 0


func _ready() -> void:
	ResourceLedger.resource_changed.connect(_on_resource_changed)
	# The day boundary is detected off time_changed, NOT day_completed, and that is
	# load-bearing. TimeManager.advance emits day_completed FIRST and time_changed
	# immediately after, in the same call — so by the time this runs, every other
	# day_completed handler has already banked its end-of-day income (VisitorFlow's
	# token lump above all). Closing the bucket on day_completed instead would race
	# the connection order and drop that income into the FOLLOWING day. Same
	# day_count != last_day idiom the headless simulator settled on.
	TimeManager.time_changed.connect(_on_time_changed)
	SeasonManager.season_started.connect(_on_season_started)


## The yield of one day of the run, 0-based. Days not yet lived — and the day in
## progress — read as zeros; the calendar only asks about days it has stamped.
func day(index: int) -> Dictionary:
	if index < 0 or index >= _days.size():
		return {WATER: 0, TOKENS: 0, VISITORS: 0}
	var d: Dictionary = _days[index]
	# Floored to whole units, matching how the journal has always shown a
	# resource: a partial drop of water is not something the page can print.
	return {
		WATER: int(floorf(float(d.get(WATER, 0.0)))),
		TOKENS: int(floorf(float(d.get(TOKENS, 0.0)))),
		VISITORS: int(d.get(VISITORS, 0)),
	}


## Days closed so far. Lags RunCalendar.elapsed_days by at most the day in
## progress.
func day_count() -> int:
	return _days.size()


## Writes one day's yield outright, padding the log to reach it.
##
## For anything that has a run's history but did not LIVE it: the preview tools
## (which teleport the clock to a state rather than advancing through it, so the
## accumulation path never runs), tests, and a save/load when one exists. Gameplay
## must never call this — the point of the accumulator is that the log is a
## by-product of play, not something a system decides to assert.
func seed_day(index: int, values: Dictionary) -> void:
	if index < 0:
		return
	while _days.size() <= index:
		_days.append({})
	_days[index] = values.duplicate()
	_bucket_day = maxi(_bucket_day, _days.size())


func _on_resource_changed(id: StringName, _value: float, delta: float) -> void:
	if delta <= 0.0:
		return
	_today[id] = float(_today.get(id, 0.0)) + delta


func _on_visitors_arrived(count: int) -> void:
	_today[VISITORS] = int(_today.get(VISITORS, 0)) + count


func _on_time_changed(_t: float) -> void:
	if TimeManager.day_count == _bucket_day:
		return
	# Pad rather than assume a single step: nothing emits a multi-day jump today,
	# but a skipped day would otherwise shift every later day's yield by one cell,
	# which reads as data rather than as a bug.
	while _days.size() < TimeManager.day_count:
		_days.append(_today if _days.size() == _bucket_day else {})
	_today = {}
	_bucket_day = TimeManager.day_count


func _on_season_started(index: int, _profile: SeasonProfile) -> void:
	# Season 0 is a fresh run, the same edge UnlockState clears its purchases on.
	if index != 0:
		return
	_days.clear()
	_today = {}
	_bucket_day = TimeManager.day_count


## VisitorFlow calls this itself in _ready — the flow is a scene node, so it comes
## and goes with the map while this autoload persists.
func bind_visitor_flow(flow: Node) -> void:
	if flow == null or not flow.has_signal(&"visitors_arrived"):
		return
	if not flow.is_connected(&"visitors_arrived", _on_visitors_arrived):
		flow.connect(&"visitors_arrived", _on_visitors_arrived)
