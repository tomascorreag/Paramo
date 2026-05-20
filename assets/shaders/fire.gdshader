shader_type canvas_item;

// Flame shader for the per-burning-cell AnimatedSprite2D flames.
//
// Sample point is snapped to the sprite's source-texel grid via
// floor(UV / TEXTURE_PIXEL_SIZE), so every fragment inside one sprite pixel
// produces the same shader output — shader pixels align exactly with sprite
// pixels (no sub-texel smearing from the upscaled viewport).
//
// Per-flame variation comes from `seed_offset` (written per-instance by
// BurningCellVFX / FireShaderPreview); two flames at any positions still
// desync because their seed_offsets differ.
//
// `color_intensity` controls the FRACTION of sprite texels swapped to the
// palette (binary per-texel decision, never a blend). 0 = all original sprite
// pixels; 1 = every texel replaced by the noise-selected palette band; 0.5 =
// roughly half of texels swapped. The mask uses its own noise channel so all
// three palette bands appear proportionally at any intensity.

#include "res://assets/shaders/noise_common.gdshaderinc"

uniform vec2 seed_offset = vec2(0.0, 0.0);

// Displacement: UV warp, quantized to texture pixels.
uniform vec2  disp_scale     = vec2(0.08, 0.05);
uniform vec2  disp_scroll    = vec2(0.0, -1.4);
uniform float disp_strength  : hint_range(0.0, 4.0) = 1.0;

// Color noise drives which palette band each texel falls into.
// `color_intensity` blends palette over source sprite RGB (0 = original, 1 = full palette).
uniform vec2  color_scale     = vec2(0.05, 0.04);
uniform vec2  color_scroll    = vec2(0.0, -0.9);
uniform float color_intensity : hint_range(0.0, 1.0) = 1.0;

uniform float lo_threshold : hint_range(-1.0, 1.0) = -0.10;
uniform float hi_threshold : hint_range(-1.0, 1.0) =  0.20;

uniform vec3 col_hi  : source_color = vec3(1.00, 0.93, 0.62);
uniform vec3 col_mid : source_color = vec3(1.00, 0.55, 0.12);
uniform vec3 col_lo  : source_color = vec3(0.62, 0.10, 0.06);

global uniform int shader_debug;

void fragment() {
	// color_intensity = 0 is an explicit passthrough: no displacement, no
	// palette, no anything — just the raw sprite. This is the unambiguous way
	// to express "original sprite color" and avoids any mix/clamp edge cases.
	if (color_intensity <= 0.001) {
		COLOR = texture(TEXTURE, UV);
	} else {
		// Snap to source-texel coordinates. Every fragment inside the same
		// sprite pixel produces the same `texel` value, so noise/displacement
		// vary at sprite-pixel granularity.
		vec2 texel = floor(UV / TEXTURE_PIXEL_SIZE);
		vec2 sampled = texel + seed_offset;

		// --- displacement ---
		vec2 ds = disp_scroll * TIME;
		vec2 dp = sampled * disp_scale;
		float dx = _noise(dp + ds);
		float dy = _noise(dp + ds + vec2(31.0, 19.0));
		vec2 disp = vec2(dx, dy);

		vec2 uv_off = round(disp * disp_strength) * TEXTURE_PIXEL_SIZE;
		vec2 uv_sample = clamp(
				UV + uv_off,
				TEXTURE_PIXEL_SIZE * 0.5,
				vec2(1.0) - TEXTURE_PIXEL_SIZE * 0.5);
		vec4 tex = texture(TEXTURE, uv_sample);

		// --- color noise (drives palette band selection per texel) ---
		vec2 cs = color_scroll * TIME;
		float n1 = _noise(sampled * color_scale + cs);
		float n2 = _noise(sampled * color_scale * 2.3 + cs * 0.7 + vec2(43.0, 17.0));
		float n  = n1 * 0.6 + n2 * 0.4;

		vec3 palette;
		if (n < lo_threshold) {
			palette = col_lo;
		} else if (n < hi_threshold) {
			palette = col_mid;
		} else {
			palette = col_hi;
		}

		// Per-texel binary swap: independent noise channel decides whether
		// this texel shows the original sprite color or the palette band.
		// `color_intensity` controls the threshold — high intensity → low
		// threshold → most texels swapped.
		float m_raw = _noise(sampled * color_scale * 1.7 + cs * 1.3 + vec2(11.0, 7.0));
		float mask = clamp(m_raw * 0.5 + 0.5, 0.0, 1.0);
		float swap_threshold = 1.0 - clamp(color_intensity, 0.0, 1.0);
		vec3 col = (mask > swap_threshold) ? palette : tex.rgb;

		if (shader_debug == 1) {
			COLOR = vec4(disp * 0.5 + 0.5, 0.0, tex.a);
		} else {
			COLOR = vec4(col, tex.a);
		}
	}
}
