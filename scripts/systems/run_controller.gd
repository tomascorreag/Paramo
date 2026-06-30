class_name RunController
extends Node

## Bridges world generation to the run spine, and makes the season loop
## observable before real HUD / planning UI exists.
##
## Lives on the procedural map base (next to ProceduralWorld). On generation
## finishing it starts the SeasonManager clock — never before, or the season
## would tick against a half-built mountain. It also swaps the Dry/Wet
## day/night look at each season boundary and drives a debug readout.
##
## The debug label + dev keys (F fast-forward, M end-season, N next-season) are
## scaffolding: they exist so a human can drive the whole loop in seconds and
## watch it cycle and end. Strip `debug_controls` and the label wiring once the
## real PlanningPhaseScreen / HUD land.

## ProceduralWorld whose generation_finished gates start_run(). If null (a
## non-procedural map), the run starts immediately on the next idle frame.
@export var procedural_world: ProceduralWorld

## Day/night controller to retint at season boundaries. Optional — the swap is
## skipped if unset or if the season has no authored profile.
@export var day_night_controller: DayNightSceneController

## Debug readout target. Optional.
@export var debug_label: Label

@export_group("Debug")
## Master switch for the dev keys. Turn off for player-facing builds.
@export var debug_controls: bool = true
## time_scale applied while fast-forward is toggled on.
@export var fast_forward_scale: float = 60.0

var _fast_forwarding: bool = false
var _normal_time_scale: float = 1.0


func _ready() -> void:
	SeasonManager.season_started.connect(_on_season_started)
	SeasonManager.run_completed.connect(_on_run_completed)
	ResourceLedger.resource_changed.connect(_on_resource_changed)

	if procedural_world != null:
		# Generation is async and always yields at least one frame before
		# emitting, so connecting here (same frame, synchronously) never misses
		# the signal. One-shot: a later debug regenerate won't restart the run.
		procedural_world.generation_finished.connect(_start, CONNECT_ONE_SHOT)
	else:
		call_deferred(&"_start")

	_refresh_label()


func _start() -> void:
	SeasonManager.start_run()
	if debug_controls:
		var p: SeasonProfile = SeasonManager.current_profile()
		print("RunController: run started — %s, Year %d" % [
			p.display_name if p != null else "—", SeasonManager.year])


# Cached label inputs so the per-frame formatter only runs when a shown value
# actually changes — avoids building a String + 9-element args Array every frame.
var _lbl_last_day: int = -1
var _lbl_last_water: int = -2147483648
var _lbl_last_ff: bool = false


func _process(_delta: float) -> void:
	# Only the day counter advances continuously (water/season are signal-driven),
	# so rebuild the label string solely when day, integer water, or the
	# fast-forward indicator changes.
	var day: int = SeasonManager.days_into_season()
	var water_i: int = int(ResourceLedger.get_amount(&"water"))
	if day == _lbl_last_day and water_i == _lbl_last_water and _fast_forwarding == _lbl_last_ff:
		return
	_lbl_last_day = day
	_lbl_last_water = water_i
	_lbl_last_ff = _fast_forwarding
	_refresh_label()


func _unhandled_input(event: InputEvent) -> void:
	if not debug_controls:
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match (event as InputEventKey).keycode:
		KEY_F:
			_toggle_fast_forward()
		KEY_M:
			_debug_force_end_season()
		KEY_N:
			SeasonManager.begin_next_season()


# --- Season signal handlers -------------------------------------------------

func _on_season_started(_index: int, profile: SeasonProfile) -> void:
	if day_night_controller != null and profile != null:
		day_night_controller.set_profile(profile.day_night_profile)
	_refresh_label()


func _on_run_completed(reason: StringName) -> void:
	if debug_controls:
		print("RunController: run completed — %s" % reason)
	if debug_label != null:
		debug_label.text = "RUN OVER — %s" % reason


func _on_resource_changed(_id: StringName, _value: float, _delta: float) -> void:
	_refresh_label()


# --- Debug helpers ----------------------------------------------------------

func _toggle_fast_forward() -> void:
	_fast_forwarding = not _fast_forwarding
	TimeManager.time_scale = fast_forward_scale if _fast_forwarding else _normal_time_scale


## Jump the clock to the season boundary by firing the same day_completed path
## the real clock uses — exercises the genuine rollover, not a shortcut.
func _debug_force_end_season() -> void:
	if SeasonManager.phase != SeasonManager.Phase.ACTIVE:
		return
	var remaining: int = SeasonManager.days_per_season - SeasonManager.days_into_season()
	for _i: int in range(maxi(1, remaining)):
		TimeManager.day_count += 1
		TimeManager.day_completed.emit(TimeManager.day_count)


func _refresh_label() -> void:
	if debug_label == null:
		return
	if SeasonManager.phase == SeasonManager.Phase.RUN_OVER:
		return  # left showing the run-over message
	var profile: SeasonProfile = SeasonManager.current_profile()
	var season_name: String = profile.display_name if profile != null else "—"
	var ff: String = "  ⏩" if _fast_forwarding else ""
	debug_label.text = "%s · Year %d · %s · Day %d/%d · Season %d/%d · Water %.0f%s" % [
		season_name,
		SeasonManager.year,
		_phase_name(SeasonManager.phase),
		mini(SeasonManager.days_into_season() + 1, SeasonManager.days_per_season),
		SeasonManager.days_per_season,
		SeasonManager.season_index + 1,
		SeasonManager.season_count,
		ResourceLedger.get_amount(&"water"),
		ff,
	]


func _phase_name(phase: int) -> String:
	if phase == SeasonManager.Phase.ACTIVE:
		return "ACTIVE"
	if phase == SeasonManager.Phase.PLANNING:
		return "PLANNING"
	if phase == SeasonManager.Phase.RUN_OVER:
		return "RUN OVER"
	return "IDLE"
