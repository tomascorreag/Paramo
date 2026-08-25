class_name PauseMenu
extends CanvasLayer

## Center-screen pause modal. Opened by the HUD pause button (via the `pause_menu`
## group) or the `pause` input action (Esc). Freezes the game with
## get_tree().paused; this layer runs PROCESS_MODE_ALWAYS so its own buttons stay
## live while everything else is frozen.
##
## Three views share one panel, swapped by _set_view: MAIN is two titled sections
## (settings: master volume, fullscreen, language / info: about) with Resume
## beneath them; CONFIRM guards Quit; ABOUT carries the credits and the licence
## links. Only one is visible at a time, and the panel does not grow to fit them,
## so the tallest view sets Panel.custom_minimum_size.
##
## Every view except MAIN is a submenu, and the way back is the chevron anchored
## to the panel's top-left corner (BackBtn), not a row in the view itself: the
## control is in the same place whichever submenu you are in, and it costs a
## submenu no height. _set_view is the only thing that shows it.
##
## The settings rows are widgets, not plain buttons: fullscreen is a checkbox
## (the row states the setting, the box states its value) and language is a
## dropdown. Both are built out of the authored styleboxes rather than out of
## Godot's CheckBox/OptionButton, which come with their own unthemed art and,
## for OptionButton, a PopupMenu this project's theme does not style.
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
@onready var _check_fill: Panel = %CheckFill
@onready var _language_btn: Button = %LanguageBtn
@onready var _language_value: Label = %Value
@onready var _language_popup: Panel = %LangPopup
@onready var _language_options: VBoxContainer = %Options
@onready var _back_btn: Button = %BackBtn
@onready var _author: Label = %Author

var _open: bool = false
var _view: View = View.MAIN
var _was_fullscreen: bool = false

## True while this modal holds the tree paused.
##
## Pausing does NOT silence the game's hotkeys on its own: the SceneTree skips
## input on nodes that can't process, but every node that has to stay live under
## pause runs PROCESS_MODE_ALWAYS, so its keys keep firing behind the modal
## (Space threw the journal open on top of the pause menu; any key advanced an
## FTUE line). Those handlers ask here before acting.
##
## Static rather than a group lookup, following TutorialGate: one writer (this
## node), a read per input event, no tree walk. The cost is the same one — it is
## per-PROCESS, not per-scene — hence the clear in `_exit_tree`, which covers the
## desktop quit path (reload_current_scene frees the modal without closing it).
##
## `get_tree().paused` is deliberately NOT the test: the journal pauses the tree
## too, and its own Space must still close it.
static var _blocking: bool = false


static func is_blocking() -> bool:
	return _blocking


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
	_back_btn.pressed.connect(_set_view.bind(View.MAIN))
	(%SourceBtn as Button).pressed.connect(_open_url.bind(REPO_URL))
	(%LicenceBtn as Button).pressed.connect(_open_url.bind(LICENCE_URL))
	(%NoticesBtn as Button).pressed.connect(_open_url.bind(NOTICES_URL))
	_fullscreen_btn.pressed.connect(_on_fullscreen_pressed)
	_refresh_fullscreen_toggle()
	_language_btn.pressed.connect(_toggle_language_popup)
	_build_language_options()
	LocaleManager.locale_changed.connect(_on_locale_changed)
	_refresh_language_row()
	_refresh_author()
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
	elif _language_popup.visible:
		_close_language_popup()   # the dropdown is the innermost thing open
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
	_refresh_fullscreen_toggle()
	_refresh_language_row()
	visible = true
	_blocking = true
	get_tree().paused = true


# The window mode can change behind the menu's back — the `toggle_fullscreen`
# action (F11) is handled by DisplayManager, and the OS/window manager can do it
# too (alt+enter, a titlebar button). Polling the mode while the modal is open is
# two DisplayServer calls a frame in the one state where nothing else runs, and it
# is the only way to keep the label honest without a signal per source.
func _process(_delta: float) -> void:
	if _open and _is_fullscreen() != _was_fullscreen:
		_refresh_fullscreen_toggle()


func close() -> void:
	if not _open:
		return
	_open = false
	visible = false
	_blocking = false
	get_tree().paused = false


func _exit_tree() -> void:
	_blocking = false


func _set_view(v: View) -> void:
	_view = v
	_main.visible = v == View.MAIN
	_confirm.visible = v == View.CONFIRM
	_about.visible = v == View.ABOUT
	# MAIN is the root, so every other view is a submenu and gets the chevron.
	# Derived from the view rather than set per transition: a view added later
	# is reachable and escapable without touching this line.
	_back_btn.visible = v != View.MAIN
	_close_language_popup()
	# Translation KEYS, not text: Label re-translates whatever is in `text` when
	# the locale changes, so storing an already-translated string here would
	# freeze this one label in the language it was set in.
	_title.text = TITLE_KEYS[v]


# --- Actions ----------------------------------------------------------------

func _is_fullscreen() -> bool:
	var mode := DisplayServer.window_get_mode()
	return mode == DisplayServer.WINDOW_MODE_FULLSCREEN \
		or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN


# A checkbox, so the row names the SETTING ("fullscreen") and the box carries its
# value. The previous row was a button labelled with the action, which had to
# swap between two translated words and read as ambiguous — nothing said whether
# "windowed" was the current state or the thing a press would do.
#
# The box is two authored styleboxes and no art: a solid_surface well with a
# frame_border on top, and an accent-soft fill inset 2px inside it that is simply
# hidden when off. Godot's CheckBox was rejected for its own reason: its check
# glyph is a theme icon this project would have to draw and register, and the
# widget would still not carry the panel's frame.
func _refresh_fullscreen_toggle() -> void:
	_was_fullscreen = _is_fullscreen()
	_check_fill.visible = _was_fullscreen


