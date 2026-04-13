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
	VERTEX.y = round(normalized.y * max_height + visual_y_offset);
}

void fragment() {
	float abs_len = abs(shadow_length) + cap_width;
	float dir = shadow_length >= 0.0 ? 1.0 : -1.0;
	float extent = max(cap_width, abs_len);

	float t = (shadow_norm.x + 1.0) * 0.5;
	float px = floor(-extent + t * 2.0 * extent + 0.5);
	float py = floor(shadow_norm.y * max_height + 0.5);

	// Flip px so the cap/taper test is always in canonical space
	// (cap on negative side, taper on positive side).
	float fpx = px * dir;

	if (fpx < 0.0) {
		// Cap: ellipse (cap_width wide, max_height tall)
		float ex = fpx / cap_width;
		float ey = py / max_height;
		if (ex * ex + ey * ey > 1.0) {
			discard;
		}
	} else {
		// Taper: full height at x=0, curves to 0 at x=abs_len
		float sx = fpx / abs_len;
		float h = pow(max(1.0 - sx, 0.0), taper);
		if (sx > 1.0 || abs(py) / max_height > h) {
			discard;
		}
	}
	COLOR = vec4(shadow_color.rgb, shadow_color.a * shadow_opacity);
}
