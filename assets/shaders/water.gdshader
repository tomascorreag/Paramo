shader_type canvas_item;

// Water surface shader for isometric tiles.
// Partially transparent with flow-direction-aware animation.
//
// Low-end-GPU optimizations:
//  - `scroll_velocity` is precomputed on the CPU (= normalize(flow_direction) * flow_speed
//    for flowing water, or a small drift for still water). Removes per-fragment
//    length/normalize/trig that used to run on every water tile.
//  - `flow_direction` is kept separately because its magnitude still shapes the
//    UV ripple offset.
//  - Debug branch is guarded by a const bool so release builds strip it at compile time.

#include "res://assets/shaders/noise_common.gdshaderinc"

// Precomputed scroll per second. Units: noise-space per second.
// Flowing: normalize(flow_direction) * flow_speed.
// Still: a small drift (e.g. (0.05, 0.04)) replaces the old per-fragment cos/sin wobble.
uniform vec2 scroll_velocity = vec2(0.05, 0.04);

// Still used (non-normalized) by the UV ripple offset path.
uniform vec2 flow_direction = vec2(0.0, 0.0);

uniform float base_alpha : hint_range(0.0, 1.0) = 0.55;
uniform vec2 wave_scale = vec2(0.04, 0.04);
uniform vec2 wave_scale_2 = vec2(0.1, 0.1);
uniform float ripple_strength : hint_range(0.0, 0.5) = 0.12;
uniform float vertical_strength : hint_range(0.0, 8.0) = 2.0;
uniform float highlight_strength : hint_range(0.0, 1.0) = 0.25;
uniform float water_intensity : hint_range(0.0, 2.0) = 1.0;

// Quantization thresholds on `wave` (= combined * highlight_strength * water_intensity).
uniform float lo_threshold : hint_range(-1.0, 1.0) = -0.15;
uniform float hi_threshold : hint_range(-1.0, 1.0) = 0.15;
uniform vec3 wave_mid : source_color = vec3(0.588, 0.663, 0.757); // #96a9c1
uniform vec3 wave_hi : source_color = vec3(0.733, 0.765, 0.816);  // #bbc3d0

// Compile-time stripped in release builds; set true when diagnosing.
const bool DEBUG_ENABLED = false;
uniform int debug : hint_range(0, 1) = 0;

varying vec2 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	// Per-pixel world position, offset to align with tile texture grid.
	// Must happen in fragment: rounding in vertex would linearly-interpolate
	// rounded corners and break per-pixel discretization.
	vec2 sampled = round(world_pos + vec2(0.5, 0.5));

	vec2 scroll = scroll_velocity * TIME;

	float n1 = _noise(sampled * wave_scale + scroll);
	float n2 = _noise(sampled * wave_scale_2 + scroll * 0.7 + vec2(43.0, 17.0));
	float combined = n1 * 0.6 + n2 * 0.4;

	// Shared scalar — avoids three separate `combined * water_intensity` multiplies.
	float ci = combined * water_intensity;
	float v_offset = round(ci * vertical_strength) * TEXTURE_PIXEL_SIZE.y;
	vec2 flow_off = round(flow_direction * (ci * ripple_strength)) * TEXTURE_PIXEL_SIZE;
	vec4 tex = texture(TEXTURE, UV + flow_off + vec2(0.0, v_offset));

	float wave = ci * highlight_strength;
	vec3 col;
	if (wave < lo_threshold) {
		col = tex.rgb;
	} else if (wave < hi_threshold) {
		col = wave_mid;
	} else {
		col = wave_hi;
	}

	float alpha = tex.a * base_alpha;

	if (DEBUG_ENABLED && debug == 1) {
		COLOR = vec4(vec3(combined * 0.5 + 0.5), tex.a);
	} else {
		COLOR = vec4(col, alpha);
	}
}
