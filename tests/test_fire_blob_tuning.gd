extends GutTest

# Guards FireBlobTuning — the pure math behind the procedural blob fire. The
# shader itself can only be verified by looking at it (see
# scripts/tools/benchmark_fire.gd and the shader_debug modes), so this file is
# where the SPEC gets held:
#
#   - an isolated ignition never outgrows kindling, at any burn amount;
#   - kindling is literally a couple of lit pixels;
#   - the quad always contains the field the shader can draw (fire_blobs.gdshader
#     has NO spatial bound of its own — the quad IS the bound, so undersizing it
#     clips blobs silently).

const RAMP_MATERIAL: String = "res://resources/materials/fire_blobs.tres"


# --- Intensity ---------------------------------------------------------------

func test_no_fire_at_zero_burn() -> void:
	assert_eq(FireBlobTuning.intensity(0.0, 0), 0.0, "a just-lit cell has no blobs yet")
	assert_eq(FireBlobTuning.intensity(0.0, 4), 0.0, "neighbours don't fake a burn that hasn't started")


func test_isolated_fire_never_outgrows_kindling() -> void:
	# THE load-bearing spec claim: burn amount alone must never make a lone
	# ignition big. If this ever fails, a single fire on an empty hillside grows
	# a full wildfire plume.
	for i: int in range(0, 101):
		var a: float = float(i) / 100.0
		assert_lte(
			FireBlobTuning.intensity(a, 0),
			FireBlobTuning.ISOLATED_CAP,
			"isolated fire at amount %.2f exceeded ISOLATED_CAP" % a)


func test_spreading_front_is_always_bigger_than_isolated() -> void:
	# Sample inside the envelope's live range; at amount 0 both are 0.
	for i: int in range(1, 101):
		var a: float = float(i) / 100.0
		assert_gt(
			FireBlobTuning.intensity(a, 4),
			FireBlobTuning.intensity(a, 0),
			"a surrounded cell must out-burn an isolated one at amount %.2f" % a)


func test_intensity_is_monotonic_in_neighbours() -> void:
	for n: int in range(0, 4):
		assert_lte(
			FireBlobTuning.intensity(0.5, n),
			FireBlobTuning.intensity(0.5, n + 1),
			"intensity must not drop as neighbour count rises (%d -> %d)" % [n, n + 1])


func test_intensity_clamps_out_of_range_inputs() -> void:
	assert_eq(FireBlobTuning.intensity(5.0, 99), FireBlobTuning.intensity(1.0, 4))
	assert_eq(FireBlobTuning.intensity(-5.0, -99), FireBlobTuning.intensity(0.0, 0))


func test_size_envelope_peaks_mid_burn_and_falls_to_embers() -> void:
	var peak: float = FireBlobTuning.size_envelope(0.5)
	assert_gt(peak, FireBlobTuning.size_envelope(0.05), "should be ramping up early")
	assert_gt(peak, FireBlobTuning.size_envelope(1.0), "should be dying back at burn-out")
	assert_lt(FireBlobTuning.size_envelope(1.0), 0.5, "embers, not a full fire")


# --- Kindling read -----------------------------------------------------------

func test_kindling_is_a_couple_of_lit_pixels() -> void:
	var u: Dictionary = FireBlobTuning.uniforms_for(0.0)
	# The shader samples the blob field at integer pixels, so a max radius under
	# ~1.5px lights 1-3 texels. This is the "kindling" requirement, in numbers.
	assert_lte(float(u[&"blob_max_radius"]), 1.5, "kindling blobs must be pixel-scale")
	assert_eq(int(u[&"slot_count"]), 1, "kindling is a single blob stream")
	assert_lte(float(u[&"k_active"]), 3.0, "kindling column must stay sparse")


func test_wildfire_is_substantially_bigger_than_kindling() -> void:
	var lo: Dictionary = FireBlobTuning.uniforms_for(0.0)
	var hi: Dictionary = FireBlobTuning.uniforms_for(1.0)
	assert_gt(float(hi[&"blob_max_radius"]), float(lo[&"blob_max_radius"]) * 3.0)
	assert_gt(float(hi[&"column_height"]), float(lo[&"column_height"]) * 3.0)
	assert_gt(int(hi[&"slot_count"]), int(lo[&"slot_count"]))


# --- Shader contracts --------------------------------------------------------

func test_slot_count_never_exceeds_shader_loop_bound() -> void:
	# fire_blobs.gdshader breaks its slot loop at SLOT_MAX; a higher slot_count
	# would be silently ignored rather than erroring.
	for i: int in range(0, 101):
		var u: Dictionary = FireBlobTuning.uniforms_for(float(i) / 100.0)
		assert_between(int(u[&"slot_count"]), 1, FireBlobTuning.SLOT_MAX)


