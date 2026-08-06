class_name RunController
extends Node

## Bridges world generation to the run spine, and makes the season loop
## observable before real HUD / planning UI exists.
##
## Lives on the procedural map base (next to ProceduralWorld). On generation
## finishing it starts the SeasonManager clock — never before, or the season
## would tick against a half-built mountain. It also swaps the Dry/Wet
## day/night look at each season boundary.
##
## The dev keys (F fast-forward, M end-season, N next-season) are scaffolding:
## they exist so a human can drive the whole loop in seconds and watch it cycle
## and end. Strip `debug_controls` once the real PlanningPhaseScreen lands. The
## run's state is now READ off the journal (RunCalendar + the season wheel)
## rather than pushed into a debug label from here.

## ProceduralWorld whose generation_finished gates start_run(). If null (a
## non-procedural map), the run starts immediately on the next idle frame.
@export var procedural_world: ProceduralWorld

## Day/night controller to retint at season boundaries. Optional — the swap is
## skipped if unset or if the season has no authored profile.
@export var day_night_controller: DayNightSceneController

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

	# Pre-apply season 1's day/night look before anything renders. start_run()
	# re-applies the same profile object later, which is then a visual no-op —
	# without this the swap from the scene's authored profile (tileset_test)
	# to dry_season lands as a one-frame regrade snap in FRONT of the player:
	# generation_finished fires only after the loading overlay has faded out.
	# Deferred so peer _readys (DayNightController's own initial grade) run first.
	call_deferred(&"_preapply_season_look")

	if procedural_world != null:
		# Generation is async and always yields at least one frame before
		# emitting, so connecting here (same frame, synchronously) never misses
		# the signal. One-shot: a later debug regenerate won't restart the run.
		procedural_world.generation_finished.connect(_start, CONNECT_ONE_SHOT)
	else:
		call_deferred(&"_start")


func _preapply_season_look() -> void:
	_on_season_started(0, SeasonManager.current_profile())


func _start() -> void:
	# The language gate freezes the world at night while the player decides.
	# Starting the run there would unpause TimeManager (SeasonManager.start_run
	# does) — the frozen entry screen then drifts from midnight toward dawn, and
	# the player's idle time burns season days. Wait for the pick instead;
	# TitleIntro emits `begun` as the cinematic starts.
	var intro := get_tree().get_first_node_in_group(&"title_intro")
	if intro != null and intro.has_method(&"is_awaiting_click") \
			and intro.is_awaiting_click() and intro.has_signal(&"begun"):
		intro.connect(&"begun", _start, CONNECT_ONE_SHOT)
		return
	SeasonManager.start_run()
	if debug_controls:
		var p: SeasonProfile = SeasonManager.current_profile()
		print("RunController: run started — %s, Year %d" % [
			p.display_name if p != null else "—", SeasonManager.year])


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


func _on_run_completed(reason: StringName) -> void:
	if debug_controls:
		print("RunController: run completed — %s" % reason)


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