func _on_fullscreen_pressed() -> void:
	# On web the browser only grants fullscreen from inside a user gesture; a
	# `pressed` handler runs during input processing, so this call is honoured
	# where a self-initiated one would be dropped silently.
	DisplayManager.toggle_fullscreen()
	_refresh_fullscreen_toggle()


# --- Language ---------------------------------------------------------------
#
# The gate on the title screen asks once per launch; this is the in-run escape
# hatch for a player who picked wrong, or who wants to read the journal in the
# other language.
#
# A dropdown rather than the old advance-to-the-next-locale toggle: the toggle
# only reads correctly while exactly two locales ship — its label had to name the
# language you were NOT in, which is a puzzle the moment there is a third. The
# row now states the active language and the list states the alternatives, which
# is the same shape at any count.
#
# It is NOT an OptionButton. That widget opens a PopupMenu, a separate Window
# with its own theme items (none of which paramo_theme.tres styles) and its own
# arrow icon, and a Window does not inherit this CanvasLayer's integer upscale.
# The list here is a Panel inside the modal, positioned under the row, drawn with
# the same solid_surface + frame_border pair as everything else in the panel.
#
# Every native name is LITERAL text, exactly as the title gate prints it, never a
# translation key: the point of the control is being readable to someone who
# cannot read the language currently on screen, and there is nothing to translate
# ("english" is not a translation of "español", they are two different words that
# are each always spelled that way). The flip side is that
# NOTIFICATION_TRANSLATION_CHANGED will NOT fix these labels the way it fixes
# every other one in this menu, so the row is refreshed by hand off
# locale_changed (and on open, in case something else switched).

## Height of one row in the dropdown, and the inset of the list inside its frame.
const LANG_ROW_H: int = 14
const LANG_POPUP_PAD: int = 4


func _build_language_options() -> void:
	# Data-driven from LocaleManager.SUPPORTED — the same array the title gate
	# builds its boxes from, so a third locale is a CSV column plus an entry
	# there, and this list grows on its own.
	for child: Node in _language_options.get_children():
		child.queue_free()
	for entry: Dictionary in LocaleManager.SUPPORTED:
		var row := Button.new()
		row.custom_minimum_size = Vector2(0, LANG_ROW_H)
		row.focus_mode = Control.FOCUS_NONE
		row.text = String(entry["native"])
		row.icon = load(String(entry["flag"])) as Texture2D
		row.pressed.connect(_on_language_chosen.bind(String(entry["code"])))
		_language_options.add_child(row)


func _refresh_language_row() -> void:
	var active := TranslationServer.get_locale()
	for i: int in LocaleManager.SUPPORTED.size():
		var entry: Dictionary = LocaleManager.SUPPORTED[i]
		if String(entry["code"]) == active:
			_language_value.text = String(entry["native"])
		# The row already open in the list is marked, not hidden: a two-item list
		# with the active item removed is a one-item list, which reads as broken.
		var option := _language_options.get_child(i) as Button
		if option != null:
			option.add_theme_color_override(&"font_color",
				Palette.ACCENT if String(entry["code"]) == active else Palette.TEXT)


func _toggle_language_popup() -> void:
	if _language_popup.visible:
		_close_language_popup()
		return
	# Sized and placed from the row it drops out of, every time it opens: the
	# panel lays out on the frame after a view swap, so a position baked into the
	# scene would be stale the first time the modal is shown.
	_language_popup.size = Vector2(
		_language_btn.size.x,
		_language_options.get_combined_minimum_size().y + LANG_POPUP_PAD)
	_language_popup.global_position = _language_btn.global_position 		+ Vector2(0.0, _language_btn.size.y)
	_language_popup.visible = true


func _close_language_popup() -> void:
	_language_popup.visible = false


# A click anywhere outside the list dismisses it, which is what every dropdown
# does and what a player who opened it by accident will try. _input rather than
# _unhandled_input: the panel's own Buttons consume presses before they reach the
# unhandled pass, so a click on Resume would leave the list open behind the view.
# The event is never consumed — dismissing must not also eat the click.
func _input(event: InputEvent) -> void:
	if not _language_popup.visible:
		return
	var click := event as InputEventMouseButton
	if click == null or not click.pressed:
		return
	if _language_popup.get_global_rect().has_point(click.position):
		return
	if _language_btn.get_global_rect().has_point(click.position):
		return  # the row itself toggles; closing here would fight it
	_close_language_popup()


func _on_language_chosen(code: String) -> void:
	_close_language_popup()
	LocaleManager.set_locale(code)


func _on_locale_changed(_code: String) -> void:
	_refresh_language_row()


# --- Credits ----------------------------------------------------------------
#
# "by Tomás Correa · 2026" is one line made of two different things: a preposition
# that translates ("por" in Spanish) and a name that does not. So the key holds
# only the preposition and the name stays a literal here — putting the whole line
# in the CSV would push a capitalised proper noun through the lowercase-chrome
# check in test_localization.gd, which scans the CSV and knows nothing about
# names.
#
# Composing it in code costs the label its automatic re-translation, hence the
# _notification hook: a Label re-translates whatever sits in `text`, and what sits
# there is already-resolved text.
const AUTHOR: String = "Tomás Correa · 2026"


func _refresh_author() -> void:
	_author.text = "%s %s" % [tr("UI_ABOUT_BY"), AUTHOR]


func _notification(what: int) -> void:
	# Fires on every node in the tree when the locale changes (SceneTree
	# propagates it unconditionally), including before _ready on a node that is
	# still being set up — hence the guard.
	if what == NOTIFICATION_TRANSLATION_CHANGED and is_node_ready():
		_refresh_author()
		_refresh_language_row()


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
