shader_type canvas_item;

// Wind color-distortion for isometric tiles.
// Samples displaced colors via procedural noise in world space,
// keeping pixel positions and tile silhouette fixed.
//
// Mask is tile-height-agnostic: per fragment, count opaque pixels directly
// below via an alpha probe. `opaque_below` rises with height above the dirt
// line in the current silhouette column. A 32-tall grass tile and a 48-tall
// grass tile share one material as long as their dirt portion is the same.
//
// Low-end-GPU notes:
//  - `wind_scroll_per_second` precomputed on CPU.
//  - Probe loop early-outs on first transparent sample and on mask saturation.
//  - Debug branch keyed by the project-level `shader_debug` int:
//      0 = off (default), 1 = mask viz, 2 = opaque_below viz. The shader
//      global is declared in project.godot [shader_globals]; all water/wind
//      materials read the same value so diagnostics toggle in lockstep.

#include "res://assets/shaders/noise_common.gdshaderinc"

uniform vec2 wind_strength = vec2(1.0, 0.3);
uniform float wind_scale : hint_range(0.001, 0.2) = 0.05;

// Precomputed scroll per second (noise-space). = normalize(wind_strength) * wind_speed.
uniform vec2 wind_scroll_per_second = vec2(0.957, 0.287);

uniform vec2 wind_tiling = vec2(1.0, 1.0);
uniform vec2 wind_strength_2 = vec2(0.5, 0.15);
uniform float wind_scale_2 : hint_range(0.001, 0.5) = 0.12;

// Silhouette-relative mask:
//   mask = clamp((opaque_below - wind_dirt_height_px) / wind_ramp_px, 0, 1)
// `wind_dirt_height_px` is the shared ground-portion thickness (pixels of
// opaque silhouette that should stay still). `wind_ramp_px` is the linear
// ramp from no-wind to full-wind above that, in pixels.
uniform float wind_dirt_height_px : hint_range(0.0, 64.0) = 4.0;
uniform float wind_ramp_px : hint_range(1.0, 64.0) = 28.0;

uniform float wind_intensity : hint_range(0.0, 2.0) = 1.0;

// Upper bound on the vertical probe; set to the tallest supported tile height.
// Loop bound must be a compile-time constant for GLES3 / WebGL2 targets.
const int WIND_PROBE_PX = 48;

// 0 = off, 1 = mask viz, 2 = opaque_below viz. See project.godot
// [shader_globals] — same uniform is read by water.gdshader.
global uniform int shader_debug;

varying vec2 world_pos;
varying vec4 v_modulate;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
	v_modulate = MODULATE;
}

void fragment() {
	vec2 snapped = round(world_pos / 2.0);
	vec2 scroll = wind_scroll_per_second * TIME;

	float n1 = _noise(snapped * wind_scale * wind_tiling + scroll);
	float n2 = _noise(snapped * wind_scale_2 * wind_tiling + scroll + vec2(43.0, 17.0));

	// Probe downward counting opaque pixels. Saturation cap lets most
	// fragments exit the loop well before WIND_PROBE_PX iterations.
	float saturate_at = wind_dirt_height_px + wind_ramp_px;
	float opaque_below = 0.0;
	for (int i = 1; i <= WIND_PROBE_PX; i++) {
		vec2 s = UV + vec2(0.0, float(i) * TEXTURE_PIXEL_SIZE.y);
		if (texture(TEXTURE, s).a < 0.1) { break; }
		opaque_below += 1.0;
		if (opaque_below >= saturate_at) { break; }
	}

	float mask = clamp((opaque_below - wind_dirt_height_px) / wind_ramp_px, 0.0, 1.0);
	mask = floor(mask * 32.0) / 32.0;

	vec2 offset = round((wind_strength * n1 + wind_strength_2 * n2) * mask * wind_intensity) * TEXTURE_PIXEL_SIZE;

	if (shader_debug == 1) {
		COLOR = vec4(vec3(mask), texture(TEXTURE, UV).a) * v_modulate;
	} else if (shader_debug == 2) {
		COLOR = vec4(vec3(opaque_below / float(WIND_PROBE_PX)), texture(TEXTURE, UV).a) * v_modulate;
	} else {
		COLOR = texture(TEXTURE, UV + offset) * v_modulate;
	}
}
