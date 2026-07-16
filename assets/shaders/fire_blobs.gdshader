shader_type canvas_item;
// blend_mix (the default) is explicit here for a reason: the palette RGB must
// reach the framebuffer unmodified. Alpha is only ever 1 or 0 — never between —
// so no fragment can put an off-palette colour on screen. See SMOKE below.
render_mode blend_mix;

// Fully-procedural blob fire + smoke. One quad per burning cell; no sprites, no
// particles, no CPU sim. Everything below is a deterministic function of TIME,
// the fragment's world pixel, and the uniforms.
//
// A blob is born as a ~1px white dot at the base of the column, grows, rises
// with turbulence, stretches along its flow direction, and steps through a hard
// 5-colour ramp (white -> yellow -> orange -> red -> char) before vanishing.
// Fire and smoke are ONE system: the char stage IS the smoke. There is no
// second emitter and no smoke code path.
//
// --- WHY THERE IS NO SPATIAL SEARCH ----------------------------------------
// rain.gdshader is a FULLSCREEN pass, so every fragment must ask "which cells
// could reach me?" and pay for a 9x3 neighbourhood scan. That is rain's rule 3
// ("exact spatial bounds — the single largest saving").
//
// This shader does not have that problem, and the difference is structural: the
// quad IS one cell's column, so the set of blobs that can touch any fragment in
// it is exactly "this column's slots". The bound still exists — it just moved to
// the CPU, where FireBlobTuning.quad_size() sizes the quad from the same
// constants once per intensity change, and the rasterizer enforces it for free.
//
// The consequence: the loop is slot_count x k_active and nothing else.
//   kindling  1 slot  x 2 blobs =  2 iterations
//   wildfire  3 slots x 8 blobs = 24 iterations
// Do NOT reintroduce a neighbourhood scan here. If blobs are clipping at the
// quad edge, the quad is too small (shader_debug == 3 shows the rect) — that is
// a CPU-side bug in quad_size(), not something to fix with a wider search.
//
// --- COORDINATE SPACE ------------------------------------------------------
// All blob math runs in integer CELL-LOCAL pixels:
//     p = floor(world) - floor(origin)
// `origin` is the quad's node position, which FireBlobColumn places exactly at
// the cell centre. +Y is down (Godot 2D), so the column rises toward -Y.
//
// World-anchored, not screen-anchored. rain reconstructs world space from a
// CPU-pushed camera_offset because it lives on a CanvasLayer and HAS no world
// transform; a world-parented quad already has one in MODEL_MATRIX, so reading
// it there is the correct analogue, not a workaround (and it costs no per-frame
// CPU push). Valid because there is no camera zoom and DisplayManager locks an
// integer content scale, so 1 world unit == 1 game pixel; and World (145, 99)
// plus every Ground* layer offset are integers, so floor(canvas space) lands on
// the same lattice as the tile texels.
//
// The faux-pixel guarantee falls out of this: blob centres move continuously in
// float, but the field is only ever SAMPLED at integer `p`. Every downstream
// term is a function of `p`, so it is constant across the N*N screen fragments
// of one game pixel. The silhouette is chunky and cannot move sub-pixel.
// shader_debug == 2 is the check — pan the camera; the grid must not swim.
//
// --- THE RAMP MUST NOT LERP ------------------------------------------------
// There is deliberately no mix()/smoothstep() anywhere on the colour path. The
// stage is an integer index into five uniforms. Do not "smooth" it.
//
//     heat  = ((1 - age_norm) - r * radial_bias * age_norm) * heat_ceiling
//     stage = floor((1 - heat) * 5)          // heat <= 0 == gone
//
// `r` is the noise-carved normalised radius (0 centre, 1 nominal edge), so the
// SIGN of the radial term is what makes the OUTER texels age first: larger r ->
// lower heat -> higher stage. A blob therefore burns inward — edges reach
// red/char while the core is still white.
//
// The radial term is scaled by age_norm so that at age 0 the blob is UNIFORMLY
// stage 0 — born white-hot at the tile, with the inward burn developing rather
// than being present at birth. Without that factor newborn blobs have yellow
// rims, which contradicts the spec.
//
// Falls out of the same two lines, without special-casing:
//   age 0.0  R~1px, heat 1 everywhere  -> a 1-2px WHITE DOT (the kindling read)
//   age 0.5  R mid                     -> orange core, red rim
//   age 0.8+ rim heat <= 0             -> silhouette ERODES inward while R still
//                                         grows: a shrinking char puff (smoke)
//   age 1.0  heat 0                    -> gone
// `radial_bias` sets when erosion starts: rim dies at age_norm = 1/(1+bias),
// independent of heat_ceiling.
//
// `heat_ceiling` caps how hot a blob can ever get — that is the entire smoulder
// control, and there is no second code path. It is MULTIPLICATIVE for a reason:
// a subtractive bias was tried and is wrong, because subtracting b makes heat
// reach 0 at age_norm = 1-b, so blobs flash their colour and die at a fraction
// of their lifetime instead of living it out. Scaling instead caps the stage
// while preserving the full life:
//     1.0  full ramp, white -> char
//     0.6  a dying fire: orange -> red -> char, never white
//     0.2  smoke only: born char, lives its whole life as char
// Ramping it down as a cell burns out therefore gives the fire a natural
// burn-down through the palette AND a smouldering tail, from one uniform.
//
// --- PERFORMANCE -----------------------------------------------------------
// Mirrors rain.gdshader's rules 1 and 2 (rule 3 is handled by the quad, above):
//
//  1. LOOP-INVARIANT HOISTING. Anything derivable from uniforms alone is
//     computed ONCE in fragment(), never inside the loop.
//
//  2. LAZY EVERYTHING, AND THE GATE IS ORDERED Y-FIRST. Rise is LINEAR in age,
//     so a blob's y is known from age alone with NO hash and NO transcendental.
//     The y-gate therefore rejects most candidates having cost ~5 ALU ops, and
//     only survivors pay for hashes, turbulence sines and the shape noise.
//     Two things this ordering depends on — re-derive it if either changes:
//       - rise must stay linear in age;
//       - turbulence must stay X-ONLY (y-turbulence means inflating y_reach by
//         its amplitude, and the gate stops being exact).
//
// Turbulence uses sin(), and per-blob randoms use the include's fract-based
// _hash. rain.gdshader MEASURED sin-based hashing as 25% FASTER than an integer
// bit-hash on GL Compatibility — but that shader is ALU-bound with an idle SFU,
// which is NOT this shader's regime (the turbulence already keeps the SFU
// busy). Do not port that conclusion here by assumption; re-measure with
// scripts/tools/benchmark_fire.gd before swapping either hash.

