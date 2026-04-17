// Shared value-noise helpers for canvas_item shaders (water, wind, etc.).
// Godot 4.1+ include. Included via: #include "res://assets/shaders/noise_common.gdshaderinc"

vec2 _hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xx + p3.yz) * p3.zy) * 2.0 - 1.0;
}

float _noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(dot(_hash(i), f),
			dot(_hash(i + vec2(1.0, 0.0)), f - vec2(1.0, 0.0)), u.x),
		mix(dot(_hash(i + vec2(0.0, 1.0)), f - vec2(0.0, 1.0)),
			dot(_hash(i + vec2(1.0, 1.0)), f - vec2(1.0, 1.0)), u.x),
		u.y
	);
}
