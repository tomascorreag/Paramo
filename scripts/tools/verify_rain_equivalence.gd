extends SceneTree
## Pixel-diff harness proving that assets/shaders/rain.gdshader is bit-identical
## to a reference copy of it across a sweep of uniform sets.
##
## WHY: rain.gdshader is heavily optimised (see its PERFORMANCE NOTES header).
## Every one of those optimisations is a claim that some branch is provably
## dead — a claim that is easy to get subtly wrong and nearly impossible to
## eyeball, because the difference would be a handful of splash pixels one
## frame in fifty. This harness turns the claim into a measurement.
##
## HOW: both shaders are rendered to SubViewports IN THE SAME FRAME, so their
## TIME built-in matches (that is the whole trick — you cannot compare across
## two runs, because TIME would differ and every drop would be somewhere else).
## The two textures are then read back and diffed byte-for-byte.
##
## A self-test case renders the reference against ITSELF first. If that ever
## reports a diff, the harness is broken (TIME desync, readback race, viewport
## config drift) and the real results mean nothing — fix the harness first.
##
## Requires a real rendering context: do NOT pass --headless.
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/verify_rain_equivalence.gd
##
## The reference shader defaults to res://scripts/tools/rain_reference.gdshader
## and is NOT kept in the repo (a frozen copy of the old shader would rot).
## Extract the revision you want to compare against first:
##
##   git show <rev>:assets/shaders/rain.gdshader > scripts/tools/rain_reference.gdshader
##
## Override the path with `-- --ref res://some/other.gdshader`.
## Exit code 0 = identical on every case, 1 = any diff or setup failure.

const NEW_SHADER_PATH := "res://assets/shaders/rain.gdshader"
const DEFAULT_REF_PATH := "res://scripts/tools/rain_reference.gdshader"
const VP_SIZE := Vector2i(480, 270)

# Frames to let a case settle before reading back. Setting a shader parameter
# in frame N lands in frame N's render; the readback needs the frame after.
# One spare frame on top of that, because a stale read here would show up as a
# false PASS (the two viewports would agree — on the previous case).
const SETTLE_FRAMES := 3