#include "res://assets/shaders/noise_common.gdshaderinc"

// --- Colour ramp. Palette-locked (assets/palettes/palette2.txt); RGB is not
// free to invent. Defaults are the authored values, overridden by
// resources/materials/fire_blobs.tres.
uniform vec3 col_white  : source_color = vec3(0.945, 0.965, 0.941); // P23 #F1F6F0
uniform vec3 col_yellow : source_color = vec3(0.992, 0.820, 0.475); // P12 #FDD179
uniform vec3 col_orange : source_color = vec3(0.922, 0.588, 0.380); // P04 #EB9661
uniform vec3 col_red    : source_color = vec3(0.710, 0.349, 0.271); // P05 #B55945
uniform vec3 col_char   : source_color = vec3(0.239, 0.200, 0.200); // P07 #3D3333

// Per-cell decorrelation. EVERY per-blob hash mixes this in, so two burning
// cells never render the same fire. Without it the whole effect is a function of
// (slot, birth) only, and every cell on the map is pixel-identical — which is
// exactly what happens if you forget to push it (it defaults to 0).
// FireBlobColumn sets it from a hash of the cell coord.
uniform float cell_seed = 0.0;

// --- CODE-DRIVEN. Editing these on the MATERIAL (fire_blobs.tres) does nothing:
// FireBlobColumn._apply() overwrites every one of them each intensity change, so
// an inspector edit to the material is discarded next frame. (The material still
// LISTS them because Godot lists every shader uniform — ignore them there.)
//
// Tune them in resources/fire_blob_tuning.tres (FireBlobTuningData) — the ONE
// resource the game and the editor preview both read. They are MIN/MAX pairs
// lerped kindling -> wildfire (a single material uniform cannot hold a pair,
// which is the whole reason they are a separate resource). FireBlobTuning
// derives the quad bound from the same values, and the quad is this shader's
// only spatial limit — so the values and the bound move together, which an
// unchecked material override would break.
//
// The knobs you tune ON THE MATERIAL are the ones below this block: the ramp
// colours, radial_bias, rise_curve, turb_freq_*, shape_evolve, smoke_dither.
// Defaults here are the mid-intensity look, for previewing the raw shader.
uniform int   slot_count      : hint_range(1, 3) = 2;
// Live blobs per slot. Staggered by k/k_active, so they stay evenly spread up
// the column at any count. This is what keeps a SHORT kindling column sparse
// while a TALL wildfire column stays dense — a fixed count cannot do both.
uniform float k_active        : hint_range(1.0, 8.0) = 5.0;
uniform float base_half_width : hint_range(0.0, 24.0) = 6.0;
uniform float column_height   : hint_range(4.0, 240.0) = 56.0;
uniform float blob_max_radius : hint_range(0.5, 16.0) = 4.0;
uniform float blob_min_radius : hint_range(0.1, 4.0) = 0.6;
// Caps how hot a blob can get. 1 = full white->char ramp, 0.2 = smoke only.
// Multiplicative, not subtractive — see THE RAMP above.
uniform float heat_ceiling    : hint_range(0.05, 1.0) = 1.0;
// Per-blob rise speed spread: each blob's speed is 1 +/- this. Pushed by
// FireBlobTuning, NOT authored in the .tres, and that is deliberate — it is
// BOUND-RELEVANT. The fastest blob reaches column_height * (1 + this), which is
// what FireBlobTuning.quad_size must size the quad to. If it lived in the .tres,
// editing it would silently push the tallest blobs outside the quad and clip
// them, because the shader has no bound of its own.
uniform float rise_speed_jitter : hint_range(0.0, 0.6) = 0.3;
// Global blob-cycle phase, in CYCLES, accumulated on the CPU as the running
// integral of dt/lifetime (FireBlobColumn._advance). This is the age CLOCK, and
// it REPLACES TIME/lifetime.
//
// Why: lifetime scales with intensity, and intensity changes every burn tick and
// every time a neighbour ignites. Deriving age as fract(TIME/lifetime) meant a
// change of Δlifetime shifted every blob's age by −TIME/lifetime²·Δlifetime — a
// term proportional to absolute TIME, so it grew through a session and teleported
// all blobs on each intensity change (plus re-rolled their hashes via birth_idx).
// Invisible at the fixed intensities of scenes/tools/fire_blob_test.tscn, a
// glitch in game. blob_phase integrates dt/lifetime instead, so it is CONTINUOUS
// across lifetime changes and the age never jumps. Pushed every frame by the
// column (game, via _process) or the preview (editor, via advance_phase).
uniform float blob_phase = 0.0;
// How long a blob lives. Also sets rise SPEED: a blob traverses the column over
// exactly one lifetime, so speed = column_height / lifetime. There is no
// separate speed uniform, and adding one would just over-determine the same
// number. To make fire rise faster, raise COLUMN_HEIGHT_* or lower LIFETIME_*
// in FireBlobTuning. NOTE: it no longer sets the age CLOCK (blob_phase does) —
// it only scales age to seconds (a = age_norm·lifetime) for the turbulence and
// the rise. That decoupling is exactly what makes an intensity-driven lifetime
// change smooth instead of a teleport.
uniform float lifetime : hint_range(0.2, 8.0) = 1.2;
// How far blobs wander sideways, in px. (How FAST they wiggle is turb_freq_*,
// which IS .tres-tunable — this one is bound-relevant and so lives in code.)
uniform float turb_amp : hint_range(0.0, 24.0) = 4.0;
// Elongation along the flow direction. 1 = round.
uniform float stretch : hint_range(1.0, 4.0) = 1.7;
uniform float noise_amp : hint_range(0.0, 1.5) = 0.6;
uniform float noise_scale : hint_range(0.02, 2.0) = 0.5;

