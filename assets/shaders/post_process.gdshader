shader_type canvas_item;

// Full-screen post-process: color grading + vignette.
// Applied via a ColorRect on a high CanvasLayer that reads the screen texture.

uniform sampler2D screen_texture : hint_screen_texture, filter_nearest;

uniform float color_temperature : hint_range(-1.0, 1.0) = 0.0;
uniform float contrast : hint_range(0.5, 1.5) = 1.0;
uniform float saturation : hint_range(0.0, 2.0) = 1.0;
uniform float brightness : hint_range(-0.5, 0.5) = 0.0;
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.0;
uniform float vignette_radius : hint_range(0.0, 1.0) = 0.5;
uniform vec4 tint_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
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
	col = mix(col, col * tint_color.rgb, tint_strength);

	// Vignette
	vec2 uv_centered = SCREEN_UV - 0.5;
	float dist = length(uv_centered);
	float vignette = smoothstep(vignette_radius, vignette_radius + 0.5, dist);
	col *= 1.0 - vignette * vignette_strength;

	COLOR = vec4(clamp(col, vec3(0.0), vec3(1.0)), 1.0);
}
