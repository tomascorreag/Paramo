class_name FireBlobTuning
extends RefCounted

# Pure tuning math for the procedural blob fire (assets/shaders/fire_blobs.gdshader).
#
# Everything here is static and side-effect free, which is deliberate: this is
# where the *spec* lives ("an isolated ignition stays kindling", "kindling is a
# couple of lit pixels"), and it is the only part of the effect that can be
# unit-tested. The shader itself can only be verified by looking at it. See
# tests/test_fire_blob_tuning.gd.
#
# Two contracts this file owns, both of which fail SILENTLY if broken — hence
# the tests:
#
#  1. quad_size(i) must strictly contain every blob the shader can draw at
#     intensity i. The shader has NO neighbourhood search: the quad IS the
#     bound (this is rain.gdshader's rule 3, moved to the CPU where it's paid
#     once per intensity change instead of once per fragment). Undersize it and
#     blobs get clipped at the quad edge with no error. shader_debug == 3 draws
#     the rect so the failure is visible.
#
#  2. The uniform names returned by uniforms_for() must match the shader's.
#     A typo'd name is silently ignored by set_shader_parameter.

# --- Intensity ---------------------------------------------------------------

# An isolated ignition can NEVER exceed this intensity, at any burn amount. This
# single constant is what makes "a lone fire stays kindling, a spreading front
# makes wildfires" true rather than aspirational.
const ISOLATED_CAP: float = 0.22

# Loop bounds in the shader. Must match SLOT_MAX / K_MAX in fire_blobs.gdshader.
const SLOT_MAX: int = 3
const K_MAX: int = 8

# --- Endpoints. Every row is lerped from kindling (i=0) to wildfire (i=1).
# Named constants rather than inline numbers because these are the escape
# hatches if the web build measures badly — COLUMN_HEIGHT is the biggest lever
# (quad area is linear in it), then K_ACTIVE (loop length).
const COLUMN_HEIGHT_MIN: float = 24.0
const COLUMN_HEIGHT_MAX: float = 200.0
const SLOT_COUNT_MIN: int = 1
const SLOT_COUNT_MAX: int = 3
const K_ACTIVE_MIN: float = 2.0
const K_ACTIVE_MAX: float = 8.0
const HALF_WIDTH_MIN: float = 0.5
const HALF_WIDTH_MAX: float = 12.0
# Blobs must be big enough to MEET their neighbours up the column. At k_active=8
# over COLUMN_HEIGHT_MAX the mean spacing is ~25px, so a max radius much under
# ~10 leaves visible gaps and the plume reads as floating embers rather than
# fire. Growing the blobs is much cheaper than raising K_ACTIVE_MAX (which is a
# loop bound); rise_curve does the rest by bunching them at the base.
const BLOB_MAX_RADIUS_MIN: float = 1.2
const BLOB_MAX_RADIUS_MAX: float = 10.0
const BLOB_MIN_RADIUS_MIN: float = 0.4
const BLOB_MIN_RADIUS_MAX: float = 1.2
const LIFETIME_MIN: float = 0.5
const LIFETIME_MAX: float = 2.2
const TURB_AMP_MIN: float = 0.5
const TURB_AMP_MAX: float = 8.0
const STRETCH_MIN: float = 1.3
const STRETCH_MAX: float = 2.0
const NOISE_AMP_MIN: float = 0.3
const NOISE_AMP_MAX: float = 0.65
const NOISE_SCALE_MIN: float = 0.7
const NOISE_SCALE_MAX: float = 0.45

# Per-blob rise speed spread: each blob rises at 1 +/- this, fixed for its life
# and re-rolled on rebirth. Constant across intensity, but owned HERE and not in
# the .tres because it is bound-relevant — the fastest blob reaches
# column_height * (1 + this), and quad_size has to know. See the rule at the top.
# 0.0 = every blob rises in lockstep (reads mechanical); 0.3 = a natural spread.
# Raising it makes the quad taller and costs fill, so it is not free.
const RISE_SPEED_JITTER: float = 0.3

# --- WHERE DOES A KNOB LIVE? -------------------------------------------------
# The rule is BOUND-RELEVANCE, not "is it constant":
#
#   Does quad_size() depend on it?
#     YES -> it belongs HERE, and uniforms_for() pushes it. The quad is the
#            shader's ONLY spatial bound, so a value the quad depends on must be
#            somewhere quad_size can read. Put it in the .tres and an inspector
#            edit silently pushes blobs outside the quad and clips them.
#     NO  -> it belongs in resources/materials/fire_blobs.tres, and this file
#            must never push it (a per-frame push would stomp the inspector and
#            the .tres would stop being the tuning surface).
#
# Bound-relevant, owned here: column_height, blob_*_radius, noise_amp, stretch,
# turb_amp, base_half_width, rise_speed_jitter, plus the SWAY_PEAK /
# SIZE_JITTER_MAX mirrors below.
#
# Look-only, owned by the .tres: the five ramp colours, radial_bias, turb_freq_min
# /max, shape_evolve, rise_curve, smoke_dither, heat_ceiling.
#   - rise_curve is safe there because it only reshapes the rise, it does not
#     lengthen it: rise_t = an*mix(1,an,rc) is exactly 1.0 at an=1 for ANY rc.
#   - turb_freq is safe because tx is bounded by turb_amp regardless of frequency,
#     and the per-fragment stretch bound is computed from the actual velocity.