// --- TUNABLE in resources/materials/fire_blobs.tres (inspector, live). Nothing
// in code writes these; they are constant across the fire's life AND the quad
// bound does not depend on them, which is exactly why they can live in the .tres.
// See the rule at the top of scripts/vfx/fire_blob_tuning.gd.

// Band width / erosion onset. Rim dies at age_norm = 1/(1+radial_bias).
uniform float radial_bias : hint_range(0.0, 2.0) = 0.5;
// How much blobs ACCELERATE upward. 0 = constant speed (blobs end up evenly
// spaced up the column, which reads as floating embers); 1 = starts slow and
// accelerates, so blobs bunch up at the base and thin out as they rise — dense
// fire at the tile, thinning smoke above. Never reaches a zero initial speed, so
// the velocity (and therefore the stretch direction) is never degenerate.
// Bound-safe at any value: rise_t = an*mix(1,an,rc) is exactly 1.0 at an=1 for
// every rc, so this reshapes the rise without lengthening it.
uniform float rise_curve : hint_range(0.0, 0.95) = 0.7;
// How FAST blobs wiggle (turb_amp is how far). Bound-safe: tx is capped by
// turb_amp regardless of frequency.
uniform float turb_freq_min : hint_range(0.1, 12.0) = 1.5;
uniform float turb_freq_max : hint_range(0.1, 12.0) = 4.0;
// How fast a blob's silhouette churns as it rises.
uniform float shape_evolve : hint_range(0.0, 8.0) = 2.0;
// SMOKE: fraction of char texels KEPT. Palette-pure thinning — whole texels are
// dropped, RGB stays exactly P07. Deliberately NOT a fractional alpha: blending
// P07 toward the background would put an off-palette colour on screen. Ships at
// 1.0 (solid); turn it down only if opaque char reads too heavy over terrain.
uniform float smoke_dither : hint_range(0.0, 1.0) = 1.0;

