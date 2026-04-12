shader_type canvas_item;

// Teardrop ground shadow: elliptical cap at the player's feet,
// tapering to a point eastward.

uniform vec4 shadow_color : source_color = vec4(0.0, 0.0, 0.05, 0.5);
uniform float shadow_length : hint_range(4.0, 64.0) = 20.0;
uniform float max_height : hint_range(1.0, 16.0) = 4.0;
uniform float taper : hint_range(0.3, 3.0) = 0.7;
uniform float cap_width : hint_range(1.0, 32.0) = 16.0;
uniform float visual_y_offset = 0.0;

varying vec2 shadow_norm;

void vertex() {
	vec2 normalized = (VERTEX - vec2(0.0, -15.0)) / vec2(16.0, 16.0);
	shadow_norm = normalized;

	// Quad extends left by cap_width (round cap) and right by shadow_length
	float t = (normalized.x + 1.0) * 0.5;
	VERTEX.x = round(-cap_width + t * (cap_width + shadow_length));
	VERTEX.y = round(normalized.y * max_height + visual_y_offset);
}

void fragment() {
	float t = (shadow_norm.x + 1.0) * 0.5;
	float px = floor(-cap_width + t * (cap_width + shadow_length) + 0.5);
	float py = floor(shadow_norm.y * max_height + 0.5);

	if (px < 0.0) {
		// Left cap: ellipse (cap_width wide, max_height tall)
		float ex = px / cap_width;
		float ey = py / max_height;
		if (ex * ex + ey * ey > 1.0) {
			discard;
		}
	} else {
		// Right taper: full height at x=0, curves to 0 at x=shadow_length
		float sx = px / shadow_length;
		float h = pow(max(1.0 - sx, 0.0), taper);
		if (sx > 1.0 || abs(py) / max_height > h) {
			discard;
		}
	}
	COLOR = shadow_color;
}
