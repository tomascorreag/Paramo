class_name PauseMenu
extends CanvasLayer

## Center-screen pause modal. Opened by the HUD pause button (via the `pause_menu`
## group) or the `pause` input action (Esc). Freezes the game with
## get_tree().paused; this layer runs PROCESS_MODE_ALWAYS so its own buttons stay
## live while everything else is frozen.
##
## Three views share one panel, swapped by _set_view: MAIN is an inline Settings
## section (master volume, fullscreen, language, about) with Quit and Resume
## beneath it; CONFIRM guards Quit; ABOUT carries the credits and the licence
## links. Only one is visible at a time, and the panel does not grow to fit them,
## so the tallest view sets Panel.custom_minimum_size.
##
## Volume drives two sinks: the page-side Strudel music gain through
## JavaScriptBridge (web only) and the Godot-side SFX bus (all platforms). Quit
## confirms first, then fully restarts: on web a page reload (the truest reset —
## autoloads, JS and music all clear), on desktop a scene reload after resetting
## SeasonManager so RunController.start_run() re-initialises cleanly (its guard
## early-returns unless IDLE/RUN_OVER).
##
## Fully scene-authored (see pause_menu.tscn): all fills/frames/colors come from
## the global theme (resources/ui/paramo_theme.tres) + the frame_border stylebox,
## so the modal renders styled in the editor. This script holds only logic.

enum View { MAIN, CONFIRM, ABOUT }

# Every link the About view can open. Deep links rather than bare repo URLs:
# the point of the section is that a player can READ the licences, not hunt for
# them. Pinned to `main` rather than to a tag — there are no release tags, and a
# dead link is worse than a link that tracks the branch.
const REPO_URL: String = "https://github.com/tomascorreag/Paramo"
const LICENCE_URL: String = REPO_URL + "/blob/main/LICENSE"
const NOTICES_URL: String = REPO_URL + "/blob/main/THIRD-PARTY-NOTICES.md"

# One title key per view, so the header names the view the player is looking at.
const TITLE_KEYS: Dictionary = {
	View.MAIN: "UI_PAUSED",
	View.CONFIRM: "UI_QUIT_Q",
	View.ABOUT: "UI_ABOUT",
}

@onready var _title: Label = %Title
@onready var _main: VBoxContainer = %Main
@onready var _confirm: VBoxContainer = %Confirm
@onready var _about: VBoxContainer = %About
@onready var _volume_slider: HSlider = %VolumeSlider
@onready var _fullscreen_btn: Button = %FullscreenBtn
@onready var _language_btn: Button = %LanguageBtn

var _open: bool = false
var _view: View = View.MAIN
var _was_fullscreen: bool = false


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
	(%AboutBtn as Button).pressed.connect(_set_view.bind(View.ABOUT))
	(%BackBtn as Button).pressed.connect(_set_view.bind(View.MAIN))
	(%SourceBtn as Button).pressed.connect(_open_url.bind(REPO_URL))
	(%LicenceBtn as Button).pressed.connect(_open_url.bind(LICENCE_URL))
	(%NoticesBtn as Button).pressed.connect(_open_url.bind(NOTICES_URL))
	_fullscreen_btn.pressed.connect(_on_fullscreen_pressed)
	_refresh_fullscreen_label()
	_language_btn.pressed.connect(_on_language_pressed)
	LocaleManager.locale_changed.connect(_on_locale_changed)
	_refresh_language_label()
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
	_refresh_fullscreen_label()
	_refresh_language_label()
	visible = true
	get_tree().paused = true


# The window mode can change behind the menu's back — the `toggle_fullscreen`
# action (F11) is handled by DisplayManager, and the OS/window manager can do it
# too (alt+enter, a titlebar button). Polling the mode while the modal is open is
# two DisplayServer calls a frame in the one state where nothing else runs, and it
# is the only way to keep the label honest without a signal per source.
func _process(_delta: float) -> void:
	if _open and _is_fullscreen() != _was_fullscreen:
		_refresh_fullscreen_label()


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
	_about.visible = v == View.ABOUT
	# Translation KEYS, not text: Label re-translates whatever is in `text` when
	# the locale changes, so storing an already-translated string here would
	# freeze this one label in the language it was set in.
	_title.text = TITLE_KEYS[v]


# --- Actions ----------------------------------------------------------------

func _is_fullscreen() -> bool:
	var mode := DisplayServer.window_get_mode()
	return mode == DisplayServer.WINDOW_MODE_FULLSCREEN \
		or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN


# The button is labelled with the ACTION it performs, not the current state, so
# there is no on/off wording to translate ("activado"/"desactivado" does not fit
# a 160px panel row). Store the KEY: a Button re-translates whatever sits in
# `text` on a locale change, so writing tr() here would freeze the language.
func _refresh_fullscreen_label() -> void:
	_was_fullscreen = _is_fullscreen()
	_fullscreen_btn.text = "UI_WINDOWED" if _was_fullscreen else "UI_FULLSCREEN"


func _on_fullscreen_pressed() -> void:
	# On web the browser only grants fullscreen from inside a user gesture; a
	# `pressed` handler runs during input processing, so this call is honoured
	# where a self-initiated one would be dropped silently.
	DisplayManager.toggle_fullscreen()
	_refresh_fullscreen_label()


# --- Language ---------------------------------------------------------------
#
# The gate on the title screen asks once per launch; this is the in-run escape
# hatch for a player who picked wrong, or who wants to read the journal in the
# other language. With exactly two shipped locales a toggle beats a submenu, so
# the button advances to the NEXT entry of LocaleManager.SUPPORTED and wraps.
#
# Its label is the target language's own `native` string — LITERAL text, exactly
# as the gate prints it, never a translation key. Two reasons: the point of the
# control is being readable to someone who cannot read the language currently on
# screen, and there is no key to translate ("english" is not a translation of
# "español", they are two different words that are each always spelled that way).
# The flip side is that Godot's NOTIFICATION_TRANSLATION_CHANGED will NOT fix
# this label for us the way it fixes every other one in this menu, so we refresh
# it by hand off locale_changed (and on open, in case something else switched).

func _next_locale_index() -> int:
	var supported: Array[Dictionary] = LocaleManager.SUPPORTED
	var current := TranslationServer.get_locale()
	for i: int in supported.size():
		if supported[i]["code"] == current:
			return (i + 1) % supported.size()
	# Active locale is not one we ship (only reachable if something bypassed
	# LocaleManager): offer the first shipped one rather than doing nothing.
	return 0


func _refresh_language_label() -> void:
	_language_btn.text = String(LocaleManager.SUPPORTED[_next_locale_index()]["native"])


func _on_language_pressed() -> void:
	LocaleManager.set_locale(String(LocaleManager.SUPPORTED[_next_locale_index()]["code"]))


func _on_locale_changed(_code: String) -> void:
	_refresh_language_label()


# --- About ------------------------------------------------------------------
#
# The section exists to make the licences reachable from inside the game: Paramo
# is MIT, but the deployed build carries AGPL (Strudel) and MIT-with-required-
# notice (FluidR3) works, and THIRD-PARTY-NOTICES.md is the document that says so.
#
# OS.shell_open covers both platforms — on web it lands on
# `godot_js_os_shell_open`, i.e. window.open(uri, "_blank"). A browser may still
# refuse that as a popup, since Godot dispatches the button press from its own
# frame rather than from inside the DOM click handler; the repo URL is therefore
# also printed as plain text in the panel, so a blocked popup is not a dead end.

func _open_url(url: String) -> void:
	OS.shell_open(url)


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