global uniform int shader_debug;
// Wind lean, sharing rain's wind DIRECTION (both set by DayNightSceneController
// from the same signed source, so a gust bends flame and rain the same way).
// Signed; its magnitude is a conservative cap (FireBlobTuning.MAX_WIND_LEAN)
// applied CPU-side, and the quad bound (FireBlobTuning.quad_size) is sized for
// that MAX, so a gust can never push a blob outside the quad and clip it. It is
// an X-ONLY displacement (see `centre` below) for the same reason turbulence is —
// so the y-first gate stays exact. A global uniform, like shader_debug, not a
// per-material push: a busy fire has ~160 duplicated blob materials.
global uniform float wind_lean;

const int N_STAGES = 5;
// Loop bounds. The ACTUAL counts are the slot_count / k_active uniforms; these
// only cap the unrolled loop. Both loops break/continue on the uniform, so
// kindling genuinely costs 2 iterations, not 24.
const int SLOT_MAX = 3;
const int K_MAX = 8;
const float TAU_ = 6.28318530718;
// Peak of the per-blob size jitter applied at `radius` below (0.7 + 0.6*h, h in
// [0,1]). The reach bounds MUST include it or they under-estimate by 30% and the
// gate starts rejecting blobs it should have drawn. FireBlobTuning.SIZE_JITTER_MAX
// mirrors this for the quad; the two must agree.
const float SIZE_JITTER_MAX = 1.3;

