extends SceneTree
## Renders the FTUE hint strip — every step in both locales, including the
## build step's four per-type variants — as stills.
##
## The strip is invisible to a plain screenshot of the game: TutorialController
## holds it until the opening cinematic has freed itself AND the run is ACTIVE,
## which means clicking through the language gate and waiting out the title. This
## builds the same UI directly instead.
##
## What to look for, i.e. the failures it exists to catch:
##   - Spanish must not clip. Every line here runs ~25% longer than the English
##     and the strip is 200px wide; the copy wraps (Label autowrap) and the panel
##     grows upward, so a clipped or overflowing line means the container chain
##     was broken back into a pinned rect.
##   - "página" must render with its accent. The strip uses the theme face
##     (Tiny5, full Spanish set), never Eggmode, which has no diacritics.
##   - The skip button sits in its own row UNDER the panel, centred, with clear
##     air between the two, in both locales — and must not push itself off the
##     bottom of the screen or drag the panel's width around when its own label
##     is the longer one ("mantén para saltar el tutorial").
##   - The build step's per-type line (ladder / bridge / fence / frailejon) is
##     the longest copy in the FTUE and the likeliest to overflow.
##   - The four NARRATIVE_* lines are full sentences and wrap to two or three
##     rows; the panel has to grow upward to hold them without leaving the crop.
##   - The skip button's hold fill must be a crisp whole-pixel column with the
##     label still readable through it (last state of each locale).
##
## Needs a rendering context — do NOT pass --headless.
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/preview_tutorial_strip.gd -- --out preview_out/
##
## Args:
##   --out <dir>    output directory (default: user://)

const VIEW_SIZE := Vector2i(480, 270)
const PIXEL_SCALE := 3
## The strip lives at the bottom; this crop is it plus room for a two-line wrap.
const CROP := Rect2i(120, 196, 240, 74)
## Palette P19 #546756 — stands in for the mountain behind the strip.
const BG := Color8(0x54, 0x67, 0x56, 0xFF)

const LOCALES: Array[String] = ["en_GB", "es_CO"]

const CONTROLLER_PATH := "res://scripts/ui/tutorial_controller.gd"

## The build step is rendered once per type it can name. Kept as plain data
## rather than read off _BUILD_KEYS so the output filenames stay stable.
const _BUILD_TYPES: Array[StringName] = [&"ladder", &"bridge", &"fence", &"frailejon"]

## The types placed with a SECOND click, rendered again on the endpoint step.
## The frailejon is absent: it has no second click, and its endpoint state would
## be the generic line over a step the real FTUE skips for it.
const _ENDPOINT_TYPES: Array[StringName] = [&"ladder", &"bridge", &"fence"]


## Stands in for TraversalPlacementController, which this tool has no scene to
## get one from. The endpoint step asks it whether a placement is open (it always
## is here, which is the state being previewed) and connects to its two signals.
class _FakePlacement extends Node:
	signal placement_began(kind: StringName)
	signal placement_ended(kind: StringName, built: bool)

	func is_placing() -> bool:
		return true

## Fraction of the skip hold to render the fill sweep at, for the one state that
## previews it. 0.6 so both edges of the bar are visible against the button.
const HOLD_PREVIEW: float = 0.6

var _out_dir: String = "user://"
var _vp: SubViewport
var _tutorial: CanvasLayer
var _frames: int = 0

# Loaded on the first _process frame, never named as `TutorialController` and
# never preloaded. The controller reads the SeasonManager autoload, and a
# --script tool is COMPILED before autoloads exist: a compile-time reference to
# the class (even just `TutorialController._STEPS`) fails the whole dependency
# chain with "Identifier not found: SeasonManager", and every later `.new()`
# then dies with "nonexistent function 'new'". Loading it at runtime, after the
# autoloads are up, is the way this project's tools touch autoload-aware code.
var _script: GDScript
var _steps: Array = []

## Frames per state: two to lay out (a container chain settles on the frame
## after the text is set) and one to let the fade tween reach full alpha.
const FRAMES_PER_STATE: int = 20
const CAPTURE_FRAME: int = FRAMES_PER_STATE - 1


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("preview_tutorial_strip needs a rendering context. Drop --headless.")
		quit(1)
		return

	var argv := OS.get_cmdline_user_args()
	for i in argv.size():
		if argv[i] == "--out" and i + 1 < argv.size():
			_out_dir = argv[i + 1]
	if not _out_dir.ends_with("/"):
		_out_dir += "/"
	DirAccess.make_dir_recursive_absolute(_out_dir)

	_vp = SubViewport.new()
	_vp.size = VIEW_SIZE
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.disable_3d = true
	_vp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	root.add_child(_vp)

	var bg_layer := CanvasLayer.new()
	bg_layer.layer = 0
	_vp.add_child(bg_layer)
	var bg := ColorRect.new()
	bg.size = Vector2(VIEW_SIZE)
	bg.color = BG
	bg_layer.add_child(bg)


