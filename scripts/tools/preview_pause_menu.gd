extends SceneTree
## Renders the pause modal's three views in both locales.
##
## The modal is pixel-pinned: Panel.custom_minimum_size IS the content box (the
## MarginContainer is anchored to the panel rect, not sized by it), so a view
## that outgrows it is drawn OUTSIDE the frame with no error, and a translation
## that outgrows a row is clipped with no error. test_locale_manager.gd measures
## both; this is how you look at the result. Saved states:
##
##   0_main_en / 1_main_es      settings column: volume, fullscreen, language, about
##   2_about_en / 3_about_es    credits + the licence links
##   4_confirm_en / 5_confirm_es the quit guard
##
## What to look for, i.e. the failures it exists to catch:
##   - Every row's glyphs inside its frame, in BOTH languages. Spanish runs ~25%
##     longer and "licencias de terceros" is the longest label in the panel.
##   - The About view must not push content under the Resume button, which is
##     anchored to the panel's bottom edge rather than being part of the stack.
##   - The author line's á and the middot must render, not tofu. The panel uses
##     the theme face (Tiny5, full Spanish set) — Eggmode would drop both.
##
## Needs a rendering context — do NOT pass --headless.
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/preview_pause_menu.gd -- --out preview_out/pause
##
## Args:
##   --out <dir>    output directory (default: user://)

const PAUSE_PATH := "res://scenes/ui/pause_menu.tscn"

const VIEW_SIZE := Vector2i(480, 270)
const PIXEL_SCALE := 3
## The panel is 184x150 centred in the 480x270 view, i.e. x 148..332, y 60..210.
## This crop is the panel plus a margin for the Resume button's overhang.
const CROP := Rect2i(138, 50, 204, 170)
## Palette P30 #14233A — stands in for the world behind the dim layer.
const BG := Color8(0x14, 0x23, 0x3A, 0xFF)

## name -> [locale, PauseMenu.View ordinal]
const STATES: Array[Array] = [
	["0_main_en", "en_GB", 0],
	["1_main_es", "es_CO", 0],
	["2_about_en", "en_GB", 2],
	["3_about_es", "es_CO", 2],
	["4_confirm_en", "en_GB", 1],
	["5_confirm_es", "es_CO", 1],
]

## Two frames of settle (the containers lay out on the frame after the view
## swap), then capture.
const FRAMES_PER_STATE: int = 4

var _out_dir: String = "user://"
var _vp: SubViewport
var _pause: CanvasLayer
var _frames: int = 0


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("preview_pause_menu needs a rendering context. Drop --headless.")
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

	var packed := load(PAUSE_PATH) as PackedScene
	if packed == null:
		push_error("preview_pause_menu: could not load %s" % PAUSE_PATH)
		quit(1)
		return
	_pause = packed.instantiate() as CanvasLayer
	_vp.add_child(_pause)


func _process(_delta: float) -> bool:
	var t: int = _frames
	_frames += 1
	var index: int = t / FRAMES_PER_STATE
	if index >= STATES.size():
		quit(0)
		return true
	match t % FRAMES_PER_STATE:
		0:
			_build(STATES[index])
		FRAMES_PER_STATE - 1:
			_capture(String(STATES[index][0]))
	return false


func _build(state: Array) -> void:
	# Shown by hand rather than through open(): open() pauses the tree, which
	# would stop this tool's own _process. It must happen HERE and not in
	# _initialize — the scene's _ready runs after that and sets visible = false.
	_pause.visible = true
	TranslationServer.set_locale(String(state[1]))
	# The language button's label is literal, not a key, so it does not follow
	# NOTIFICATION_TRANSLATION_CHANGED — the menu refreshes it off LocaleManager,
	# which this tool bypasses. Ask for it by hand.
	_pause.call(&"_refresh_language_label")
	_pause.call(&"_set_view", int(state[2]))


func _capture(name_: String) -> void:
	var img := _vp.get_texture().get_image()
	img.save_png("%spause_%s_full.png" % [_out_dir, name_])
	var crop := img.get_region(CROP)
	crop.save_png("%spause_%s.png" % [_out_dir, name_])
	# NEAREST upscale: at 1:1 the 8px rows are unreadable in a still.
	crop.resize(CROP.size.x * PIXEL_SCALE, CROP.size.y * PIXEL_SCALE,
		Image.INTERPOLATE_NEAREST)
	crop.save_png("%spause_%s_%dx.png" % [_out_dir, name_, PIXEL_SCALE])
	print("saved pause_%s" % name_)
