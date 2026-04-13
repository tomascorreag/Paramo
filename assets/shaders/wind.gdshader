shader_type canvas_item;

// Wind color-distortion for isometric tiles.
// Samples displaced colors via procedural noise in world space,
// keeping pixel positions and tile silhouette fixed.

uniform vec2 wind_strength = vec2(1.0, 0.3);
uniform float wind_scale : hint_range(0.001, 0.2) = 0.05;
uniform float wind_speed : hint_range(0.0, 10.0) = 2.0;
uniform vec2 wind_tiling = vec2(1.0, 1.0);
uniform vec2 wind_strength_2 = vec2(0.5, 0.15);
uniform float wind_scale_2 : hint_range(0.001, 0.5) = 0.12;
uniform float wind_mask : hint_range(0.0, 1.0) = 1.0;
uniform float wind_intensity : hint_range(0.0, 2.0) = 1.0;
uniform vec2 wind_tile_size = vec2(32.0, 32.0);
uniform vec2 wind_tile_offset = vec2(0.5, 0.5);
uniform int wind_debug : hint_range(0, 3) = 0;

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
	vec2 snapped = round(world_pos / 2.0);
	vec2 scroll = normalize(wind_strength + vec2(0.0001)) * wind_speed * TIME;

	float n1 = _noise(snapped * wind_scale * wind_tiling + scroll);
	float n2 = _noise(snapped * wind_scale_2 * wind_tiling + scroll + vec2(43.0, 17.0));

	// Tile-local Y from atlas UV, normalized 0..1 per 32-texel tile
	vec2 uv_offset = TEXTURE_PIXEL_SIZE * wind_tile_offset;
	float tile_y = fract((UV.y + uv_offset.y) / (wind_tile_size.y * TEXTURE_PIXEL_SIZE.y));
	float tile_x = fract((UV.x + uv_offset.x) / (wind_tile_size.x * TEXTURE_PIXEL_SIZE.x));
	float ty = floor(tile_y * 32.0) / 32.0;
	float snapped_mask = floor(wind_mask * 32.0) / 32.0;
	float mask = snapped_mask > 0.0 ? floor((1.0 - ty / snapped_mask) * 32.0) / 32.0 : 0.0;
	mask = max(mask, 0.0);

	vec2 offset = round((wind_strength * n1 + wind_strength_2 * n2) * mask * wind_intensity) * TEXTURE_PIXEL_SIZE;

	if (wind_debug == 1) {
		// Raw UV.y as grayscale
		COLOR = vec4(vec3(UV.y), texture(TEXTURE, UV).a);
	} else if (wind_debug == 2) {
		// Mask as grayscale
		COLOR = vec4(vec3(mask), texture(TEXTURE, UV).a);
	} else if (wind_debug == 3) {
		// fract tile_y — should show one clean black→white gradient per tile
		COLOR = vec4(vec3(tile_y), texture(TEXTURE, UV).a);
	} else {
		COLOR = texture(TEXTURE, UV + offset);
	}
}
