shader_type canvas_item;
render_mode blend_premul_alpha;

// World-anchored pixel rain.
//
// Uses premultiplied-alpha blending so each drop can carry a small additive
// lift on top of the normal alpha-mix: that lift is what keeps drops visible
// when they pass over tiles whose color is similar to the rain color. The
// engine blend formula is dst = src.rgb + dst.rgb * (1 - src.a), so any rgb
// contribution beyond `light * alpha` adds directly to whatever's underneath.
//
// Pattern math runs in WORLD-space coords (SCREEN_UV scaled then offset by the
// camera's top-left in world space) so streaks and splashes stay glued to the
// world as the camera moves.
//
// The world is divided into a grid of cells (column_spacing wide, cell_height
// tall). Each cell hosts K_DROPS_PER_CELL drops with staggered phases (drop j
// is offset by j/K of one cycle_period from drop 0). Per-drop properties —
// alpha, splash decision, splash_y — are hashed independently, so each drop
// in a cell is a distinct rain instance.
//
// The column grid lives in SHEARED-X space (sheared_x = world_px.x -
// streak_angle * world_px.y). In sheared space a diagonally-falling drop is
// vertical, so all the per-cell math (col_idx, anchor_x, hashing, head_y) is
// unchanged from when rain fell straight down. Only the final pixel test
// (streak_x and splash particle pxf) un-shears back to real space, which is
// what makes the entire drop — not just its silhouette — travel along the
// angle. Locality is preserved, so the ±SPLASH_X_RADIUS neighborhood search
// in fragment() doesn't have to grow with the angle.
//
// Drops "spawn" at cell_top each cycle. To hide that as a visible world-Y
// line, every drop fades in over its first seg_len pixels of fall — at the
// spawn pixel itself alpha is 0, full strength once the head has fallen one
// streak length. Combined with K staggered phases (one drop spawns every
// cycle_period/K seconds at each cell_top), spawns are imperceptible: they're
// frequent, off-center, and never start with a hard pixel.
//
// The static column properties (speed, phase offset, streak length) are
// hashed from col_idx ONLY so all cells in a column share the same cycle
// timing.
//
// Each drop has at most one splash event per cycle, at a random y inside its
// cell, gated by splash_probability. When the head reaches splash_y the drop
// dies and the splash particles emit for splash_dwell. No phantom splashes
// below the death point: a drop has exactly one splash_y, not multiple slots.
//
// `tint_color` is set externally to the current DayNight background fill, so
// rain takes on the ambient hue (warm at dusk, cool/dark at night, bright at
// noon). Multiplied with rain_color before adding to the screen.

uniform vec4 rain_color : source_color = vec4(0.75, 0.82, 0.95, 0.6);
uniform vec4 tint_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float tint_intensity : hint_range(0.0, 1.0) = 1.0;
uniform float additive_boost : hint_range(0.0, 1.0) = 0.15;
uniform float rain_amount : hint_range(0.0, 1.0) = 0.5;
uniform float column_spacing : hint_range(1.0, 16.0) = 2.0;
uniform float cell_height : hint_range(32.0, 1024.0) = 270.0;
uniform float fall_speed : hint_range(1.0, 800.0) = 220.0;
uniform float streak_length : hint_range(1.0, 32.0) = 10.0;
uniform float streak_angle : hint_range(-0.6, 0.6) = 0.12;
uniform float splash_min_y : hint_range(0.0, 1.0) = 0.25;
uniform float splash_dwell : hint_range(0.0, 0.5) = 0.15;
uniform float splash_size : hint_range(0.0, 4.0) = 1.0;
uniform float splash_probability : hint_range(0.0, 1.0) = 1.0;
uniform float streak_alpha_variation : hint_range(0.0, 1.0) = 0.5;
uniform vec2 viewport_size = vec2(480.0, 270.0);
uniform vec2 camera_offset = vec2(0.0);