# Uniform sets to sweep. Anything that steers the culling logic gets pushed to
# both extremes: streak_angle (drives the sheared-column drift), splash_dwell
# and splash_size (drive the particle extents that gate the nest), splash_min_y
# (decides whether the row-below branch can ever fire), cell_height (decides how
# often the row-above branch fires), and column_spacing.
const CASES: Array[Dictionary] = [
	# The values rain.tscn actually ships — the case that matters most.
	{
		"name": "shipped (rain.tscn)",
		"rain_amount": 1.0, "column_spacing": 1.0, "cell_height": 270.0,
		"fall_speed": 220.0, "streak_length": 16.0, "streak_angle": -0.346,
		"splash_min_y": 0.05, "splash_dwell": 0.25, "splash_size": 2.0,
		"splash_probability": 1.0, "streak_alpha_variation": 1.0,
		"tint_intensity": 0.5,
	},
	{
		"name": "shader defaults",
		"rain_amount": 0.5, "column_spacing": 2.0, "cell_height": 270.0,
		"fall_speed": 220.0, "streak_length": 10.0, "streak_angle": 0.12,
		"splash_min_y": 0.25, "splash_dwell": 0.15, "splash_size": 1.0,
		"splash_probability": 1.0, "streak_alpha_variation": 0.5,
		"tint_intensity": 1.0,
	},
	# splash_min_y = 0 lets the row-below branch actually fire: a splash can sit
	# right on its own cell_top and ricochet up into the row above it.
	{
		"name": "splash_min_y=0 (row-below live)",
		"rain_amount": 1.0, "column_spacing": 1.0, "cell_height": 64.0,
		"fall_speed": 220.0, "streak_length": 16.0, "streak_angle": 0.0,
		"splash_min_y": 0.0, "splash_dwell": 0.5, "splash_size": 4.0,
		"splash_probability": 1.0, "streak_alpha_variation": 1.0,
		"tint_intensity": 0.5,
	},
	# Small cells + max particle extents: cell boundaries everywhere, so both
	# neighbour-row branches are exercised on a large share of pixels.
	{
		"name": "tiny cells, max splash",
		"rain_amount": 1.0, "column_spacing": 1.0, "cell_height": 32.0,
		"fall_speed": 400.0, "streak_length": 8.0, "streak_angle": 0.6,
		"splash_min_y": 0.05, "splash_dwell": 0.5, "splash_size": 4.0,
		"splash_probability": 1.0, "streak_alpha_variation": 0.5,
		"tint_intensity": 1.0,
	},
	{
		"name": "max negative angle",
		"rain_amount": 1.0, "column_spacing": 1.0, "cell_height": 270.0,
		"fall_speed": 220.0, "streak_length": 32.0, "streak_angle": -0.6,
		"splash_min_y": 0.05, "splash_dwell": 0.25, "splash_size": 2.0,
		"splash_probability": 1.0, "streak_alpha_variation": 1.0,
		"tint_intensity": 0.5,
	},
	# splash_dwell = 0 hits the max(0.001, ...) clamp and the degenerate
	# extents that fall out of it.
	{
		"name": "zero dwell / zero splash size",
		"rain_amount": 1.0, "column_spacing": 2.0, "cell_height": 270.0,
		"fall_speed": 220.0, "streak_length": 16.0, "streak_angle": 0.2,
		"splash_min_y": 0.5, "splash_dwell": 0.0, "splash_size": 0.0,
		"splash_probability": 1.0, "streak_alpha_variation": 1.0,
		"tint_intensity": 0.5,
	},
	# streak_length = 1 exercises the max(1.0, ...) floor in seg_len, which the
	# optimised pre-gate has to stay conservative against.
	{
		"name": "min streak length",
		"rain_amount": 1.0, "column_spacing": 1.0, "cell_height": 270.0,
		"fall_speed": 100.0, "streak_length": 1.0, "streak_angle": 0.0,
		"splash_min_y": 0.05, "splash_dwell": 0.25, "splash_size": 2.0,
		"splash_probability": 0.5, "streak_alpha_variation": 1.0,
		"tint_intensity": 0.5,
	},
	# Sparse rain: most columns die on the h_alive gate.
	{
		"name": "sparse rain",
		"rain_amount": 0.15, "column_spacing": 1.0, "cell_height": 270.0,
		"fall_speed": 220.0, "streak_length": 16.0, "streak_angle": -0.346,
		"splash_min_y": 0.05, "splash_dwell": 0.25, "splash_size": 2.0,
		"splash_probability": 1.0, "streak_alpha_variation": 1.0,
		"tint_intensity": 0.5,
	},
	# Lantern on — the hoisted lantern_factor / lit / lift_mul path.
	{
		"name": "lantern lit",
		"rain_amount": 1.0, "column_spacing": 1.0, "cell_height": 270.0,
		"fall_speed": 220.0, "streak_length": 16.0, "streak_angle": -0.346,
		"splash_min_y": 0.05, "splash_dwell": 0.25, "splash_size": 2.0,
		"splash_probability": 1.0, "streak_alpha_variation": 1.0,
		"tint_intensity": 0.5,
		"lantern_energy": 1.0, "lantern_pos_view": Vector2(240.0, 135.0),
		"lantern_radius_px": Vector2(256.0, 128.0),
	},
	# Camera pushed far from the origin: world_px gets large, which is where
	# float precision in the hashing and the cell_top math would show up.
	{
		"name": "camera far from origin",
		"rain_amount": 1.0, "column_spacing": 1.0, "cell_height": 270.0,
		"fall_speed": 220.0, "streak_length": 16.0, "streak_angle": -0.346,
		"splash_min_y": 0.05, "splash_dwell": 0.25, "splash_size": 2.0,
		"splash_probability": 1.0, "streak_alpha_variation": 1.0,
		"tint_intensity": 0.5, "camera_offset": Vector2(20000.0, -13000.0),
	},
]

var _ref_path: String = DEFAULT_REF_PATH
var _vp_a: SubViewport
var _vp_b: SubViewport
var _mat_a: ShaderMaterial  # reference
var _mat_b: ShaderMaterial  # optimised (or reference again, during self-test)

var _case_i: int = -1  # -1 = harness self-test, >=0 = index into CASES
var _wait: int = 0
var _failures: int = 0
var _checked: int = 0


