shader_type canvas_item;

// Pixelated burn-away dissolve for the grass overlay sprite placed on top of
// a burning tile. As `burn_amount` rises from 0 to 1, source pixels are
// discarded in a noise-driven random order, revealing whatever is painted
// underneath (the dirt tile). A char tint also bleeds in before the dissolve
// completes so the grass darkens before vanishing.

uniform float burn_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec4 char_color : source_color = vec4(0.10, 0.07, 0.05, 1.0);
uniform float char_mix_at : hint_range(0.0, 1.0) = 0.35;
uniform float noise_scale : hint_range(0.1, 64.0) = 8.0;

#include "res://assets/shaders/noise_common.gdshaderinc"

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	if (c.a < 0.01) {
		discard;
	}

	// Pixelated dissolve: snap to one noise sample per source texel so the
	// burn looks pixel-art-accurate, not per-fragment fuzz.
	vec2 pix_uv = floor(UV / TEXTURE_PIXEL_SIZE) * TEXTURE_PIXEL_SIZE;
	float n = _hash(pix_uv * noise_scale * 100.0).x * 0.5 + 0.5;

	// Char tint ramps in before the dissolve completes.
	float char_t = smoothstep(char_mix_at, 1.0, burn_amount);
	c.rgb = mix(c.rgb, char_color.rgb, char_t);

	if (n < burn_amount) {
		discard;
	}

	COLOR = c;
}