func test_k_active_never_exceeds_shader_loop_bound() -> void:
	for i: int in range(0, 101):
		var u: Dictionary = FireBlobTuning.uniforms_for(float(i) / 100.0)
		assert_between(float(u[&"k_active"]), 1.0, float(FireBlobTuning.K_MAX))


func test_quad_contains_every_blob_the_shader_can_draw() -> void:
	# FireBlobTuning contract 1. The shader has no neighbourhood search — the
	# rasterizer is its only bound — so a quad smaller than the field clips blobs
	# at the edge with no error. shader_debug == 3 makes this visible in-engine;
	# this test makes it fail in CI.
	for i: int in range(0, 101):
		var t: float = float(i) / 100.0
		var q: Vector2 = FireBlobTuning.quad_size(t)
		assert_gte(
			q.x * 0.5,
			FireBlobTuning.max_horizontal_reach(t),
			"quad half-width clips blobs at intensity %.2f" % t)
		assert_gte(
			q.y,
			FireBlobTuning.max_rise(t),
			"quad height clips blobs at intensity %.2f" % t)


func test_uniform_names_all_exist_on_the_shader() -> void:
	# FireBlobTuning contract 2: set_shader_parameter silently ignores unknown
	# names, so a typo here would just make that knob stop working.
	var mat: ShaderMaterial = load(RAMP_MATERIAL) as ShaderMaterial
	assert_not_null(mat, "fire_blobs.tres must load")
	var declared: Dictionary = {}
	for p: Dictionary in mat.shader.get_shader_uniform_list():
		declared[StringName(p["name"])] = true
	for name: StringName in FireBlobTuning.uniforms_for(0.5):
		assert_true(
			declared.has(name),
			"uniforms_for() pushes '%s', which fire_blobs.gdshader does not declare" % name)


func test_tres_does_not_author_code_driven_uniforms() -> void:
	# The knob-location rule (see fire_blob_tuning.gd's header): anything
	# uniforms_for() pushes is overwritten every intensity change, so authoring it
	# in the .tres creates a knob that looks tunable in the inspector and silently
	# does nothing. This catches that drift — without it the rule is just a comment.
	var mat: ShaderMaterial = load(RAMP_MATERIAL) as ShaderMaterial
	assert_not_null(mat, "fire_blobs.tres must load")
	for name: StringName in FireBlobTuning.uniforms_for(0.5):
		assert_null(
			mat.get_shader_parameter(name),
			"fire_blobs.tres authors '%s', but uniforms_for() overwrites it — " % name
			+ "the .tres value is dead. Remove it, or stop pushing it.")


func test_rise_speed_jitter_is_reflected_in_the_quad() -> void:
	# Per-blob rise speed is BOUND-RELEVANT: the fastest blob overshoots the
	# nominal column_height, and the quad is the shader's only bound. If the two
	# ever disagree the tallest blobs get clipped with no error.
	assert_gt(FireBlobTuning.RISE_SPEED_JITTER, 0.0, "blobs should not rise in lockstep")
	for i: int in range(0, 101):
		var t: float = float(i) / 100.0
		var nominal: float = lerpf(
			FireBlobTuning.COLUMN_HEIGHT_MIN, FireBlobTuning.COLUMN_HEIGHT_MAX, t)
		assert_gte(
			FireBlobTuning.max_rise(t),
			nominal * (1.0 + FireBlobTuning.RISE_SPEED_JITTER),
			"max_rise ignores the rise-speed overshoot at intensity %.2f" % t)


func test_ramp_colours_are_exact_palette_entries() -> void:
	# CLAUDE.md: RGB is locked to palette2. These are the five ramp stops the
	# user picked; if someone eyedrops a "nicer" orange this catches it.
	var mat: ShaderMaterial = load(RAMP_MATERIAL) as ShaderMaterial
	var expected: Dictionary = {
		&"col_white": Palette.P23,
		&"col_yellow": Palette.P12,
		&"col_orange": Palette.P04,
		&"col_red": Palette.P05,
		&"col_char": Palette.P07,
	}
	for name: StringName in expected:
		var got: Color = mat.get_shader_parameter(name)
		var want: Color = expected[name]
		assert_almost_eq(got.r, want.r, 0.001, "%s.r off palette" % name)
		assert_almost_eq(got.g, want.g, 0.001, "%s.g off palette" % name)
		assert_almost_eq(got.b, want.b, 0.001, "%s.b off palette" % name)