# --- Mirrors of shader internals. quad_size() is only correct while these match
# fire_blobs.gdshader; nothing but a human keeps them in sync, because the tests
# below derive BOTH sides of the containment assert from these same constants and
# therefore cannot catch a drift from the shader. If you change the sway, the size
# jitter, or the stretch in the shader, change these too and re-check with
# `preview_fire_blobs.gd --debug 3` (which renders the real quad against the real
# blobs, and is the only check that would actually notice).
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


## Size envelope over burn amount: kindling -> established -> dying back to
## embers. Deliberately shaped like BurningCellVFX._burn_envelope (which drives
## the light) so size and glow rise and fall together.
static func size_envelope(amount: float) -> float:
	var a: float = clampf(amount, 0.0, 1.0)
	if a < 0.20:
		return (a / 0.20) * 0.55
	if a < 0.80:
		return lerpf(0.55, 1.0, (a - 0.20) / 0.60)
	return lerpf(1.0, 0.35, (a - 0.80) / 0.20)


## Combined intensity in [0, 1]. Burning neighbours raise the CEILING; burn
## amount drives the envelope toward it. Amount alone can never make an isolated
## fire big — that asymmetry is the whole point.
static func intensity(amount: float, burning_neighbours: int) -> float:
	var n: float = float(clampi(burning_neighbours, 0, 4)) / 4.0
	var cap: float = lerpf(ISOLATED_CAP, 1.0, n)
	return clampf(size_envelope(amount) * cap, 0.0, 1.0)


## Shader uniform values for an intensity in [0, 1]. Keys are shader uniform
## names — see contract 2 above.
static func uniforms_for(i: float) -> Dictionary:
	var t: float = clampf(i, 0.0, 1.0)
	return {
		&"slot_count": _slot_count(t),
		&"k_active": lerpf(K_ACTIVE_MIN, K_ACTIVE_MAX, t),
		&"base_half_width": lerpf(HALF_WIDTH_MIN, HALF_WIDTH_MAX, t),
		&"column_height": lerpf(COLUMN_HEIGHT_MIN, COLUMN_HEIGHT_MAX, t),
		&"blob_max_radius": lerpf(BLOB_MAX_RADIUS_MIN, BLOB_MAX_RADIUS_MAX, t),
		&"blob_min_radius": lerpf(BLOB_MIN_RADIUS_MIN, BLOB_MIN_RADIUS_MAX, t),
		&"lifetime": lerpf(LIFETIME_MIN, LIFETIME_MAX, t),
		&"turb_amp": lerpf(TURB_AMP_MIN, TURB_AMP_MAX, t),
		&"stretch": lerpf(STRETCH_MIN, STRETCH_MAX, t),
		&"noise_amp": lerpf(NOISE_AMP_MIN, NOISE_AMP_MAX, t),
		&"noise_scale": lerpf(NOISE_SCALE_MIN, NOISE_SCALE_MAX, t),
		&"rise_speed_jitter": RISE_SPEED_JITTER,
	}


## Quad size in world px for an intensity in [0, 1]. See contract 1 — this MUST
## strictly contain the drawable field, because the shader has no other bound.
static func quad_size(i: float) -> Vector2:
	var t: float = clampf(i, 0.0, 1.0)
	# Largest half-extent a blob can reach in any direction: its radius, inflated
	# by the noise carve, then by the stretch (which elongates along flow — the
	# flow is mostly vertical, so bounding both axes by it is conservative).
	var r_out: float = _blob_reach(t)
	var half_w: float = lerpf(HALF_WIDTH_MIN, HALF_WIDTH_MAX, t) \
			+ lerpf(TURB_AMP_MIN, TURB_AMP_MAX, t) * SWAY_PEAK \
			+ r_out + QUAD_PAD
	var h: float = lerpf(COLUMN_HEIGHT_MIN, COLUMN_HEIGHT_MAX, t) * (1.0 + RISE_SPEED_JITTER) \
			+ r_out + QUAD_PAD
	return Vector2(half_w * 2.0, h)


## Max horizontal distance a blob centre can travel from the column axis, plus
## its own extent. Exposed so the tests can assert quad_size contains it.
static func max_horizontal_reach(i: float) -> float:
	var t: float = clampf(i, 0.0, 1.0)
	return lerpf(HALF_WIDTH_MIN, HALF_WIDTH_MAX, t) \
			+ lerpf(TURB_AMP_MIN, TURB_AMP_MAX, t) * SWAY_PEAK \
			+ _blob_reach(t)


## Max height a blob centre reaches, plus its own extent. column_height is the
## NOMINAL rise — the fastest blob overshoots it by RISE_SPEED_JITTER, and that
## overshoot is real quad height, not a rounding allowance.
static func max_rise(i: float) -> float:
	var t: float = clampf(i, 0.0, 1.0)
	return lerpf(COLUMN_HEIGHT_MIN, COLUMN_HEIGHT_MAX, t) * (1.0 + RISE_SPEED_JITTER) \
			+ _blob_reach(t)


# Max half-extent of a single blob, in any direction. Mirrors the shader's
# r_eff_max: full radius x size jitter x noise carve x stretch. All four factors
# are required — see SIZE_JITTER_MAX.
static func _blob_reach(t: float) -> float:
	return lerpf(BLOB_MAX_RADIUS_MIN, BLOB_MAX_RADIUS_MAX, t) \
			* SIZE_JITTER_MAX \
			* (1.0 + lerpf(NOISE_AMP_MIN, NOISE_AMP_MAX, t)) \
			* lerpf(STRETCH_MIN, STRETCH_MAX, t)


static func _slot_count(t: float) -> int:
	return clampi(
		int(round(lerpf(float(SLOT_COUNT_MIN), float(SLOT_COUNT_MAX), t))),
		SLOT_COUNT_MIN,
		SLOT_MAX)
