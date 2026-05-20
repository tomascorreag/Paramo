shader_type canvas_item;

// Charring + dissolve for a frailejon sprite. Same pixel-snapped dissolve
// pattern as burn_dissolve.gdshader, but the char tint kicks in much earlier
// so the plant visibly blackens before pixels start vanishing.

uniform float burn_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec4 char_color : source_color = vec4(0.06, 0.05, 0.04, 1.0);
uniform float char_mix_at : hint_range(0.0, 1.0) = 0.05;
uniform float noise_scale : hint_range(0.1, 64.0) = 8.0;

#include "res://assets/shaders/noise_common.gdshaderinc"

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	if (c.a < 0.01) {
		discard;
	}

	vec2 pix_uv = floor(UV / TEXTURE_PIXEL_SIZE) * TEXTURE_PIXEL_SIZE;
	float n = _hash(pix_uv * noise_scale * 100.0).x * 0.5 + 0.5;

	float char_t = smoothstep(char_mix_at, 1.0, burn_amount);
	c.rgb = mix(c.rgb, char_color.rgb, char_t);

	if (n < burn_amount) {
		discard;
	}

	COLOR = c;
}