// --- Lantern (single point light driven by PlayerLightController) -----------
// All values are pushed each frame by scripts/vfx/rain.gd. When the lantern is
// off, `lantern_energy` is 0 and `lantern_factor` short-circuits to 0, so the
// rain renders exactly as it did before this feature.
//
// `lantern_pos_view` is the lantern's world position MINUS camera_offset,
// computed CPU-side to avoid float precision loss far from the world origin.
// Comparison happens in the same view-space (world_px - camera_offset).
uniform vec2 lantern_pos_view = vec2(-9999.0);
uniform vec2 lantern_radius_px = vec2(256.0, 128.0);
uniform float lantern_energy : hint_range(0.0, 1.0) = 0.0;
uniform vec4 lantern_color : source_color = vec4(1.0, 0.725, 0.45, 1.0);
uniform float lantern_color_mix : hint_range(0.0, 1.0) = 0.6;
uniform float lantern_lift_gain : hint_range(0.0, 4.0) = 1.5;

float hash1(float n) {
	return fract(sin(n * 91.3458) * 47453.5453);
}

float hash2(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Proximity-to-lantern factor in [0..1]. 1 at the lantern center, 0 at the
// edge of the ellipse defined by lantern_radius_px (xy independent so the
// isometric squash is respected). Scaled by lantern_energy so the fade-in /
// fade-out animates for free.
float lantern_factor(vec2 px_view) {
	if (lantern_energy <= 0.0) {
		return 0.0;
	}
	vec2 d = (px_view - lantern_pos_view) / max(lantern_radius_px, vec2(1.0));
	float r = length(d);
	return (1.0 - smoothstep(0.0, 1.0, r)) * lantern_energy;
}

// Compute the drop contribution at world_px for the drop owned by
// (col_idx, cell_row). Returns rgba — zero alpha means nothing to draw.
//
// `speed` deliberately does NOT depend on rain_amount. The shader is
// stateless, so `head_y = mod(TIME, cell_height/speed) * speed` will jump
// (sometimes backwards/upward) any frame `speed` changes. rain_amount is
// noise-modulated each frame by the rain controller, so coupling speed to it
// produced a visible stall/reversal in sync with the noise wave. Density
// (the h_alive gate) and alpha (amt_alpha) carry the "heavier rain reads
// heavier" signal instead.
vec4 compute_drop(float col_idx, float cell_row, vec2 world_px,
		float amt_alpha) {
	// All "static" drop properties (alive, phase, speed, streak length) depend
	// ONLY on col_idx. This synchronizes every drop in the same column across
	// all cell rows: when cell N's drop wraps back to its cell_top, cell N-1's
	// drop is simultaneously at cell_top_N (= cell_bottom_{N-1}). The two
	// visually meet at the same world pixel, so the chain looks continuous and
	// no spawn point is visible mid-screen.
	float h_alive = hash1(col_idx + 101.0);
	if (h_alive > rain_amount) {
		return vec4(0.0);
	}

	float h_phase = hash1(col_idx + 1.0);
	float h_speed = hash1(col_idx + 17.0);
	float h_len   = hash1(col_idx + 53.0);

	float speed = fall_speed * (0.8 + 0.4 * h_speed);
	float seg_len = max(1.0, streak_length + (h_len - 0.5) * 2.0);

	float cycle_period = cell_height / speed;
	// Per-column phase offset on cell_top scatters the cell-row boundaries
	// across columns. Without it, every column's drops fade in (and splash
	// out) at the same world-Y, summing into a visible horizontal seam at
	// each cell boundary. The offset is hashed from col_idx only, so it's
	// stable across frames and identical for every cell_row in this column —
	// the drop_idx invariant and per-column chain continuity are preserved.
	// fragment() computes the row index per column so this offset is applied
	// consistently.
	float cell_top = (cell_row + hash1(col_idx + 200.0)) * cell_height;
	float anchor_x = (col_idx + 0.5) * column_spacing;
	float splash_dwell_clamped = max(0.001, splash_dwell);

	// tint_intensity lerps between untinted rain_color (0.0) and full ambient
	// modulation (1.0). At 1.0 rain matches scene lighting; at 0.0 rain ignores
	// it and stays whatever the inspector rain_color is.
	vec3 effective_tint = mix(vec3(1.0), tint_color.rgb, tint_intensity);
	vec3 light = rain_color.rgb * effective_tint;

	// Lantern bias: warm the rgb toward lantern_color and amplify the additive
	// lift, both scaled by proximity. lk == 0 when the lantern is off or the
	// pixel is outside the radius, so the rest of the math is a no-op then.
	float lk = lantern_factor(world_px - camera_offset);
	vec3 lit = mix(light, light * lantern_color.rgb, lk * lantern_color_mix);
	float lift_mul = 1.0 + lk * lantern_lift_gain;

	// Particle constants reused by every drop's splash.
	const int K_DROPS_PER_CELL = 4;
	const int N_PARTICLES = 6;
	const int TRAIL_LEN = 3;
	const float TRAIL_DT = 0.025;
	const float GRAVITY = 220.0;
	const float X_TRAVEL_LIMIT = 4.0;
	float base_speed_p = 30.0 * splash_size;
	float vx_cap = X_TRAVEL_LIMIT / splash_dwell_clamped;
	float vx_speed = min(base_speed_p, vx_cap);

	vec4 best = vec4(0.0);

	// Iterate the K drops in this cell. Each has staggered phase j/K relative
	// to the column's base phase, an independent splash decision, an
	// independent splash_y, and an independent random alpha.
	for (int j = 0; j < K_DROPS_PER_CELL; j++) {
		float jf = float(j);
		float drop_phase = h_phase + jf / float(K_DROPS_PER_CELL);
		float t_off = TIME + drop_phase * cycle_period;
		float cycle_idx_j = floor(t_off / cycle_period);
		float t_in_cycle_j = mod(t_off, cycle_period);
		float head_y_world = cell_top + t_in_cycle_j * speed;

		// drop_idx (= cell_row - cycle_idx) is the invariant across wraps —
		// when the drop transitions from (cell N, cycle C) to (cell N+1,
		// cycle C+1) both numbers shift by 1 and drop_idx stays the same. So
		// the per-drop hashes don't flicker as the chain crosses cell rows.
		float drop_idx_j = cell_row - cycle_idx_j;
		vec2 drop_key = vec2(col_idx + jf * 0.713, drop_idx_j + 7.0);

		float h_alpha = hash2(drop_key);
		float h_splash_fire = hash2(drop_key + vec2(0.11, 0.0));
		float h_splash_norm = hash2(drop_key + vec2(0.0, 0.13));

		float alpha_mult = mix(1.0 - streak_alpha_variation, 1.0, h_alpha);

		bool drop_splashes = h_splash_fire < splash_probability;
		float splash_y_world = cell_top + cell_height + 1.0;
		if (drop_splashes) {
			float splash_norm = mix(splash_min_y, 1.0, h_splash_norm);
			splash_y_world = floor(cell_top + splash_norm * cell_height);
		}

		// --- STREAK: alive while head hasn't reached splash_y. Clipped to
		// the cell's own vertical range (no tail leak above cell_top), and
		// faded in over the first seg_len pixels of fall so spawns don't
		// look like a hard pop-in at cell_top.
		if (head_y_world < splash_y_world) {
			float dy = head_y_world - world_px.y;
			if (dy >= 0.0 && dy < seg_len
					&& world_px.y < splash_y_world
					&& world_px.y >= cell_top) {
				// anchor_x is the column's SHEARED center. Un-shear at this
				// row to get the streak's real-x. Because the streak is a
				// vertical segment in sheared space, this single expression
				// places every row of the streak onto the diagonal path the
				// head actually travels — so the drop falls along the angle
				// instead of merely being tilted.
				float streak_x = anchor_x + streak_angle * world_px.y;
				if (world_px.x == floor(streak_x)) {
					float head_fade = 1.0 - dy / seg_len;
					float fadein = clamp((head_y_world - cell_top) / seg_len, 0.0, 1.0);
					float a = rain_color.a * head_fade * amt_alpha * alpha_mult * fadein;
					float lift = additive_boost * head_fade * amt_alpha * alpha_mult * fadein * lift_mul;
					vec4 c = vec4(lit * a + lit * lift, a);
					if (c.a > best.a) {
						best = c;
					}
					continue;
				}
			}
		}

		// --- SPLASH: one event per drop per cycle (if drop_splashes), at
		// splash_y_world. Particles burst in random directions, mostly
		// upward (vy ricochet) with gravity pulling them back.
		if (drop_splashes) {
			float t_after = (head_y_world - splash_y_world) / speed;
			if (t_after >= 0.0 && t_after < splash_dwell_clamped) {
				float age = t_after / splash_dwell_clamped;
				float fade = 1.0 - age;

				// Splash emits at the drop's REAL position when the head
				// reaches splash_y_world. anchor_x is sheared, so un-shear at
				// splash_y to get the emission x in real space. Particles
				// then fly through real space under real gravity (pyf is
				// untouched — gravity is vertical regardless of streak_angle).
				float splash_x_real = anchor_x + streak_angle * splash_y_world;

				float slot_best_intensity = 0.0;
				for (int k = 0; k < N_PARTICLES; k++) {
					float kf = float(k);
					vec2 phash_key = drop_key + vec2(kf * 1.31, 7.0);
					float h_vx = hash2(phash_key);
					float h_vy = hash2(phash_key + vec2(0.0, 0.5));
					float vx = (h_vx * 2.0 - 1.0) * vx_speed;
					float vy = (h_vy * 1.3 - 1.0) * base_speed_p;
					for (int i = 0; i < TRAIL_LEN; i++) {
						float sample_t = t_after - float(i) * TRAIL_DT;
						if (sample_t < 0.0) {
							break;
						}
						float pxf = splash_x_real + vx * sample_t;
						float pyf = splash_y_world + vy * sample_t + 0.5 * GRAVITY * sample_t * sample_t;
						if (world_px.x == floor(pxf) && world_px.y == floor(pyf)) {
							float trail_intensity = 1.0 - float(i) / float(TRAIL_LEN);
							if (trail_intensity > slot_best_intensity) {
								slot_best_intensity = trail_intensity;
							}
							break;
						}
					}
				}

				if (slot_best_intensity > 0.0) {
					float a = rain_color.a * fade * amt_alpha * slot_best_intensity * alpha_mult;
					float lift = additive_boost * fade * amt_alpha * slot_best_intensity * alpha_mult * lift_mul;
					vec4 c = vec4(lit * a + lit * lift, a);
					if (c.a > best.a) {
						best = c;
					}
				}
			}
		}
	}

	return best;
}

void fragment() {
	vec2 world_px = floor(SCREEN_UV * viewport_size + camera_offset);

	// Sheared-X domain: a drop falling diagonally in real space is vertical
	// in sheared space. col_idx, anchor_x, and all per-cell hashing live in
	// sheared X; only the streak's pixel test and splash particle origins
	// un-shear back to real space. See the header comment.
	float sheared_x = world_px.x - streak_angle * world_px.y;
	float col_idx = floor(sheared_x / column_spacing);

	float amt_alpha = pow(rain_amount, 0.7);

	// Neighborhood search (in SHEARED columns — see header comment):
	//  - 3 rows (above / self / below) so streak tails and splash particles
	//    that cross cell-row boundaries still get rendered.
	//  - 9 columns (±SPLASH_X_RADIUS) so splash particles that fly sideways
	//    out of their origin column still get rendered at the fragment's
	//    column. Bound = SPLASH_X_RADIUS × column_spacing pixels of sheared
	//    drift. Sheared drift = real X-travel + streak_angle × Y-travel; at
	//    splash_dwell=0.15 the Y bound is ~5 px, so even at streak_angle=0.6
	//    the worst-case sheared drift is ~7 px — within ±8 px at the default
	//    column_spacing=2.
	// Streak rendering stays purely in its own sheared column (single-pixel
	// test along the diagonal), so neighbor-column iteration only ever
	// contributes splash hits.
	const int SPLASH_X_RADIUS = 4;
	vec4 best = vec4(0.0);
	for (int dx = -SPLASH_X_RADIUS; dx <= SPLASH_X_RADIUS; dx++) {
		// Per-column row index: each column has its own hashed cell_top phase
		// (see compute_drop), so the cell this world_px.y falls into differs
		// per column. Compute the row relative to that column's grid.
		float c_idx = col_idx + float(dx);
		float h_cp = hash1(c_idx + 200.0);
		float r_base = floor(world_px.y / cell_height - h_cp);
		for (int dr = -1; dr <= 1; dr++) {
			vec4 c = compute_drop(
				c_idx,
				r_base + float(dr),
				world_px, amt_alpha);
			if (c.a > best.a) {
				best = c;
			}
		}
	}
	COLOR = best;
}
