class_name PauseMenu
extends CanvasLayer

## Center-screen pause modal. Opened by the HUD pause button (via the `pause_menu`
## group) or the `pause` input action (Esc). Freezes the game with
## get_tree().paused; this layer runs PROCESS_MODE_ALWAYS so its own buttons stay
## live while everything else is frozen.
##
## The main view shows an inline Settings section (a single master-volume slider)
## with Quit and Resume beneath it; Quit swaps to a confirm view. Volume drives
## two sinks: the page-side Strudel music gain through JavaScriptBridge (web
## only) and the Godot-side SFX bus (all platforms). Quit confirms first,
## then fully restarts: on web a
## page reload (the truest reset — autoloads, JS and music all clear), on desktop
## a scene reload after resetting SeasonManager so RunController.start_run()
## re-initialises cleanly (its guard early-returns unless IDLE/RUN_OVER).
##
## Fully scene-authored (see pause_menu.tscn): all fills/frames/colors come from
## the global theme (resources/ui/paramo_theme.tres) + the frame_border stylebox,
## so the modal renders styled in the editor. This script holds only logic.

enum View { MAIN, CONFIRM }

@onready var _title: Label = %Title
@onready var _main: VBoxContainer = %Main
@onready var _confirm: VBoxContainer = %Confirm
@onready var _volume_slider: HSlider = %VolumeSlider

var _open: bool = false
var _view: View = View.MAIN


func _ready() -> void:
	# ALWAYS so the modal keeps processing + receiving input under get_tree().paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = UILayers.PAUSE
	add_to_group(&"pause_menu")
	_wire()
	visible = false
	_set_view(View.MAIN)


func _wire() -> void:
	(%ResumeBtn as Button).pressed.connect(close)
	(%CancelBtn as Button).pressed.connect(_set_view.bind(View.MAIN))
	(%YesBtn as Button).pressed.connect(_do_restart)
	_volume_slider.value_changed.connect(_on_volume_changed)
	# Apply the authored default now — otherwise the SFX bus sits at 0 dB (louder
	# than the slider claims) until the player first drags it.
	_on_volume_changed(_volume_slider.value)


# --- Open / close -----------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"pause"):
		return
	get_viewport().set_input_as_handled()
	if not _open:
		open()
	elif _view != View.MAIN:
		_set_view(View.MAIN)   # Esc backs out of a sub-panel first
	else:
		close()


func toggle() -> void:
	if _open:
		close()
	else:
		open()


func open() -> void:
	if _open:
		return
	_open = true
	_set_view(View.MAIN)
	visible = true
	get_tree().paused = true


func close() -> void:
	if not _open:
		return
	_open = false
	visible = false
	get_tree().paused = false


func _set_view(v: View) -> void:
	_view = v
	_main.visible = v == View.MAIN
	_confirm.visible = v == View.CONFIRM
	_title.text = "quit?" if v == View.CONFIRM else "paused"


# --- Actions ----------------------------------------------------------------

func _on_volume_changed(v: float) -> void:
	# Two sinks, because the game's audio comes from two places: the music is
	# page-side (Strudel, web only) and the SFX are Godot-side (the SFX bus, all
	# platforms). One slider drives both so it reads as a true master volume.
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.ParamoMusic && window.ParamoMusic.setVolume(%f);" % v)
	var sfx := AudioServer.get_bus_index(&"SFX")
	if sfx >= 0:
		# linear_to_db(0) is -inf; mute instead so the bus doesn't carry a
		# non-finite gain.
		AudioServer.set_bus_mute(sfx, v <= 0.0)
		if v > 0.0:
			AudioServer.set_bus_volume_db(sfx, linear_to_db(v))


func _do_restart() -> void:
	get_tree().paused = false
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.location.reload();")
		return
	# Desktop/editor: autoloads survive a scene reload, so hand SeasonManager back
	# to IDLE — its start_run() (re-fired by the reloaded RunController once the
	# world regenerates) then resets the ledger, clock and season cleanly.
	SeasonManager.phase = SeasonManager.Phase.IDLE
	get_tree().reload_current_scene()