func _initialize() -> void:
	for i in OS.get_cmdline_user_args().size() - 1:
		if OS.get_cmdline_user_args()[i] == "--ref":
			_ref_path = OS.get_cmdline_user_args()[i + 1]

	if DisplayServer.get_name() == "headless":
		push_error("verify_rain_equivalence needs a rendering context. Drop --headless.")
		quit(1)
		return

	var ref_shader := load(_ref_path) as Shader
	var new_shader := load(NEW_SHADER_PATH) as Shader
	if ref_shader == null:
		push_error("Could not load reference shader at %s.\n"
			% _ref_path
			+ "Produce one with:\n"
			+ "  git show <rev>:assets/shaders/rain.gdshader > scripts/tools/rain_reference.gdshader")
		quit(1)
		return
	if new_shader == null:
		push_error("Could not load %s" % NEW_SHADER_PATH)
		quit(1)
		return

	_mat_a = ShaderMaterial.new()
	_mat_a.shader = ref_shader
	_mat_b = ShaderMaterial.new()
	# Self-test first: reference vs reference must be identical. Swapped to the
	# optimised shader once that passes.
	_mat_b.shader = ref_shader

	_vp_a = _make_viewport(_mat_a)
	_vp_b = _make_viewport(_mat_b)
	root.add_child(_vp_a)
	root.add_child(_vp_b)

	print("rain shader equivalence")
	print("  reference: %s" % _ref_path)
	print("  candidate: %s" % NEW_SHADER_PATH)
	print("  viewport:  %dx%d" % [VP_SIZE.x, VP_SIZE.y])
	print("")
	_apply(_self_test_uniforms())
	_wait = SETTLE_FRAMES


func _make_viewport(mat: ShaderMaterial) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = VP_SIZE
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.disable_3d = true
	var rect := ColorRect.new()
	rect.size = Vector2(VP_SIZE)
	rect.color = Color(0, 0, 0, 0)
	rect.material = mat
	vp.add_child(rect)
	return vp


# The self-test deliberately uses a busy configuration: dense rain, big
# splashes, sheared columns. If TIME were desyncing between the two viewports
# this is where it would show.
func _self_test_uniforms() -> Dictionary:
	return CASES[0]


func _apply(case: Dictionary) -> void:
	var defaults := {
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
		"viewport_size": Vector2(VP_SIZE),
		"camera_offset": Vector2.ZERO,
		"lantern_pos_view": Vector2(-9999, -9999),
		"lantern_radius_px": Vector2(256, 128),
		"lantern_energy": 0.0,
		"lantern_color": Color(1, 0.725, 0.45, 1),
		"lantern_color_mix": 0.6,
		"lantern_lift_gain": 1.5,
	}
	for key: String in defaults:
		var value: Variant = case.get(key, defaults[key])
		_mat_a.set_shader_parameter(key, value)
		_mat_b.set_shader_parameter(key, value)


func _process(_delta: float) -> bool:
	if _wait > 0:
		_wait -= 1
		return false

	var label: String = ("harness self-test (ref vs ref)" if _case_i < 0
		else CASES[_case_i]["name"])
	var ok := _compare(label)

	if _case_i < 0:
		if not ok:
			print("")
			print("HARNESS BROKEN: the reference shader does not match itself.")
			print("The two SubViewports are not rendering at the same TIME, or the")
			print("readback is racing. Every result below would be meaningless.")
			quit(1)
			return true
		# Self-test passed — swap in the real candidate.
		_mat_b.shader = load(NEW_SHADER_PATH) as Shader
		print("")

	_case_i += 1
	if _case_i >= CASES.size():
		_report()
		return true

	_apply(CASES[_case_i])
	_wait = SETTLE_FRAMES
	return false


func _compare(label: String) -> bool:
	var img_a := _vp_a.get_texture().get_image()
	var img_b := _vp_b.get_texture().get_image()
	if img_a == null or img_b == null:
		push_error("Viewport readback returned null")
		_failures += 1
		return false
	if img_a.get_size() != img_b.get_size() or img_a.get_format() != img_b.get_format():
		push_error("Viewport format/size mismatch — harness misconfigured")
		_failures += 1
		return false

	var a := img_a.get_data()
	var b := img_b.get_data()
	var diff_bytes := 0
	var max_delta := 0
	for i in a.size():
		var d: int = absi(a[i] - b[i])
		if d > 0:
			diff_bytes += 1
			max_delta = maxi(max_delta, d)

	# Non-transparent byte count, so a "pass" on an empty frame is obvious
	# rather than looking like a clean result.
	var lit_px := 0
	for i in range(3, a.size(), 4):
		if a[i] > 0:
			lit_px += 1

	_checked += 1
	var ok := diff_bytes == 0
	if not ok:
		_failures += 1
	print("  %s  %-34s  drawn_px=%-6d diff_bytes=%-7d max_delta=%d"
		% ["PASS" if ok else "FAIL", label, lit_px, diff_bytes, max_delta])
	if lit_px == 0:
		print("         ^ WARNING: reference drew nothing — this case proves nothing.")
	return ok


func _report() -> void:
	print("")
	if _failures == 0:
		print("PASS — %d/%d cases pixel-identical." % [_checked, _checked])
		quit(0)
	else:
		print("FAIL — %d/%d cases differ." % [_failures, _checked])
		quit(1)
