shader_type canvas_item;

// Reprints world art as low-contrast INK on the field journal's paper: the
// frailejon sprite and the bridge/ladder tiles are drawn in the game's full
// palette, and dropping them onto a cream page unmodified reads as live game
// sprites pasted into a notebook rather than as sketches somebody made in it.
//
// This is a GRADIENT MAP, not a desaturate, and the difference is the whole
// reason it exists. The project locks every authored RGB to the 33 entries of
// assets/palettes/palette2.txt (see CLAUDE.md), and a luminance mix —
// mix(vec3(lum), col, saturation), the way post_process.gdshader does it —
// invents intermediate colours that are in no palette. Mapping luminance through
// CONSTANT-interpolation gradients instead means the output can only ever be one
// of the stops authored in resources/ui/journal_ink_*.tres. Palette-legal by
// construction.
//
// HUE-AWARE, in FOUR ramps rather than one: a single ramp makes every swatch the
// same colour, so a plant and a plank become indistinguishable washes. Each
// fragment's own hue picks its ramp, so flora stays green, wood stays brown and
// stone stays cool — coloured-pencil field sketches rather than one printing.
//
// The ramps are LOW CONTRAST by authoring, not by anything here: their darkest
// stops are lifted well off near-black while their lightest run up into the
// paper, so highlights dissolve into the page and shadows never punch out of it.
// Retune the LOOK on the .tres files; there is nothing to tune in this shader
// except where the hue boundaries fall.

// One ramp per hue family. filter_nearest matters: the gradients bake hard steps
// into the image, and linear filtering would blend ACROSS a step and hand back a
// colour that is not a stop — exactly what this shader exists to avoid.
// repeat_disable so a luminance of 0 or 1 cannot wrap to the far end.
uniform sampler2D ramp_warm : filter_nearest, repeat_disable;
uniform sampler2D ramp_green : filter_nearest, repeat_disable;
uniform sampler2D ramp_cool : filter_nearest, repeat_disable;
uniform sampler2D ramp_neutral : filter_nearest, repeat_disable;

// Below this saturation a fragment has no meaningful hue and goes to the neutral
// ramp. Keep it LOW: a frailejon's pale leaves are only weakly green, and a
// threshold that catches them turns the whole plant grey.
uniform float sat_threshold : hint_range(0.0, 1.0) = 0.12;

// Hue boundaries in TURNS (0 = red, 1/3 = green, 2/3 = blue). warm owns both ends
// of the wheel — reds and oranges below the first boundary, magentas and pinks
// above the last — because both are wood/earth tones in this project's art.
uniform float hue_warm_end : hint_range(0.0, 1.0) = 0.17;   // ~61 deg, past yellow
uniform float hue_green_end : hint_range(0.0, 1.0) = 0.47;  // ~170 deg, past cyan
uniform float hue_cool_end : hint_range(0.0, 1.0) = 0.88;   // ~317 deg, past violet

// 0 = untouched world art, 1 = pure ink. Between the two the result is NOT
// palette-legal (it is a blend), so anything shipped on the page wants 1.0; the
// uniform is here to A/B the mapping while tuning the ramps.
uniform float ink_amount : hint_range(0.0, 1.0) = 1.0;

// Output ALPHA multiplier — the journal shop draws a LOCKED swatch faded. A
// uniform rather than self_modulate because this shader overwrites COLOR and
// never multiplies the vertex modulate back in, so self_modulate is silently
// ignored on anything it draws (the trap this uniform exists to avoid). Alpha
// only: RGB stays a palette stop, per the palette rule.
uniform float dim : hint_range(0.0, 1.0) = 1.0;

// Rec.601 weights, the same ones post_process.gdshader grades with — kept
// identical so a swatch and the world it depicts agree about which parts of a
// sprite are the dark ones.
const vec3 LUMA = vec3(0.299, 0.587, 0.114);

// Hue in turns, 0 for a fully desaturated colour. Standard max/min derivation;
// GLSL's mod() is floor-based, so the red branch cannot come back negative.
float hue_of(vec3 c) {
	float mx = max(max(c.r, c.g), c.b);
	float mn = min(min(c.r, c.g), c.b);
	float d = mx - mn;
	if (d <= 0.0) {
		return 0.0;
	}
	float h;
	if (mx == c.r) {
		h = mod((c.g - c.b) / d, 6.0);
	} else if (mx == c.g) {
		h = (c.b - c.r) / d + 2.0;
	} else {
		h = (c.r - c.g) / d + 4.0;
	}
	return h / 6.0;
}

void fragment() {
	vec4 col = texture(TEXTURE, UV);
	float lum = dot(col.rgb, LUMA);

	float mx = max(max(col.r, col.g), col.b);
	float sat = mx > 0.0 ? (mx - min(min(col.r, col.g), col.b)) / mx : 0.0;
	float hue = hue_of(col.rgb);

	// A HARD pick, never a blend between two ramps: mixing two palette colours
	// yields one that is in no palette, which would quietly undo the guarantee the
	// CONSTANT gradients exist to provide. Exactly one weight below is 1.0 and the
	// rest are 0.0, so the weighted sum reproduces its ramp's stop bit for bit.
	float neutral = step(sat, sat_threshold);
	float chroma = 1.0 - neutral;
	float w_green = chroma * step(hue_warm_end, hue) * (1.0 - step(hue_green_end, hue));
	float w_cool = chroma * step(hue_green_end, hue) * (1.0 - step(hue_cool_end, hue));
	// Whatever chroma is left: the two ends of the wheel, which are both warm.
	float w_warm = chroma - w_green - w_cool;

	// All four are sampled UNCONDITIONALLY. A texture fetch inside non-uniform
	// control flow has undefined derivatives, and this project ships WebGL2 where
	// that is not a theoretical concern — selecting after the fetch is the safe
	// shape, and four fetches on three 32x32 swatches costs nothing.
	vec2 at = vec2(lum, 0.5);
	vec3 ink = neutral * texture(ramp_neutral, at).rgb
		+ w_warm * texture(ramp_warm, at).rgb
		+ w_green * texture(ramp_green, at).rgb
		+ w_cool * texture(ramp_cool, at).rgb;

	// Alpha is passed through untouched: the swatches are cut-out sprites and the
	// page has to show through everywhere they are empty.
	COLOR = vec4(mix(col.rgb, ink, ink_amount), col.a * dim);
}