// highp is deliberate: level1 world coords reach ~1500, and a mediump (fp16)
// varying has ~1-unit precision at 1024 — it would visibly quantize the pixel
// grid. UNVERIFIED whether Godot's Compatibility backend already forces highp
// on WebGL2; the qualifier is cheap insurance either way. shader_debug == 2 is
// the check.
varying highp vec2 v_world;
varying flat highp vec2 v_origin;

vec3 stage_color(int stage) {
	if (stage <= 0) { return col_white; }
	if (stage == 1) { return col_yellow; }
	if (stage == 2) { return col_orange; }
	if (stage == 3) { return col_red; }
	return col_char;
}

void vertex() {
	// canvas_item MODEL_MATRIX is local -> canvas (world) space; the camera
	// lives in CANVAS_MATRIX, so this is camera-independent and world-locked.
	// The transform is affine, so linear interpolation of v_world is exact —
	// no perspective divide, no noperspective qualifier needed.
	v_world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
	v_origin = MODEL_MATRIX[3].xy;
}

void fragment() {
	// Integer cell-local pixel. Everything downstream is evaluated only here,
	// which is what produces hard faux-pixels locked to the tile texel grid.
	vec2 p = floor(v_world) - floor(v_origin);

	// --- Loop-invariant setup (rule 1). Depends only on uniforms.
	float life = max(lifetime, 0.0001);
	float ka = max(k_active, 1.0);
	// Widest a blob can ever be: full radius, times the size jitter's peak, times
	// the noise carve, times the stretch. Every one of those four is load-bearing
	// — drop any and the gate under-rejects.
	float r_eff_max = blob_max_radius * SIZE_JITTER_MAX * (1.0 + noise_amp) * max(stretch, 1.0);
	float y_reach = r_eff_max + 1.0;
	// Slots are spread across the emitter width. With slot_count == 1 the lone
	// slot sits dead centre, which is the kindling case.
	float slot_denom = max(float(slot_count), 1.0);

	float best_heat = -1.0;
	int best_stage = N_STAGES;
	vec2 best_q = vec2(0.0);
	float best_age = 0.0;

	for (int s = 0; s < SLOT_MAX; s++) {
		if (s >= slot_count) { break; }
		float sf = float(s);
		float slot_x = (slot_count == 1)
				? 0.0
				: mix(-base_half_width, base_half_width, sf / (slot_denom - 1.0));

		// Per-slot phase, hoisted out of the k loop so the inner loop needs no
		// hash before its gate.
		float slot_phase = _hash(vec2(sf * 1.37 + cell_seed, 3.0)).x * 0.5 + 0.5;

		for (int k = 0; k < K_MAX; k++) {
			if (float(k) >= ka) { break; }

			// Age from the CPU phase clock, NOT TIME/life (see blob_phase). The clock
			// advances at 1/life cycles/sec and is continuous when life changes, so
			// intensity can vary without re-scrambling blobs. slot_phase + k/k_active
			// staggers the slot's live blobs evenly up the column at any count.
			float phase = blob_phase + slot_phase + float(k) / ka;
			float an = fract(phase);
			// Age in seconds. an is the clock; life only SCALES it, so a lifetime
			// change stretches the seconds smoothly instead of jumping the normalised
			// age. dan/dt is still exactly 1/life, which keeps the analytic velocity
			// below correct.
			float a = an * life;

			// birth_idx increments once each time a blob respawns, so per-blob hashes
			// change exactly once per birth instead of flickering. (Same role as
			// rain's drop_idx.) floor() of the SAME continuous phase, so it is stable
			// under lifetime changes — the old floor(TIME/life) re-rolled every hash
			// on every intensity tick.
			float birth_idx = floor(phase);
			vec2 key = vec2(sf * 1.37 + float(k) * 0.713 + cell_seed, birth_idx + 7.0);

			// Per-blob rise speed. This is the ONE hash paid BEFORE the gate, and
			// it is unavoidable: speed decides y, and y is what the gate tests. So
			// the gate now costs ~1 _hash (fract-based, no sin) per candidate
			// instead of nothing. Keep it to this single hash — everything else
			// stays lazy (rule 2). Hashed off `key`, so a blob's speed is fixed for
			// its whole life and re-rolled on each rebirth, rather than changing
			// under it frame to frame.
			float speed_mult = 1.0 + _hash(key + vec2(0.0, 91.3)).x * rise_speed_jitter;

			// --- GATE (rules 2/3). y is still a direct, cheap function of age: the
			// gate only ever evaluates y FROM age, never inverts it, so the curve
			// can be any shape as long as it stays cheap. The gate stays EXACT for
			// any speed_mult because it compares against y itself, not against
			// column_height. What speed_mult does change is how far a blob travels
			// — which is why FireBlobTuning must size the quad to
			// column_height * (1 + rise_speed_jitter).
			float rise_t = an * mix(1.0, an, rise_curve);
			float y = -column_height * rise_t * speed_mult;
			if (abs(p.y - y) > y_reach) { continue; }

			// Only survivors pay for the rest (rule 2). Two _hash calls = 4
			// randoms, which is everything else a blob needs.
			vec2 hA = _hash(key) * 0.5 + 0.5;
			vec2 hB = _hash(key + vec2(17.3, 5.1)) * 0.5 + 0.5;

			// --- Turbulence. X-ONLY, so the y-gate above stays exact.
			// Amplitude ramps with age: blobs wander more the higher they get.
			float w1 = mix(turb_freq_min, turb_freq_max, hA.x);
			float w2 = w1 * 2.37;
			float ph1 = hA.y * TAU_;
			float ph2 = hB.x * TAU_;
			float s1 = sin(a * w1 + ph1);
			float s2 = sin(a * w2 + ph2);
			float sway = s1 + 0.5 * s2;
			// Wind lean: shear the rise about the cell base — 0 at the base, full
			// at the tip (-y is height above base, so -wind_lean*y pushes +X for
			// positive wind). X-only, so the y-gate above stays exact; the CPU quad
			// bound is sized for the max lean so leaning tips never clip.
			vec2 centre = vec2(slot_x + turb_amp * an * sway - wind_lean * y, y);

			// Radius grows from the kindling dot to the full blob, per spec.
			float radius = mix(blob_min_radius, blob_max_radius, an) * (0.7 + 0.6 * hB.y);
			float r_eff = radius * (1.0 + noise_amp);

			// --- Velocity is ANALYTIC (the derivatives of the sway and the rise
			// curve), so the stretch direction costs two cos() and no extra
			// sampling. d/da of [turb_amp * an * sway] and of
			// [-H * an*mix(1,an,rc) * speed_mult].
			// vy is bounded away from zero by (1 - rise_curve) > 0 AND by
			// speed_mult >= 1 - rise_speed_jitter > 0 (both uniforms' hint_ranges
			// stop short of the degenerate value), so vel is never zero and
			// normalize() is always safe.
			float dsway = w1 * cos(a * w1 + ph1) + 0.5 * w2 * cos(a * w2 + ph2);
			// vy first: the wind-lean term of dtx needs it. speed_mult scales vy
			// but not the sway term of dtx, so a slow blob's velocity is relatively
			// MORE horizontal and it leans into its sway harder — the same reason a
			// slow-rising ember drifts more than a fast one.
			float vy = -(column_height / life)
					* ((1.0 - rise_curve) + 2.0 * rise_curve * an) * speed_mult;
			// Wind lean adds -wind_lean*y to centre.x; d/da of that is -wind_lean*vy,
			// so folding it into dtx tilts vdir and the flame stretches ALONG its
			// lean with no extra sampling.
			float dtx = turb_amp * (sway / life + an * dsway) - wind_lean * vy;
			vec2 vdir = normalize(vec2(dtx, vy));
			vec2 perp = vec2(-vdir.y, vdir.x);

			// --- Exact axis-aligned bound of the ROTATED stretch ellipse
			// (semi-axis r_eff along perp, r_eff*stretch along vdir). Tighter
			// than a naive r_eff*stretch box, still conservative, +1 to absorb
			// the floor() and float slop.
			float ax = r_eff;
			float bx = r_eff * stretch;
			float half_x = sqrt(ax * ax * perp.x * perp.x + bx * bx * vdir.x * vdir.x) + 1.0;
			float half_y = sqrt(ax * ax * perp.y * perp.y + bx * bx * vdir.y * vdir.y) + 1.0;
			vec2 d = p - centre;
			if (abs(d.x) > half_x || abs(d.y) > half_y) { continue; }

			// --- Shape. Anisotropic: dividing the along-flow component
			// ELONGATES the blob along vdir. Applied to the SAMPLE COORDS
			// before the radial and noise evaluation, so the carve stretches
			// with the silhouette rather than being applied on top of it.
			vec2 ds = vec2(dot(d, perp), dot(d, vdir) / max(stretch, 0.0001));
			float r = length(ds) / max(radius, 0.0001);
			// Amorphous carve, in BLOB-LOCAL space so the texture travels with
			// the blob instead of swimming through it. The age term churns the
			// silhouette as it rises.
			r += _noise(ds * noise_scale + vec2(a * shape_evolve, hB.y * 64.0)) * noise_amp;

			// --- SILHOUETTE. This test is what makes the blob a blob, and it
			// must stay SEPARATE from the ramp below. Folding it into `heat`
			// looks equivalent but is not: the radial term there is scaled by
			// `an`, so a newborn blob (an ~ 0) would have heat ~ 1 at every r
			// and therefore no edge at all — the AABB gate becomes the shape and
			// every blob renders as a hard RECTANGLE. (Observed, not theorised.)
			if (r >= 1.0) { continue; }

			// --- The ramp. No interpolation, by design. heat <= 0 is the
			// "burned out" test — it erodes the silhouette inward from r=1 once
			// age passes 1/(1+radial_bias). For heat in (0,1] the stage is
			// automatically 0..4, so there is no out-of-range branch; the clamp
			// only catches heat > 1, which the noise carve can produce near the
			// centre by pushing r slightly negative.
			float heat = ((1.0 - an) - r * radial_bias * an) * heat_ceiling;
			if (heat <= 0.0) { continue; }
			int stage = clamp(int(floor((1.0 - heat) * float(N_STAGES))), 0, N_STAGES - 1);

			// Hottest sample wins where blobs overlap, so flame reads in front
			// of smoke rather than being covered by it.
			if (heat > best_heat) {
				best_heat = heat;
				best_stage = stage;
				best_q = ds;
				best_age = a;
			}
		}
	}

	if (best_stage >= N_STAGES) {
		COLOR = vec4(0.0);
	} else {
		vec3 col = stage_color(best_stage);
		float alpha = 1.0;
		// Palette-pure smoke thinning: drop whole texels, never blend. Hashed on
		// blob-local integer coords so the screen door rides with the blob
		// instead of being a static world-space grid.
		if (best_stage == N_STAGES - 1 && smoke_dither < 1.0) {
			float dh = _hash(floor(best_q) + vec2(best_age * 13.0, 3.0)).x * 0.5 + 0.5;
			if (dh > smoke_dither) { alpha = 0.0; }
		}
		COLOR = vec4(col, alpha);
	}

	if (shader_debug == 1) {
		// Stage index as a grey ramp — check the banding geometry without the
		// palette confusing the read. The rim index MUST exceed the core index.
		COLOR = vec4(vec3(float(best_stage) / float(N_STAGES - 1)), COLOR.a);
	} else if (shader_debug == 2) {
		// World-snap check. Pan the camera: this grid must stay glued to the
		// terrain and must not swim. If it does, the highp varying didn't take.
		COLOR = vec4(fract(v_world), 0.0, 1.0);
	} else if (shader_debug == 3) {
		// Quad rect. Nothing should be clipping at the edge; if it is,
		// FireBlobTuning.quad_size() is too small.
		COLOR = vec4(0.0, 1.0, 0.0, 0.25);
	}
}
