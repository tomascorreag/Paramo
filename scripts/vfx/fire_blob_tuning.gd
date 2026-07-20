class_name FireBlobTuning
extends RefCounted

# Tuning math for the procedural blob fire (assets/shaders/fire_blobs.gdshader).
# The VALUES live in an inspector-editable resource (FireBlobTuningData /
# resources/fire_blob_tuning.tres); this file is the MATH that turns them into
# shader uniforms and a quad bound. Split that way so the values are tunable in
# the editor while the bound logic — which fails silently if wrong — stays in
# code with tests.
#
# Everything here is static and side-effect free, which is deliberate: this is
# where the shader-mapping *spec* lives ("kindling is a couple of lit pixels",
# "the quad always contains the drawable field"), and it is the only part of the
# effect that can be unit-tested. The shader itself can only be verified by
# looking at it. See tests/test_fire_blob_tuning.gd.
#
# NOTE: the fire's DYNAMICS (how intensity grows, spread, fuel) moved to
# FireDynamics — this file is now purely intensity -> shader uniforms + quad
# bound. There is no longer an isolated-fire ceiling; a lone fire grows too.
#
# Every method takes `data` defaulting to DATA, the one shared resource the game
# and the preview both use. Editing that .tres in the inspector is live in
# scenes/tools/fire_blob_test.tscn (the preview re-reads every frame) and ships
# to the game unchanged. Pass a different resource only to preview an alternative.
#
# Two contracts this file owns, both of which fail SILENTLY if broken — hence
# the tests:
#
#  1. quad_size(i) must strictly contain every blob the shader can draw at
#     intensity i. The shader has NO neighbourhood search: the quad IS the
#     bound (rain.gdshader's rule 3, moved to the CPU). Undersize it and blobs
#     get clipped at the quad edge with no error. shader_debug == 3 draws the
#     rect so the failure is visible.
#  2. The uniform names returned by uniforms_for() must match the shader's.
#     A typo'd name is silently ignored by set_shader_parameter.

# The shared, inspector-editable tuning. preload() returns the same cached
# instance the inspector mutates, so edits are live everywhere that reads DATA.
const DATA: FireBlobTuningData = preload("res://resources/fire_blob_tuning.tres")

# --- Structural constants. NOT in the resource on purpose ---------------------
# These are not "look" knobs; they are code/shader invariants a designer must not
# be able to desync by dragging a slider.

# Loop bounds in the shader. Must match SLOT_MAX / K_MAX in fire_blobs.gdshader,
# and they clamp the resource's slot_count / k_active so a bad .tres value can't
# exceed what the shader's unrolled loops will actually run.
const SLOT_MAX: int = 3
const K_MAX: int = 8

# --- Mirrors of shader internals. quad_size() is only correct while these match
# fire_blobs.gdshader; nothing but a human keeps them in sync, because the tests
# derive BOTH sides of the containment assert from these same constants and so
# cannot catch a drift from the shader. If you change the sway, the size jitter,
# or the stretch in the shader, change these too and re-check with
# `preview_fire_blobs.gd --debug 3` (the only check that would actually notice).
#
# Peak |s1 + 0.5*s2| in the shader's two-harmonic sway; turbulence reach is
# turb_amp * this.
const SWAY_PEAK: float = 1.5
# Peak of the shader's per-blob size jitter (0.7 + 0.6*h). Omitting this
# under-sizes every bound by 30% and silently clips the biggest blobs.
const SIZE_JITTER_MAX: float = 1.3
# Padding on the derived quad, absorbing the shader's floor() and float slop.
# Same role as rain.gdshader's 1-2px bound padding.
const QUAD_PAD: float = 2.0

# The fire's lean has two parts that SHARE one fill budget:
#   - MEAN: the steady downwind lean (global `wind_lean`), set from wind intensity.
#   - GUST: a zero-mean oscillation on top (global `wind_gust`), riding the same
#     scrolling noise field the grass sways on — see WIND_GUST_* in
#     fire_blobs.gdshader — so a gust bends grass and flame in phase.
# The shader's instantaneous lean is `wind_lean + wind_gust * noise`, with the
# noise in [-1, 1], so its peak magnitude is MAX_WIND_MEAN + MAX_WIND_GUST. That
# sum is MAX_WIND_LEAN, which the quad bound is sized for (max_horizontal_reach) —
# the quad is the shader's ONLY spatial bound, so a lean past it clips leaning
# tips silently (the same failure rise_speed_jitter is guarded against). Splitting
# the budget rather than adding to it means the gust costs ZERO extra quad fill.
#
# Kept low because the lean displaces the blob CENTRE by lean * rise height, and
# the tallest column is ~128px, so each 0.01 of total lean is ~1.3px of extra quad
# half-width (pure transparent fill on the fill-bound web build). ~10 degrees at a
# full storm; re-split or raise only against benchmark_fire.gd's area ratio, not
# desktop ms (see [[desktop-cannot-measure-fill]]).
const MAX_WIND_MEAN: float = 0.11
const MAX_WIND_GUST: float = 0.07
# Peak total lean = mean + gust (noise in [-1,1]). Derived, so the quad bound and
# the budget split can never drift apart.
const MAX_WIND_LEAN: float = MAX_WIND_MEAN + MAX_WIND_GUST


