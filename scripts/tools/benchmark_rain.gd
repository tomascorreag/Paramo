extends SceneTree
## GPU cost benchmark for assets/shaders/rain.gdshader.
##
## Renders the shader alone into a large SubViewport with vsync off and no other
## scene content, so frame time is essentially the rain pass. Reports ms/frame.
##
## Pass `--ref <res://path>` to also time a second shader and print the speedup
## ratio — the two are timed in separate phases, never concurrently, so they
## don't contend for the GPU.
##
## BENCH_SIZE is NOT an artificial blow-up of a 480x270 game. The project uses
## `canvas_items` stretch, which renders at the WINDOW resolution and only keeps
## the logical canvas at 480x270 (DisplayManager then locks an integer scale by
## setting content_scale_size = window/N). Verified at runtime: at a 1440x810
## window the root Viewport.size is 1440x810, so a fullscreen pass is 1.17M
## fragments — and 2.07M at 1080p fullscreen. So 1920x1080 here is roughly a
## real fullscreen frame, not a synthetic one.
##
## Cost is linear in pixel count, so the RATIO between two shaders is the
## meaningful output; the absolute ms is for this GPU and does not transfer to a
## weaker/web target.
##
## The viewport_size uniform is set to BENCH_SIZE (not the game's 480x270) so
## world_px stays 1:1 with screen pixels. If it were left at 480x270 each world
## pixel would cover a block of screen pixels, making neighbouring fragments
## take identical branches — that artificial coherence would flatter the result.
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/benchmark_rain.gd \
##       -- --ref res://scripts/tools/rain_reference.gdshader

const SHADER_PATH := "res://assets/shaders/rain.gdshader"
const BENCH_SIZE := Vector2i(1920, 1080)
const WARMUP_FRAMES := 90
const TIMED_FRAMES := 240

# The uniforms rain.tscn actually ships. Benchmarking the shader defaults would
# understate the cost: rain_amount=1.0 is the worst case (h_alive culls nothing)
# and column_spacing=1.0 is twice the column count of the default 2.0.
const SHIPPED := {
	"rain_color": Color(0.7505, 0.820325, 0.95, 0.78431374),
	"tint_color": Color(1, 1, 1, 1),
	"tint_intensity": 0.5,
	"additive_boost": 0.15,
	"rain_amount": 1.0,
	"column_spacing": 1.0,
	"cell_height": 270.0,
	"fall_speed": 220.0,
	"streak_length": 16.0,
	"streak_angle": -0.346,
	"splash_min_y": 0.05,
	"splash_dwell": 0.25,
	"splash_size": 2.0,
	"splash_probability": 1.0,
	"streak_alpha_variation": 1.0,
	"camera_offset": Vector2.ZERO,
	"lantern_pos_view": Vector2(-9999, -9999),
	"lantern_radius_px": Vector2(256, 128),
	"lantern_energy": 0.0,
	"lantern_color": Color(1, 0.725, 0.45, 1),
	"lantern_color_mix": 0.6,
	"lantern_lift_gain": 1.5,
}

var _phases: Array[Dictionary] = []
var _phase_i: int = 0
var _frame: int = 0
var _t0: int = 0
var _vp: SubViewport
var _rect: ColorRect


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("benchmark_rain needs a rendering context. Drop --headless.")
		quit(1)
		return

	var ref_path := ""
	var argv := OS.get_cmdline_user_args()
	for i in argv.size() - 1:
		if argv[i] == "--ref":
			ref_path = argv[i + 1]

	var candidate := load(SHADER_PATH) as Shader
	if candidate == null:
		push_error("Could not load %s" % SHADER_PATH)
		quit(1)
		return

	if ref_path != "":
		var ref := load(ref_path) as Shader
		if ref == null:
			push_error("Could not load reference shader at %s" % ref_path)
			quit(1)
			return
		_phases.append({"name": "reference", "shader": ref})
	_phases.append({"name": "candidate", "shader": candidate})

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	_vp = SubViewport.new()
	_vp.size = BENCH_SIZE
	_vp.transparent_bg = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.disable_3d = true
	_rect = ColorRect.new()
	_rect.size = Vector2(BENCH_SIZE)
	_rect.color = Color(0, 0, 0, 0)
	_vp.add_child(_rect)
	root.add_child(_vp)

	print("rain shader benchmark")
	print("  device:  %s" % RenderingServer.get_video_adapter_name())
	# Compared against a 1080p fullscreen frame, NOT against 480x270 — see the
	# canvas_items note in the header.
	print("  size:    %dx%d (%.2fx a 1080p fullscreen frame)"
		% [BENCH_SIZE.x, BENCH_SIZE.y,
			float(BENCH_SIZE.x * BENCH_SIZE.y) / float(1920 * 1080)])
	print("  uniforms: rain.tscn shipped values (rain_amount=1.0 worst case)")
	print("")
	_begin_phase()


func _begin_phase() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = _phases[_phase_i]["shader"]
	for key: String in SHIPPED:
		mat.set_shader_parameter(key, SHIPPED[key])
	mat.set_shader_parameter("viewport_size", Vector2(BENCH_SIZE))
	_rect.material = mat
	_frame = 0


func _process(_delta: float) -> bool:
	_frame += 1
	# Warmup covers shader compile plus driver/clock ramp; timing starts only
	# once the pipeline is hot.
	if _frame == WARMUP_FRAMES:
		_t0 = Time.get_ticks_usec()
		return false
	if _frame < WARMUP_FRAMES + TIMED_FRAMES:
		return false

	var elapsed := Time.get_ticks_usec() - _t0
	_phases[_phase_i]["ms"] = (float(elapsed) / 1000.0) / float(TIMED_FRAMES)
	print("  %-10s %7.3f ms/frame" % [_phases[_phase_i]["name"], _phases[_phase_i]["ms"]])

	_phase_i += 1
	if _phase_i >= _phases.size():
		_report()
		return true
	_begin_phase()
	return false


func _report() -> void:
	if _phases.size() == 2:
		var ref_ms: float = _phases[0]["ms"]
		var new_ms: float = _phases[1]["ms"]
		print("")
		print("  speedup: %.2fx  (%.1f%% of the shader pass removed)"
			% [ref_ms / maxf(new_ms, 0.0001), (1.0 - new_ms / maxf(ref_ms, 0.0001)) * 100.0])
	quit(0)
