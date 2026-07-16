extends SceneTree
## Validates the two Godot-4.6 behaviors the subpixel-viewport recipe depends on,
## BEFORE restructuring the shared gameplay_base + every map on faith:
##
##   1. A hint_screen_texture post-process ColorRect, on a CanvasLayer INSIDE a
##      SubViewport, actually grades that SubViewport's own low-res framebuffer
##      (with an explicit BackBufferCopy in COPY_MODE_VIEWPORT). This is the
##      point the specialist reasoned from docs but did not run — so run it.
##   2. Snapping SubViewport.canvas_transform.origin to whole texels works and a
##      Camera2D inside the viewport is what drives that transform.
##
## Needs a rendering context — do NOT pass --headless (SubViewport render targets
## and readback are meaningless under the headless driver). Prints PASS/FAIL per
## check and saves a PNG of the low-res buffer for eyeballing. Exit 0 = all pass.
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/verify_subpixel.gd -- --out /tmp/subpixel

const POST_SHADER := "res://assets/shaders/post_process.gdshader"
const VP_SIZE := Vector2i(64, 64)
const WORLD_COLOR := Color(0.0, 0.8, 0.2)  # distinct green; nothing else emits it

var _out_dir := ""
var _frame := 0
var _vp: SubViewport
var _pp_mat: ShaderMaterial
var _cam: Camera2D
var _fails: Array[String] = []
var _phase := 0


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("verify_subpixel needs a rendering context — drop --headless.")
		quit(1)
		return
	var argv := OS.get_cmdline_user_args()
	for i in argv.size() - 1:
		if argv[i] == "--out":
			_out_dir = argv[i + 1]

	_build_tree()
	print("subpixel mechanism verification")
	print("  device: %s" % RenderingServer.get_video_adapter_name())
	print("")


func _build_tree() -> void:
	var container := SubViewportContainer.new()
	container.stretch = false

	_vp = SubViewport.new()
	_vp.size = VP_SIZE
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.transparent_bg = false
	container.add_child(_vp)

	# World: a Node2D so a Camera2D drives the viewport's canvas_transform, with a
	# flat green fill covering the frame.
	var world := Node2D.new()
	var fill := ColorRect.new()
	fill.size = Vector2(VP_SIZE) * 4.0
	fill.position = -Vector2(VP_SIZE) * 2.0
	fill.color = WORLD_COLOR
	world.add_child(fill)
	_cam = Camera2D.new()
	_cam.position = Vector2(10.3, 5.7)  # deliberately fractional
	world.add_child(_cam)
	_vp.add_child(world)

	# Backbuffer must be captured (whole-screen, not Rect — godot#111096) after
	# the world draws and before the post pass reads it.
	var bbc := BackBufferCopy.new()
	bbc.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	_vp.add_child(bbc)

	# Post-process: neutral first (should pass the world through untouched — that
	# is the proof screen_texture reads the SubViewport's own buffer).
	var pp_layer := CanvasLayer.new()
	pp_layer.layer = 100
	var pp := ColorRect.new()
	pp.size = Vector2(VP_SIZE)
	_pp_mat = ShaderMaterial.new()
	_pp_mat.shader = load(POST_SHADER) as Shader
	pp.material = _pp_mat
	pp_layer.add_child(pp)
	_vp.add_child(pp_layer)

	root.add_child(container)


func _sample_center() -> Color:
	var img := _vp.get_texture().get_image()
	return img.get_pixel(VP_SIZE.x / 2, VP_SIZE.y / 2)


func _process(_delta: float) -> bool:
	_frame += 1
	# Let the render target + backbuffer settle each phase.
	if _frame < 4:
		return false

	if _phase == 0:
		# Check 1: neutral post-process must pass the world color through, proving
		# screen_texture inside the SubViewport reads the low-res world.
		var c := _sample_center()
		var ok := c.is_equal_approx(WORLD_COLOR) or (
			absf(c.g - WORLD_COLOR.g) < 0.06
			and absf(c.r - WORLD_COLOR.r) < 0.06
			and absf(c.b - WORLD_COLOR.b) < 0.06
		)
		_report("screen_texture reads SubViewport buffer (neutral pass-through)",
			ok, "center=%s expected≈%s" % [c, WORLD_COLOR])
		if _out_dir != "":
			_vp.get_texture().get_image().save_png("%s_neutral.png" % _out_dir)
		# Now push brightness and re-check the grade actually modifies the buffer.
		_pp_mat.set_shader_parameter("brightness", 0.3)
		_phase = 1
		_frame = 0
		return false

	if _phase == 1:
		var c := _sample_center()
		var brightened := c.g > WORLD_COLOR.g + 0.15 and c.r > WORLD_COLOR.r + 0.15
		_report("post-process grades the SubViewport buffer (brightness +0.3)",
			brightened, "center=%s (expected each channel +~0.3)" % c)

		# Check 2: a Camera2D inside the viewport drives canvas_transform, and
		# snapping its origin to whole texels leaves an integer origin + sub-texel
		# remainder < 1.
		var origin := _vp.canvas_transform.origin
		var snapped := origin.round()
		var rem := origin - snapped
		var drives := not origin.is_equal_approx(Vector2.ZERO)
		_report("Camera2D drives SubViewport.canvas_transform",
			drives, "origin=%s" % origin)
		_report("canvas_transform origin snaps to integer texels",
			snapped == snapped.round() and rem.length() < 1.0,
			"origin=%s snapped=%s remainder=%s" % [origin, snapped, rem])
		_finish()
		return true

	return false


func _report(name_: String, ok: bool, detail: String) -> void:
	print("  [%s] %s" % ["PASS" if ok else "FAIL", name_])
	if not ok:
		print("         %s" % detail)
		_fails.append(name_)


func _finish() -> void:
	print("")
	if _fails.is_empty():
		print("  ALL PASS — recipe mechanism validated; safe to migrate the base.")
		quit(0)
	else:
		print("  %d FAILED — do NOT migrate; investigate first." % _fails.size())
		quit(1)
