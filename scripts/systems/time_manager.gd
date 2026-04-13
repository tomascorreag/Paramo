extends Node
## Autoload registered as "TimeManager" in project.godot.
## Cannot use class_name — Godot disallows class_name matching an autoload name.

## Global game clock. Tracks normalized time of day and emits signals
## at key thresholds. Register as autoload.

signal time_changed(time_normalized: float)
signal period_changed(new_period: StringName, old_period: StringName)
signal day_completed(day_count: int)

# --- Period constants ---

const PERIOD_DAWN: StringName = &"dawn"
const PERIOD_MORNING: StringName = &"morning"
const PERIOD_NOON: StringName = &"noon"
const PERIOD_AFTERNOON: StringName = &"afternoon"
const PERIOD_DUSK: StringName = &"dusk"
const PERIOD_NIGHT: StringName = &"night"

# Sorted by threshold. The first entry whose threshold > time_of_day wins.
const _PERIODS: Array[Array] = [
	[0.22, PERIOD_NIGHT], # 00:00 – 05:17
	[0.30, PERIOD_DAWN], # 05:17 – 07:12
	[0.45, PERIOD_MORNING], # 07:12 – 10:48
	[0.55, PERIOD_NOON], # 10:48 – 13:12
	[0.70, PERIOD_AFTERNOON], # 13:12 – 16:48
	[0.80, PERIOD_DUSK], # 16:48 – 19:12
	[1.01, PERIOD_NIGHT], # 19:12 – 00:00
]

# --- State ---

## Normalized time of day [0.0, 1.0). 0 = midnight, 0.5 = noon.
var time_of_day: float = 0.25

## Total completed day cycles.
var day_count: int = 0

# --- Configuration ---

## Real seconds per full game day.
@export var seconds_per_game_day: float = 300.0

## Speed multiplier. 1.0 = realtime. Set >1 for debug fast-forward.
@export var time_scale: float = 1.0

## Halts the clock when true (for planning phases, menus, etc.).
@export var paused: bool = false

var _current_period: StringName = &""


func _ready() -> void:
	_current_period = _evaluate_period(time_of_day)


func _process(delta: float) -> void:
	if paused or seconds_per_game_day <= 0.0:
		return

	var advance: float = delta * time_scale / seconds_per_game_day
	time_of_day += advance

	if time_of_day >= 1.0:
		time_of_day -= 1.0
		day_count += 1
		day_completed.emit(day_count)

	time_changed.emit(time_of_day)

	var new_period: StringName = _evaluate_period(time_of_day)
	if new_period != _current_period:
		var old: StringName = _current_period
		_current_period = new_period
		period_changed.emit(new_period, old)


## Returns the current named period.
func get_period() -> StringName:
	return _current_period


## Jump to a specific time (for debug / cutscenes).
## NOTE: Does not advance day_count on wrap — use for visual repositioning only.
func set_time(t: float) -> void:
	time_of_day = fmod(t, 1.0)
	var new_period: StringName = _evaluate_period(time_of_day)
	if new_period != _current_period:
		var old: StringName = _current_period
		_current_period = new_period
		period_changed.emit(new_period, old)
	time_changed.emit(time_of_day)


func _evaluate_period(t: float) -> StringName:
	for entry: Array in _PERIODS:
		if t < entry[0]:
			return entry[1]
	return PERIOD_NIGHT
