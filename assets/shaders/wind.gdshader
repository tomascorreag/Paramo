shader_type canvas_item;

// Wind color-distortion for isometric tiles.
// Samples displaced colors via procedural noise in world space,
// keeping pixel positions and tile silhouette fixed.
//
// Low-end-GPU optimizations:
//  - `wind_scroll_per_second` precomputed on CPU (was: normalize(wind_strength + eps) * wind_speed
//    evaluated per-fragment on every wind tile every frame).
//  - `wind_mask_inv` precomputed on CPU (was: floor(wind_mask*32)/32 + a divide per fragment).
//    Stores 1.0 / snapped_mask; 0.0 signals "masked-out" (final mask is 0).
//  - Debug branch is guarded by a const bool so release builds strip it at compile time.

#include "res://assets/shaders/noise_common.gdshaderinc"

// Magnitude still used directly for the UV offset vector.
uniform vec2 wind_strength = vec2(1.0, 0.3);
uniform float wind_scale : hint_range(0.001, 0.2) = 0.05;

// Precomputed scroll per second (noise-space). = normalize(wind_strength) * wind_speed.
uniform vec2 wind_scroll_per_second = vec2(0.957, 0.287);

uniform vec2 wind_tiling = vec2(1.0, 1.0);
uniform vec2 wind_strength_2 = vec2(0.5, 0.15);
uniform float wind_scale_2 : hint_range(0.001, 0.5) = 0.12;

// Precomputed: snapped_mask = floor(wind_mask * 32.0) / 32.0;
// wind_mask_inv = snapped_mask > 0 ? 1.0/snapped_mask : 0.0 (0 means "masked-out").
// Examples: wind_mask 0.9 -> 1.142857; 0.85 -> 1.185185; 0.8 -> 1.28.
uniform float wind_mask_inv = 1.142857;

uniform float wind_intensity : hint_range(0.0, 2.0) = 1.0;
uniform vec2 wind_tile_size = vec2(32.0, 32.0);
uniform vec2 wind_tile_offset = vec2(0.5, 0.5);

const bool DEBUG_ENABLED = false;
uniform int wind_debug : hint_range(0, 3) = 0;

varying vec2 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec2 snapped = round(world_pos / 2.0);
	vec2 scroll = wind_scroll_per_second * TIME;

	float n1 = _noise(snapped * wind_scale * wind_tiling + scroll);
	float n2 = _noise(snapped * wind_scale_2 * wind_tiling + scroll + vec2(43.0, 17.0));

	// Tile-local Y from atlas UV, normalized 0..1 per tile.
	vec2 uv_offset = TEXTURE_PIXEL_SIZE * wind_tile_offset;
	float tile_y = fract((UV.y + uv_offset.y) / (wind_tile_size.y * TEXTURE_PIXEL_SIZE.y));
	float ty = floor(tile_y * 32.0) / 32.0;

	// Uniform branch: all fragments in a draw call take the same path.
	float mask = 0.0;
	if (wind_mask_inv > 0.0) {
		mask = floor((1.0 - ty * wind_mask_inv) * 32.0) / 32.0;
	}
	mask = max(mask, 0.0);

	vec2 offset = round((wind_strength * n1 + wind_strength_2 * n2) * mask * wind_intensity) * TEXTURE_PIXEL_SIZE;

	if (DEBUG_ENABLED && wind_debug == 1) {
		COLOR = vec4(vec3(UV.y), texture(TEXTURE, UV).a);
	} else if (DEBUG_ENABLED && wind_debug == 2) {
		COLOR = vec4(vec3(mask), texture(TEXTURE, UV).a);
	} else if (DEBUG_ENABLED && wind_debug == 3) {
		COLOR = vec4(vec3(tile_y), texture(TEXTURE, UV).a);
	} else {
		COLOR = texture(TEXTURE, UV + offset);
	}
}
