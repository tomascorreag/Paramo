shader_type canvas_item;

// Water surface shader for isometric tiles.
// Partially transparent with flow-direction-aware animation.
// Noise functions reused from wind.gdshader.

uniform vec2 flow_direction = vec2(0.0, 0.0);
uniform float flow_speed : hint_range(0.0, 5.0) = 1.0;
uniform float base_alpha : hint_range(0.0, 1.0) = 0.55;
uniform vec2 wave_scale = vec2(0.04, 0.04);
uniform vec2 wave_scale_2 = vec2(0.1, 0.1);
uniform float ripple_strength : hint_range(0.0, 0.5) = 0.12;
uniform float vertical_strength : hint_range(0.0, 8.0) = 2.0;
uniform float highlight_strength : hint_range(0.0, 1.0) = 0.25;
uniform float water_intensity : hint_range(0.0, 2.0) = 1.0;

// Quantization thresholds on `wave` (= combined_noise * highlight_strength * water_intensity).
// wave < lo_threshold          -> base texture color (unmodified)
// lo_threshold <= wave < hi_threshold -> wave_mid
// wave >= hi_threshold         -> wave_hi
uniform float lo_threshold : hint_range(-1.0, 1.0) = -0.15;
uniform float hi_threshold : hint_range(-1.0, 1.0) = 0.15;
uniform vec3 wave_mid : source_color = vec3(0.588, 0.663, 0.757); // #96a9c1
uniform vec3 wave_hi : source_color = vec3(0.733, 0.765, 0.816); // #bbc3d0

uniform int debug : hint_range(0, 3) = 0;

varying vec2 world_pos;

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

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	// Per-pixel world position, offset to align with tile texture grid
	vec2 sampled = round(world_pos + vec2(0.5, 0.5));

	// Flow scroll; still water uses slow circular drift
	vec2 scroll;
	if (length(flow_direction) < 0.01) {
		scroll = vec2(cos(TIME * 0.3), sin(TIME * 0.4)) * 0.5;
	} else {
		scroll = normalize(flow_direction) * flow_speed * TIME;
	}

	// Two noise layers for wave detail
	float n1 = _noise(sampled * wave_scale + scroll);
	float n2 = _noise(sampled * wave_scale_2 + scroll * 0.7 + vec2(43.0, 17.0));
	float combined = n1 * 0.6 + n2 * 0.4;

	// UV displacement: vertical color shift + flow ripple
	float intensity = water_intensity;
	float v_offset = round(combined * vertical_strength * intensity) * TEXTURE_PIXEL_SIZE.y;
	vec2 flow_off = round(flow_direction * combined * ripple_strength * intensity)
					 * TEXTURE_PIXEL_SIZE;
	vec4 tex = texture(TEXTURE, UV + flow_off + vec2(0.0, v_offset));

	// Discrete wave colors — low band keeps base texture, mid/hi are flat
	float wave = combined * highlight_strength * intensity;
	vec3 col;
	if (wave < lo_threshold) {
		col = tex.rgb;
	} else if (wave < hi_threshold) {
		col = wave_mid;
	} else {
		col = wave_hi;
	}

	// Alpha: base transparency, preserving sprite mask
	float alpha = tex.a * base_alpha;

	if (debug == 1) {
		COLOR = vec4(vec3(combined * 0.5 + 0.5), tex.a);
	} else {
		COLOR = vec4(col, alpha);
	}
}