## Shader uniform values for an intensity in [0, 1]. Keys are shader uniform
## names — see contract 2 above.
static func uniforms_for(i: float, data: FireBlobTuningData = DATA) -> Dictionary:
	var t: float = clampf(i, 0.0, 1.0)
	return {
		&"slot_count": _slot_count(t, data),
		&"k_active": lerpf(data.k_active_min, data.k_active_max, t),
		&"base_half_width": lerpf(data.half_width_min, data.half_width_max, t),
		&"column_height": lerpf(data.column_height_min, data.column_height_max, t),
		&"blob_max_radius": lerpf(data.blob_max_radius_min, data.blob_max_radius_max, t),
		&"blob_min_radius": lerpf(data.blob_min_radius_min, data.blob_min_radius_max, t),
		&"lifetime": lerpf(data.lifetime_min, data.lifetime_max, t),
		&"turb_amp": lerpf(data.turb_amp_min, data.turb_amp_max, t),
		&"stretch": lerpf(data.stretch_min, data.stretch_max, t),
		&"noise_amp": lerpf(data.noise_amp_min, data.noise_amp_max, t),
		&"noise_scale": lerpf(data.noise_scale_min, data.noise_scale_max, t),
		&"rise_speed_jitter": data.rise_speed_jitter,
	}


## Quad size in world px for an intensity in [0, 1]. See contract 1 — this MUST
## strictly contain the drawable field, because the shader has no other bound.
static func quad_size(i: float, data: FireBlobTuningData = DATA) -> Vector2:
	var t: float = clampf(i, 0.0, 1.0)
	# Derive both half-extents from the reach helpers (+ QUAD_PAD) rather than
	# re-deriving the formulae here — that way the wind-lean term added to
	# max_horizontal_reach can't be present in the bound the tests check while
	# missing from the quad the shader actually gets.
	var half_w: float = max_horizontal_reach(t, data) + QUAD_PAD
	var h: float = max_rise(t, data) + QUAD_PAD
	return Vector2(half_w * 2.0, h)


## Max horizontal distance a blob centre can travel from the column axis, plus
## its own extent. Exposed so the tests can assert quad_size contains it. Folds in
## the worst-case wind lean: the shader displaces the centre by wind_lean * rise
## height (see `centre` in fire_blobs.gdshader), maxed at MAX_WIND_LEAN * the
## tallest a blob centre reaches — otherwise a leaning tip clips at the quad edge.
static func max_horizontal_reach(i: float, data: FireBlobTuningData = DATA) -> float:
	var t: float = clampf(i, 0.0, 1.0)
	var max_centre_rise: float = lerpf(data.column_height_min, data.column_height_max, t) \
			* (1.0 + data.rise_speed_jitter)
	return lerpf(data.half_width_min, data.half_width_max, t) \
			+ lerpf(data.turb_amp_min, data.turb_amp_max, t) * SWAY_PEAK \
			+ MAX_WIND_LEAN * max_centre_rise \
			+ _blob_reach(t, data)


## Max height a blob centre reaches, plus its own extent. column_height is the
## NOMINAL rise — the fastest blob overshoots it by rise_speed_jitter, and that
## overshoot is real quad height, not a rounding allowance.
static func max_rise(i: float, data: FireBlobTuningData = DATA) -> float:
	var t: float = clampf(i, 0.0, 1.0)
	return lerpf(data.column_height_min, data.column_height_max, t) \
			* (1.0 + data.rise_speed_jitter) + _blob_reach(t, data)


## How far below the cell base the quad must extend, in world px. Blobs are BORN
## with their centre exactly on the base (shader y = 0) at radius blob_min_radius,
## so their lower half falls below it. The quad's bottom edge sits on the base, so
## without this skirt every base blob is sliced flat and the fire reads as cut off
## along the tile line. Mirrors _blob_reach but off blob_min_radius — the BIRTH
## radius — since the freshly-born base blobs are the only thing the field reaches
## below the base. + QUAD_PAD, like the other extents.
static func quad_bottom(i: float, data: FireBlobTuningData = DATA) -> float:
	var t: float = clampf(i, 0.0, 1.0)
	return _born_blob_reach(t, data) + QUAD_PAD


# Max downward extent of a base-born blob (centre on the base, radius
# blob_min_radius). Same jitter x noise x stretch factors as _blob_reach: a
# newborn blob rises nearly vertically, so its stretch elongates it downward too.
static func _born_blob_reach(t: float, data: FireBlobTuningData) -> float:
	return lerpf(data.blob_min_radius_min, data.blob_min_radius_max, t) \
			* SIZE_JITTER_MAX \
			* (1.0 + lerpf(data.noise_amp_min, data.noise_amp_max, t)) \
			* lerpf(data.stretch_min, data.stretch_max, t)


# Max half-extent of a single blob, in any direction. Mirrors the shader's
# r_eff_max: full radius x size jitter x noise carve x stretch. All four factors
# are required — see SIZE_JITTER_MAX.
static func _blob_reach(t: float, data: FireBlobTuningData) -> float:
	return lerpf(data.blob_max_radius_min, data.blob_max_radius_max, t) \
			* SIZE_JITTER_MAX \
			* (1.0 + lerpf(data.noise_amp_min, data.noise_amp_max, t)) \
			* lerpf(data.stretch_min, data.stretch_max, t)


static func _slot_count(t: float, data: FireBlobTuningData) -> int:
	return clampi(
		int(round(lerpf(float(data.slot_count_min), float(data.slot_count_max), t))),
		data.slot_count_min,
		SLOT_MAX)
