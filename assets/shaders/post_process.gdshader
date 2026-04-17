shader_type canvas_item;

// Full-screen post-process: color grading + vignette.
// Applied via a ColorRect on a high CanvasLayer that reads the screen texture.
//
// Low-end-GPU optimizations:
//  - Vignette uses squared distance (dot) instead of length() to avoid a per-pixel sqrt
//    on every pixel of the screen. Falloff curve shape is imperceptibly different.
//  - `tint_color` is vec3 (alpha was never read). Godot accepts Color -> vec3 at runtime.

uniform sampler2D screen_texture : hint_screen_texture, filter_nearest;

uniform float color_temperature : hint_range(-1.0, 1.0) = 0.0;
uniform float contrast : hint_range(0.5, 1.5) = 1.0;
uniform float saturation : hint_range(0.0, 2.0) = 1.0;
uniform float brightness : hint_range(-0.5, 0.5) = 0.0;
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.0;
uniform float vignette_radius : hint_range(0.0, 1.0) = 0.5;
uniform vec3 tint_color : source_color = vec3(1.0, 1.0, 1.0);
uniform float tint_strength : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	vec3 col = texture(screen_texture, SCREEN_UV).rgb;

	// Brightness
	col += vec3(brightness);

	// Contrast (pivot at 0.5)
	col = (col - 0.5) * contrast + 0.5;

	// Saturation (luminance-preserving desaturation)
	float lum = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(vec3(lum), col, saturation);

	// Color temperature (warm shifts red up / blue down, cool does the opposite)
	col.r += color_temperature * 0.1;
	col.b -= color_temperature * 0.1;

	// Tint overlay
	col = mix(col, col * tint_color, tint_strength);

	// Vignette via squared distance: compare dist² against radius² (avoids sqrt).
	vec2 uv_centered = SCREEN_UV - 0.5;
	float dist_sq = dot(uv_centered, uv_centered);
	float r0 = vignette_radius * vignette_radius;
	float r1 = (vignette_radius + 0.5) * (vignette_radius + 0.5);
	float vignette = smoothstep(r0, r1, dist_sq);
	col *= 1.0 - vignette * vignette_strength;

	COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), 1.0);
}
