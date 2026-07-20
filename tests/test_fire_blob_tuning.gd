extends GutTest

# Guards FireBlobTuning — the pure intensity -> shader-uniform + quad-bound math
# behind the procedural blob fire. The shader itself can only be verified by
# looking at it (see scripts/tools/benchmark_fire.gd and the shader_debug modes),
# so this file is where the shader-mapping SPEC gets held:
#
#   - kindling is literally a couple of lit pixels;
#   - the quad always contains the field the shader can draw (fire_blobs.gdshader
#     has NO spatial bound of its own — the quad IS the bound, so undersizing it
#     clips blobs silently).
#
# The fire's DYNAMICS (intensity growth, spread, fuel) are FireDynamics' spec —
# see tests/test_fire_dynamics.gd. FireBlobTuning no longer computes intensity.

const RAMP_MATERIAL: String = "res://resources/materials/fire_blobs.tres"


# --- Kindling read -----------------------------------------------------------

func test_kindling_is_a_couple_of_lit_pixels() -> void:
	var u: Dictionary = FireBlobTuning.uniforms_for(0.0)
	# Kindling is a SMALL EMBER, not a plume. The retune reshaped it from a thin
	# tall wisp of ~1px dots into a short compact glow: a stubby column
	# (column_height_min) with a chunkier blob (blob_max_radius_min). Both stay
	# small — the shader samples at integer pixels, so a few-px blob in a few-px
	# column still lights only a small cluster. Guard BOTH extents so a future
	# retune can't quietly balloon kindling into a full flame (wildfire is 16px
	# blobs / 80px column — roughly 4x these bounds).
	assert_lte(float(u[&"blob_max_radius"]), 5.0, "kindling blobs stay a few px, not plume-scale")
	assert_lte(float(u[&"column_height"]), 8.0, "kindling barely rises")
	assert_eq(int(u[&"slot_count"]), 1, "kindling is a single blob stream")
	# Kindling density = k_active_min, a tuned look value (fire_blob_tuning.tres).
	# The bound is "still a small cluster, not a plume"; raise it only alongside a
	# deliberate retune of that field.
	assert_lte(float(u[&"k_active"]), 4.0, "kindling column must stay sparse")


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


func test_quad_bottom_covers_base_born_blobs() -> void:
	# Blobs are born centred on the base (shader y = 0) at blob_min_radius, so
	# their lower half falls below it. The quad's bottom edge sits on the base, so
	# quad_bottom must clear a born blob or the base is sliced flat — the "cut off
	# at the bottom" bug. Lower bound: it must exceed at least the bare birth radius
	# at every intensity (the real reach folds jitter/noise/stretch on top, so this
	# is conservative and can't false-pass).
	for i: int in range(0, 101):
		var t: float = float(i) / 100.0
		var born_radius: float = float(FireBlobTuning.uniforms_for(t)[&"blob_min_radius"])
		assert_gte(
			FireBlobTuning.quad_bottom(t),
			born_radius,
			"quad bottom slices base blobs at intensity %.2f" % t)
	# And it must scale with fire size — a wildfire's base blobs dwarf kindling's.
	assert_gt(
		FireBlobTuning.quad_bottom(1.0),
		FireBlobTuning.quad_bottom(0.0),
		"quad bottom must grow with intensity")


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


# NOTE: there is deliberately no "the material must not author code-driven
# uniforms" test. Godot re-serializes EVERY shader uniform into fire_blobs.tres
# the instant it is touched in the inspector, so that invariant is unenforceable.
# The guarantee that actually matters — a code-driven value in the material is
# IGNORED, FireBlobTuning wins — is enforced below by
# test_editor_refresh_syncs_look_params_but_not_code_driven (it sets
# column_height=999 in the material and asserts the column uses the resource's
# value). That is the enforceable form of the same intent.


