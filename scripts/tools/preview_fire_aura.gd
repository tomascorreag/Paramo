extends SceneTree
## Renders the off-screen-fire aura (assets/shaders/fire_aura.gdshader +
## scripts/vfx/fire_aura_overlay.gd) to PNGs so the edge glow can be eyeballed
## without launching the game and walking the camera off a real fire.
##
## The aura is a SCREEN-SPACE effect keyed off where fires land relative to the
## camera, so — like the blob fire — the only way to know what it looks like is to
## render it. This harness builds a viewport with a Camera2D at the origin, drops
## a few stand-in "fires" (Node2D in the fire_vfx group exposing get_intensity)
## at chosen world bearings, and drives a FireAuraOverlay over a dark background.
##
## It captures three phases of a PROBE fire to prove the brief:
##   0 far     probe far off the right edge  -> faint, thin glow (proximity low)
##   1 near    probe just off the right edge  -> bright, thick glow (proximity high)
##   2 onscreen probe walked into the frame   -> glow gone (fades as it enters)
## Two static context fires (top edge, left edge) sit through all three so you can
## see distinct directions light distinct edges and that they don't interfere.
##
## Needs a rendering context — do NOT pass --headless.
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/preview_fire_aura.gd -- --out /tmp/aura
##
## Args:
##   --out <dir>     output directory (default: user://)
##   --settle <n>    engine frames to let the temporal smoothing settle per phase
##                   (default 45; fps is pinned to 60 so this is ~0.75s)

const OVERLAY_SCRIPT: GDScript = preload("res://scripts/vfx/fire_aura_overlay.gd")
const AURA_MAT: ShaderMaterial = preload("res://resources/materials/fire_aura.tres")

const VIEW_SIZE := Vector2i(320, 240)
const PIXEL_SCALE := 2
# Palette P30 #14233A — the darkest entry, what the game sits on at night. The
# aura is additive, so it needs a dark bed to read against.
const BG := Color(0.078431375, 0.13725491, 0.22745098, 1.0)

# Probe world-X per phase (camera at origin, zoom 1 => view spans x in [-160, 160]).
# far off-right, just off-right, then inside the frame.
const PHASES: Array = [
	{"label": "0_far", "probe_x": 430.0},
	{"label": "1_near", "probe_x": 180.0},
	{"label": "2_onscreen", "probe_x": 60.0},
]

var _out_dir: String = "user://"
var _settle: int = 45
var _vp: SubViewport
var _probe: Node2D
var _phase: int = 0
var _frame_in_phase: int = 0


# Stand-in for BurningCellVFX: the overlay only needs a Node2D in the fire_vfx
# group answering get_intensity(). global_position comes from Node2D.
class FakeFire extends Node2D:
	var intensity: float = 1.0
	func _init(i: float) -> void:
		intensity = i
		add_to_group(&"fire_vfx")
	func get_intensity() -> float:
		return intensity


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("preview_fire_aura needs a rendering context. Drop --headless.")
		quit(1)
		return

	var argv := OS.get_cmdline_user_args()
	for i in argv.size() - 1:
		match argv[i]:
			"--out": _out_dir = argv[i + 1]
			"--settle": _settle = int(argv[i + 1])
	if not _out_dir.ends_with("/"):
		_out_dir += "/"
	# save_png needs the directory to exist.
	DirAccess.make_dir_recursive_absolute(_out_dir)

	# Pin fps so the temporal smoothing settles in a predictable frame count
	# (a=1-exp(-dt/tau) crawls if dt is a sub-millisecond vsync-off frame).
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 60

	_vp = SubViewport.new()
	_vp.size = VIEW_SIZE
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.disable_3d = true
	root.add_child(_vp)

	# Dark background on a screen-space CanvasLayer (below the aura's layer).
	var bg_layer := CanvasLayer.new()
	bg_layer.layer = 0
	_vp.add_child(bg_layer)
	var bg := ColorRect.new()
	bg.size = Vector2(VIEW_SIZE)
	bg.color = BG
	bg_layer.add_child(bg)

	# Camera at the origin drives the viewport's canvas transform — the overlay
	# reads exactly this to project each fire into screen space.
	# An enabled Camera2D auto-becomes current on entering the tree, which is what
	# drives the viewport's canvas transform (world -> screen, origin centred).
	var cam := Camera2D.new()
	cam.position = Vector2.ZERO
	_vp.add_child(cam)

	# The aura overlay on its own screen-space CanvasLayer, as in gameplay_base.
	var aura_layer := CanvasLayer.new()
	aura_layer.layer = 105
	_vp.add_child(aura_layer)
	var aura := ColorRect.new()
	aura.set_script(OVERLAY_SCRIPT)
	aura.material = AURA_MAT
	aura.size = Vector2(VIEW_SIZE)
	aura_layer.add_child(aura)

	# Static context fires: one off the top edge, one off the left edge.
	var top_fire := FakeFire.new(0.6)
	top_fire.position = Vector2(0.0, -260.0)
	_vp.add_child(top_fire)
	var left_fire := FakeFire.new(0.4)
	left_fire.position = Vector2(-260.0, 0.0)
	_vp.add_child(left_fire)

	# The probe whose X we sweep across phases.
	_probe = FakeFire.new(0.9)
	_probe.position = Vector2(PHASES[0]["probe_x"], 0.0)
	_vp.add_child(_probe)

	print("fire_aura preview")
	print("  device:  %s" % RenderingServer.get_video_adapter_name())
	print("  view:    %dx%d, camera at origin (zoom 1)" % [VIEW_SIZE.x, VIEW_SIZE.y])
	print("  context: top fire i=0.6, left fire i=0.4 (static)")
	print("  probe:   i=0.9, swept right->inside across %d phases" % PHASES.size())
	print("  out:     %s (%dx upscaled, NEAREST)" % [_out_dir, PIXEL_SCALE])
	print("")


func _process(_delta: float) -> bool:
	_frame_in_phase += 1
	if _frame_in_phase < _settle:
		return false

	var phase: Dictionary = PHASES[_phase]
	var img: Image = _vp.get_texture().get_image()
	img.resize(VIEW_SIZE.x * PIXEL_SCALE, VIEW_SIZE.y * PIXEL_SCALE, Image.INTERPOLATE_NEAREST)
	var path: String = "%sfire_aura_%s.png" % [_out_dir, phase["label"]]
	var err: int = img.save_png(path)
	if err != OK:
		push_error("save_png failed (%d) for %s" % [err, path])
		quit(1)
		return true
	print("  saved %s (probe_x=%.0f)" % [path, float(phase["probe_x"])])

	_phase += 1
	if _phase >= PHASES.size():
		quit(0)
		return true
	# Advance to the next phase and let the smoothing re-settle.
	_probe.position = Vector2(float(PHASES[_phase]["probe_x"]), 0.0)
	_frame_in_phase = 0
	return false
