shader_type canvas_item;

// Teardrop ground shadow: elliptical cap near the player's feet,
// tapering to a point in the direction of shadow_length.
// Positive shadow_length = taper right, negative = taper left.

uniform vec4 shadow_color : source_color = vec4(0.0, 0.0, 0.05, 0.5);
uniform float shadow_length : hint_range(-64.0, 64.0) = 20.0;
uniform float max_height : hint_range(1.0, 16.0) = 4.0;
uniform float taper : hint_range(0.3, 3.0) = 0.7;
uniform float cap_width : hint_range(1.0, 32.0) = 16.0;
uniform float visual_y_offset = 0.0;
uniform float shadow_opacity : hint_range(0.0, 1.0) = 0.5;
uniform vec2 sprite_offset = vec2(0.0, -15.0);

// Material-driven vertical jitter. `roughness` is an integer pixel budget
// for each shadow pixel's y-offset into the teardrop shape test — 0 = smooth
// oval, higher = more broken silhouette. `noise_cell_px` chunks the hash so
// multiple adjacent pixels share a displacement (chunky jaggies, not per-
// pixel salt-and-pepper). The hash is keyed on the WORLD-pixel coord of
// each shadow pixel (derived from the quad origin + (qx, qy), not from
// interpolated world_pos) — pattern stays fixed to the ground as the
// entity walks, while each shadow pixel maps to exactly one hash bucket
// regardless of any sub-pixel quad drift from visual_y_offset lerps.
uniform float roughness : hint_range(0.0, 4.0) = 0.0;
uniform float noise_cell_px : hint_range(0.5, 32.0) = 2.0;
// How much of the entity's world motion the noise field tracks. 1.0 =
// fully world-locked (at 1× sprite speed the jaggies scroll past the
// sprite at 1× — combined with the sprite's own visible motion this reads
// as "twice as much motion"). 0.0 = fully sprite-locked (pattern glued to
// the silhouette, no scroll). 0.5 = half-speed drift, reducing the
// perceived doubling while still varying the pattern across tiles.
uniform float noise_world_follow : hint_range(0.0, 1.0) = 0.5;

// Altitude cutoff along the shadow's east/west taper direction. GDScript
// samples 3 cells in that direction and lerps `cutoff_x` (screen pixels
// from the entity's cell center along the taper axis) toward the far
// corner of the LAST MATCHING cell — 16 (own cell, immediate diagonal
// differs), 48 (next cell matches, second differs), 80 (next two match,
// third differs). The fragment uses this to build a diamond-shaped clip
// at that cell. Default = a value past the shadow's max extent (set by
// GDScript at runtime) → no visible clip. tile_size_px is the iso
// diamond's full extent (Godot's TileSet `tile_size`).
uniform float cutoff_x = 1000.0;
uniform vec2 tile_size_px = vec2(32.0, 16.0);

varying vec2 shadow_norm;
varying vec2 quad_origin_world;