func test_editor_refresh_syncs_look_params_but_not_code_driven() -> void:
	# The preview holds a frozen .duplicate() of fire_blobs.tres per column, so
	# inspector edits only reach it via FireBlobColumn.editor_refresh. This guards
	# that path: look params must sync from the live .tres, code-driven ones must
	# stay FireBlobTuning-driven (a .tres value for them is dead), and the ceiling
	# comes from the caller, not the .tres. Without this, "edit the .tres and watch
	# it update" silently reverts to the freeze bug it was written to fix.
	var col: FireBlobColumn = load("res://scripts/vfx/fire_blob_column.gd").new()
	col.set_intensity(1.0)  # column_height should be the FireBlobTuning MAX
	var mat: ShaderMaterial = col.material
	var src: ShaderMaterial = load(RAMP_MATERIAL) as ShaderMaterial

	var saved_rb: Variant = src.get_shader_parameter(&"radial_bias")
	var saved_ch: Variant = src.get_shader_parameter(&"column_height")
	src.set_shader_parameter(&"radial_bias", 1.9)      # a LOOK param
	src.set_shader_parameter(&"column_height", 999.0)  # a CODE-DRIVEN param

	col.editor_refresh(0.4)

	assert_almost_eq(float(mat.get_shader_parameter(&"radial_bias")), 1.9, 0.001,
		"look param edited in the .tres did not reach the column")
	assert_almost_eq(float(mat.get_shader_parameter(&"column_height")),
		FireBlobTuning.DATA.column_height_max, 0.001,
		"a .tres value stomped a FireBlobTuning-driven uniform")
	assert_almost_eq(float(mat.get_shader_parameter(&"heat_ceiling")), 0.4, 0.001,
		"heat_ceiling must come from the caller, not the .tres")

	# Leave the shared resource as we found it — other tests load the same instance.
	src.set_shader_parameter(&"radial_bias", saved_rb)
	src.set_shader_parameter(&"column_height", saved_ch)
	col.free()


func test_wind_lean_budget_splits_into_mean_plus_gust() -> void:
	# The quad bound is sized for MAX_WIND_LEAN, but the shader's instantaneous lean
	# is wind_lean + wind_gust*noise (|noise|<=1), peaking at MAX_WIND_MEAN +
	# MAX_WIND_GUST. If that sum ever exceeds MAX_WIND_LEAN, a full gust pushes a
	# blob past the quad and clips it. Pin the invariant so a retune of either part
	# can't silently break the bound.
	assert_gt(FireBlobTuning.MAX_WIND_GUST, 0.0, "the gust must be a real oscillation")
	assert_almost_eq(FireBlobTuning.MAX_WIND_MEAN + FireBlobTuning.MAX_WIND_GUST,
		FireBlobTuning.MAX_WIND_LEAN, 0.0001,
		"mean + gust must equal the lean the quad is sized for")


func test_max_horizontal_reach_includes_wind_lean() -> void:
	# The shader leans a blob's centre by wind_lean * rise height, capped CPU-side
	# at MAX_WIND_LEAN. The quad is the shader's ONLY spatial bound, so
	# max_horizontal_reach (which quad_size widens by) MUST fold that in, or a gust
	# clips leaning tips with no error — the same failure mode rise_speed_jitter is
	# guarded against. The neighbouring quad-contains test can't catch a dropped
	# lean term (blob_reach alone dwarfs it), so recompute the expected reach from
	# raw tuning data here, independently of the function under test.
	assert_gt(FireBlobTuning.MAX_WIND_LEAN, 0.0, "wind lean must be a real cap")
	var d: FireBlobTuningData = FireBlobTuning.DATA
	for i: int in range(0, 101):
		var t: float = float(i) / 100.0
		var base_half: float = lerpf(d.half_width_min, d.half_width_max, t)
		var turb: float = lerpf(d.turb_amp_min, d.turb_amp_max, t) * FireBlobTuning.SWAY_PEAK
		var centre_rise: float = lerpf(d.column_height_min, d.column_height_max, t) \
				* (1.0 + d.rise_speed_jitter)
		var blob: float = lerpf(d.blob_max_radius_min, d.blob_max_radius_max, t) \
				* FireBlobTuning.SIZE_JITTER_MAX \
				* (1.0 + lerpf(d.noise_amp_min, d.noise_amp_max, t)) \
				* lerpf(d.stretch_min, d.stretch_max, t)
		var expected: float = base_half + turb + FireBlobTuning.MAX_WIND_LEAN * centre_rise + blob
		assert_almost_eq(FireBlobTuning.max_horizontal_reach(t), expected, 0.001,
			"max_horizontal_reach dropped a term at intensity %.2f" % t)


