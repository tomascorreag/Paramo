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

varying vec2 shadow_norm;

void vertex() {
	vec2 normalized = (VERTEX - sprite_offset) / vec2(16.0, 16.0);
	shadow_norm = normalized;

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