// Deterministic [0,1) hash of an integer 2D lattice point.
float _hash2(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

// Value noise: bilinear interpolation of 4 integer-lattice hashes, with
// smoothstep weighting for a C1-continuous field. Output range [0, 1).
// Scale `p` by 1.0 / wavelength at the call site.
float _value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = _hash2(i);
	float b = _hash2(i + vec2(1.0, 0.0));
	float c = _hash2(i + vec2(0.0, 1.0));
	float d = _hash2(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}


void vertex() {
	vec2 normalized = (VERTEX - sprite_offset) / vec2(16.0, 16.0);
	shadow_norm = normalized;

	// Sprite's local origin (0,0) in world space. Constant across vertices —
	// every fragment gets the same value. Used in fragment to derive a
	// stable world-pixel coord per shadow pixel (see fragment comment).
	quad_origin_world = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xy;

	// Effective taper = abs + cap so the taper always extends beyond the cap.
	float abs_len = abs(shadow_length) + cap_width;
	float extent = max(cap_width, abs_len);
	float t = (normalized.x + 1.0) * 0.5;
	VERTEX.x = round(-extent + t * 2.0 * extent);
	// Quad SIZE is integer (round() on the span), but visual_y_offset is
	// added OUTSIDE the round so it stays smooth — it carries the player's
	// altitude lerp and y_visual_diff (sort-snap compensation). Rounding it
	// would re-snap the shadow vertically every step. MODEL_MATRIX handles
	// the horizontal sub-pixel tracking the same way.
	VERTEX.y = round(normalized.y * max_height) + visual_y_offset;
}

void fragment() {
	float abs_len = abs(shadow_length) + cap_width;
	float dir = shadow_length >= 0.0 ? 1.0 : -1.0;
	float extent = max(cap_width, abs_len);

	// Quantize interpolated position to integer canvas pixel within the quad.
	// (sn + 1) * extent ranges [0, 2*extent] across the quad. floor() tiles
	// exactly 2*extent pixels cleanly, so every canvas pixel maps to one
	// shadow pixel regardless of the quad's subpixel position — no edge
	// half-pixels like the previous floor(x + 0.5) scheme produced.
	float qx = floor((shadow_norm.x + 1.0) * extent);
	float qy = floor((shadow_norm.y + 1.0) * max_height);

	// Pixel center relative to the quad center, for shape evaluation.
	float cx = qx + 0.5 - extent;
	float cy = qy + 0.5 - max_height;

	// Altitude cutoff: clip the shadow at the iso-diamond edge of the LAST
	// matching cell along the taper direction. `cutoff_x` is the screen-px
	// distance from the entity cell center to that cell's far (east/west)
	// corner. The clip diamond is co-centered with the rendered shadow
	// (i.e. with the quad, which is itself offset from the entity's local
	// origin by `visual_y_offset`) so its east tip lands at the cell border
	// along the shadow's centerline — that's the line the eye reads as
	// "where the shadow ends at the tile edge". Only pixels on the taper
	// side of the cell center get tested; cap-side pixels never clip.
	float half_w = tile_size_px.x * 0.5;
	float half_h = tile_size_px.y * 0.5;
	float cell_center_cx = (cutoff_x - half_w) * dir;
	float dx = cx - cell_center_cx;
	if (dx * dir > 0.0 && abs(dx) / half_w + abs(cy) / half_h > 1.0) {
		discard;
	}

	// Material-driven vertical displacement. Sample position mixes the
	// entity's world origin (scaled by noise_world_follow) with the shadow
	// pixel's local offset from that origin. follow=1 pins the pattern to
	// the ground (scrolls past the sprite at 1× sprite speed, which stacks
	// with the sprite's own motion as "2× perceived"); follow=0 pins the
	// pattern to the silhouette; follow=0.5 is a half-speed drift across
	// the ground. Value noise is C1-continuous, so fractional sample
	// positions just slide the smooth field — no chunk-boundary artifacts.
	// dy is always floored to an integer, so the output stays binary per
	// shadow pixel (each pixel either at its original y or shifted by an
	// integer number of pixels).
	if (roughness > 0.0) {
		vec2 sample_pos =
			quad_origin_world * noise_world_follow
			+ vec2(qx - extent, qy - max_height + visual_y_offset);
		float h = _value_noise(sample_pos / noise_cell_px);
		// Signed sample spread across [-(roughness + 0.5), +(roughness + 0.5)),
		// floored to integer. The +0.5 ensures the ±1 boundary is inside
		// the range for any roughness > 0 (no dead zone below 1.0).
		float raw = (h - 0.5) * 2.0 * (roughness + 0.5);
		float dy = floor(raw + 0.5);
		cy += dy;
	}

	// Flip cx so cap is always on negative side, taper on positive side.
	float fcx = cx * dir;

	if (fcx < 0.0) {
		// Cap: ellipse (cap_width wide, max_height tall)
		float ex = fcx / cap_width;
		float ey = cy / max_height;
		if (ex * ex + ey * ey > 1.0) {
			discard;
		}
	} else {
		// Taper: full height at x=0, curves to 0 at x=abs_len
		float sx = fcx / abs_len;
		float h = pow(max(1.0 - sx, 0.0), taper);
		if (sx > 1.0 || abs(cy) / max_height > h) {
			discard;
		}
	}
	COLOR = vec4(shadow_color.rgb, shadow_color.a * shadow_opacity);
}