func _process(_delta: float) -> bool:
	if _script == null:
		_script = load(CONTROLLER_PATH) as GDScript
		if _script == null:
			push_error("preview_tutorial_strip: could not load %s" % CONTROLLER_PATH)
			quit(1)
			return true
		_steps = _script.get_script_constant_map()["_STEPS"]

	var t: int = _frames
	_frames += 1
	var index: int = t / FRAMES_PER_STATE
	if index >= LOCALES.size() * _states_per_locale():
		quit(0)
		return true
	var locale: String = LOCALES[index / _states_per_locale()]
	var state: int = index % _states_per_locale()
	# The LAST state of each locale is the skip button mid-hold, shown over the
	# first step — it is the button being previewed here, not the copy.
	var holding: bool = state == _states_per_locale() - 1
	# States between the step list and that one are the build step re-shown per
	# bought type.
	var step: int = 0 if holding else mini(state, _steps.size() - 1)
	var bought: StringName = &""
	var label: String = ""
	if not holding and state >= _steps.size():
		# Two runs of per-type states after the step list: the build step once per
		# purchasable type, then the endpoint step once per type that has a second
		# click. Both re-show a SPECIFIC step rather than whatever the clamp above
		# landed on — without that they all rendered the last step (the closing
		# narrative), which is the one line that ignores _bought_type entirely, so
		# the states this tool exists to compare were copies of one picture.
		var extra: int = state - _steps.size()
		if extra < _BUILD_TYPES.size():
			bought = _BUILD_TYPES[extra]
			step = _step_index(&"build")
			label = "build_" + String(bought)
		else:
			bought = _ENDPOINT_TYPES[extra - _BUILD_TYPES.size()]
			step = _step_index(&"build_endpoint")
			label = "endpoint_" + String(bought)
	elif holding:
		label = "skip_hold"
	if label.is_empty():
		label = String(_steps[step]["id"])
	match t % FRAMES_PER_STATE:
		0:
			_build(locale, step, bought)
			if holding:
				_tutorial.set(&"_skip_hold", HOLD_PREVIEW * float(
						_script.get_script_constant_map()["_SKIP_HOLD"]))
		CAPTURE_FRAME:
			_capture("%s_%d_%s" % [locale, state, label])
	# The hold fill is sized off the button's live rect by the controller's
	# _tick_skip_hold, which is part of the _process this tool keeps stopped —
	# and the rect is only final after a layout pass, so this runs per frame
	# rather than once in _build.
	if _tutorial != null:
		_tutorial.call(&"_update_skip_fill")
	return false


# Where a step sits in _STEPS. Looked up by id rather than typed as a number:
# the step list is reordered whenever the FTUE is retuned.
func _step_index(id: StringName) -> int:
	for i in _steps.size():
		if _steps[i]["id"] == id:
			return i
	return _steps.size() - 1


## Every step once, then the build step per purchasable type, then the endpoint
## step per type with a second click, then the skip button mid-hold.
func _states_per_locale() -> int:
	return _steps.size() + _BUILD_TYPES.size() + _ENDPOINT_TYPES.size() + 1


func _build(locale: String, step: int, bought: StringName) -> void:
	# LocaleManager's _ready runs AFTER this script's _initialize and would
	# overwrite a locale set there (see CLAUDE.md), so the locale is applied
	# per state here, from _process, well after boot.
	TranslationServer.set_locale(locale)

	if _tutorial != null:
		_tutorial.queue_free()
		_tutorial = null

	_tutorial = _script.new()
	_vp.add_child(_tutorial)
	# The second-click step skips itself unless a placement is actually open, and
	# there is no placement controller here — this stub is the smallest thing
	# that answers its two questions (is one open, and the two signals it
	# connects to).
	var placement := _FakePlacement.new()
	_tutorial.add_child(placement)
	_tutorial.set(&"_traversal", placement)
	# _process is where the controller waits for the run to go ACTIVE; there is
	# no run here, so drive the two calls it would have made itself. Its own
	# _process is stopped so the wait can't fire a second time.
	_tutorial.set_process(false)
	_tutorial.visible = true
	# _show_step reads _bought_type to pick the build line; there is no shop
	# here to set it, so inject it first.
	_tutorial.set(&"_bought_type", bought)
	_tutorial.call(&"_show_step", step)
	# The strip fades in over 0.25 s and nothing else drives the alpha; jump it.
	var strip := _tutorial.get_node_or_null(^"StripAnchor/Column/Strip") as Control
	if strip != null:
		strip.modulate.a = 1.0
	var skip := _tutorial.get_node_or_null(^"Skip") as Control
	if skip != null:
		skip.modulate.a = 1.0


func _capture(name_: String) -> void:
	var img := _vp.get_texture().get_image()
	img.save_png("%stutorial_%s_full.png" % [_out_dir, name_])
	var crop := img.get_region(CROP)
	crop.resize(CROP.size.x * PIXEL_SCALE, CROP.size.y * PIXEL_SCALE,
		Image.INTERPOLATE_NEAREST)
	crop.save_png("%stutorial_%s_%dx.png" % [_out_dir, name_, PIXEL_SCALE])
	print("saved tutorial_%s" % name_)
