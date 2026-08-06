extends SceneTree
## Renders the title screen's LANGUAGE GATE — the two boxes (español/colombia,
## english/uk) that replaced the old "click to begin" prompt.
##
## The gate is invisible to any plain screenshot of the scene: title_intro.gd
## hides everything until ProceduralWorld reports generation_finished, and each
## box's alpha is then driven per frame by how close the mouse is to THAT box. So
## the only way to see what a player sees is to activate the gate and drive a
## cursor at it, which is what this does. Saved states:
##
##   0_idle        cursor far away        — both boxes at their floor alpha
##   1_hover_es    cursor over the left   — español lit, english still dim
##   2_hover_en    cursor over the right  — the mirror image
##   3_preselect   a saved locale exists  — that box carries a raised floor alpha
##                                          and the accent frame, WITHOUT being
##                                          pre-clicked (the player is still asked)
##
## What to look for, i.e. the failures it exists to catch:
##   - Approaching one box must light ONLY that box. If both ramp together the
##     per-box proximity has regressed to the old single-prompt behaviour and the
##     boxes stop reading as a choice.
##   - "español" must render with its ñ. The gate uses the theme face (Tiny5,
##     which has the full Spanish set); Eggmode does NOT, so if this ever moves to
##     the title face the ñ turns to tofu.
##   - The pre-selected box must look MARKED, not CHOSEN — clearly different from
##     the hover state, or players will think the game already decided for them.
##
## Needs a rendering context — do NOT pass --headless.
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/preview_language_gate.gd -- --out /tmp/gate
##
## Args:
##   --out <dir>    output directory (default: user://)

const TITLE_PATH := "res://scenes/ui/title_intro.tscn"

const VIEW_SIZE := Vector2i(480, 270)
const PIXEL_SCALE := 4
## The boxes sit 40..88 below screen centre, i.e. y 175..223 of the 270-tall
## view, spanning x 136..344. This crop is those boxes plus a margin.
const CROP := Rect2i(120, 160, 240, 76)
## Palette P30 #14233A — stands in for the night world behind the gate.
const BG := Color8(0x14, 0x23, 0x3A, 0xFF)

## Well clear of both boxes (they occupy y 175..223), so the proximity ramp sits
## at its floor. It has to be an explicit position, not "leave the cursor alone":
## the viewport remembers where the previous state put it, and a parked cursor
## silently hovers the next state's render.
const CURSOR_AWAY := Vector2(240, 20)

## name -> [saved locale (empty = first-ever launch), cursor position]
const STATES: Array[Array] = [
	["0_idle", "", CURSOR_AWAY],
	["1_hover_es", "", Vector2(190, 199)],
	["2_hover_en", "", Vector2(290, 199)],
	["3_preselect", "es_CO", CURSOR_AWAY],
]

var _out_dir: String = "user://"
var _vp: SubViewport
var _title: CanvasLayer
var _frames: int = 0
var _state: int = -1


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("preview_language_gate needs a rendering context. Drop --headless.")
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
	# The gate reads the mouse every frame; without this the SubViewport never
	# sees the motion events pushed into it and both boxes stay at their floor.
	_vp.handle_input_locally = true
	root.add_child(_vp)

	var bg_layer := CanvasLayer.new()
	bg_layer.layer = 0
	_vp.add_child(bg_layer)
	var bg := ColorRect.new()
	bg.size = Vector2(VIEW_SIZE)
	bg.color = BG
	bg_layer.add_child(bg)


## Frames spent on each state. The gate ramps each box's alpha with EXPONENTIAL
## smoothing (prompt_track_speed 10, so ~15% of the remaining gap per frame at
## 60fps): a couple of frames after the cursor moves lands mid-ramp, and the
## still then understates how much brighter the hovered box gets. 40 frames is
## comfortably converged.
const FRAMES_PER_STATE: int = 40
## Frame within a state at which the cursor is placed — early, so the rest of the
## budget is ramp time.
const AIM_FRAME: int = 2


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
		AIM_FRAME:
			_aim(STATES[index][2])
		FRAMES_PER_STATE - 1:
			_capture(STATES[index][0])
	return false


func _build(state: Array) -> void:
	if _title != null:
		_title.queue_free()
		_title = null
	# The saved locale is read once in _ready, so it has to be written before the
	# scene is instantiated — hence a fresh instance per state.
	_write_saved_locale(state[1])

	var packed := load(TITLE_PATH) as PackedScene
	if packed == null:
		push_error("preview_language_gate: could not load %s" % TITLE_PATH)
		quit(1)
		return
	_title = packed.instantiate() as CanvasLayer
	_vp.add_child(_title)
	# No ProceduralWorld in the tree, so title_intro.gd takes its "handcrafted map"
	# path and activates the gate itself. Nothing else to drive.


func _write_saved_locale(code: String) -> void:
	var cfg := ConfigFile.new()
	if code.is_empty():
		DirAccess.remove_absolute("user://settings.cfg")
	else:
		cfg.set_value("locale", "code", code)
		cfg.save("user://settings.cfg")
	# LocaleManager cached the old value at boot; re-read so the gate marks the
	# box this state is about.
	var lm := root.get_node_or_null(^"LocaleManager")
	if lm != null:
		lm.call(&"_read_saved")
		lm.set(&"_saved", code)


func _aim(at: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = at
	motion.global_position = at
	_vp.push_input(motion, true)


func _capture(name_: String) -> void:
	var img := _vp.get_texture().get_image()
	img.save_png("%sgate_%s_full.png" % [_out_dir, name_])
	var crop := img.get_region(CROP)
	crop.save_png("%sgate_%s.png" % [_out_dir, name_])
	# NEAREST upscale: at 1:1 the 8px region subtitle is unreadable in a still.
	crop.resize(CROP.size.x * PIXEL_SCALE, CROP.size.y * PIXEL_SCALE,
		Image.INTERPOLATE_NEAREST)
	crop.save_png("%sgate_%s_%dx.png" % [_out_dir, name_, PIXEL_SCALE])
	print("saved gate_%s" % name_)