func test_rise_speed_jitter_is_reflected_in_the_quad() -> void:
	# Per-blob rise speed is BOUND-RELEVANT: the fastest blob overshoots the
	# nominal column_height, and the quad is the shader's only bound. If the two
	# ever disagree the tallest blobs get clipped with no error.
	assert_gt(FireBlobTuning.DATA.rise_speed_jitter, 0.0, "blobs should not rise in lockstep")
	for i: int in range(0, 101):
		var t: float = float(i) / 100.0
		var nominal: float = lerpf(
			FireBlobTuning.DATA.column_height_min, FireBlobTuning.DATA.column_height_max, t)
		assert_gte(
			FireBlobTuning.max_rise(t),
			nominal * (1.0 + FireBlobTuning.DATA.rise_speed_jitter),
			"max_rise ignores the rise-speed overshoot at intensity %.2f" % t)


func test_blob_phase_advances_at_one_over_lifetime() -> void:
	# The blob age clock is a CPU accumulator (blob_phase), NOT the shader's
	# TIME/lifetime — that decoupling is what stops an intensity change from
	# teleporting every blob (age used to shift by ~TIME*Δlifetime). This guards the
	# rate: phase must gain 1/lifetime per second, or blobs rise at the wrong speed.
	var col: FireBlobColumn = load("res://scripts/vfx/fire_blob_column.gd").new()
	col.set_cell_seed(0.0)  # deterministic: _phase seed = 0
	var mat: ShaderMaterial = col.material

	col.set_intensity(0.0)  # lifetime = lifetime_min
	var life0: float = FireBlobTuning.DATA.lifetime_min
	var p0: float = float(mat.get_shader_parameter(&"blob_phase"))
	for _i: int in 10:
		col.advance_phase(0.1)  # 1.0s total
	var gained: float = float(mat.get_shader_parameter(&"blob_phase")) - p0
	assert_almost_eq(gained, 1.0 / life0, 0.002,
		"phase must advance 1/lifetime per second")

	col.free()


func test_blob_phase_is_continuous_across_an_intensity_change() -> void:
	# THE fix, in a test: changing intensity changes lifetime, but the phase VALUE
	# must not jump — it just changes RATE. A discontinuity here is exactly the
	# glitch this whole clock was built to remove.
	var col: FireBlobColumn = load("res://scripts/vfx/fire_blob_column.gd").new()
	col.set_cell_seed(0.0)
	var mat: ShaderMaterial = col.material

	col.set_intensity(0.0)
	for _i: int in 5:
		col.advance_phase(0.1)
	var before: float = float(mat.get_shader_parameter(&"blob_phase"))

	col.set_intensity(1.0)  # lifetime jumps min -> max; phase must be untouched
	var after: float = float(mat.get_shader_parameter(&"blob_phase"))
	assert_almost_eq(after, before, 0.0001,
		"set_intensity moved the phase — the age clock is not continuous")

	# ...and it now advances at the NEW lifetime's rate.
	col.advance_phase(0.1)
	var step: float = float(mat.get_shader_parameter(&"blob_phase")) - after
	assert_almost_eq(step, 0.1 / FireBlobTuning.DATA.lifetime_max, 0.002,
		"phase rate did not follow the new lifetime")

	col.free()


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
