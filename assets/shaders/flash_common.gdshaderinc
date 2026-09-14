// Placement / discovery flash, shared by wind.gdshader (swaying plants) and
// flash.gdshader (everything else). See dev-notes/vfx.md "Spawn flash".
//
// Two independent effects on one material:
//
//  REVEAL — the arrival. Texels appear in a DITHERED GRADIENT that travels
//  from `reveal_from` to `reveal_to` (world space) as `reveal_amount` runs
//  0 -> 1: a 4x4 Bayer threshold in TEXEL space, offset by how far along the
//  travel direction the fragment sits, with a soft band `reveal_band` wide
//  (as a fraction of the from->to span). Every texel is either fully there
//  or not there at all, so nothing off-palette is invented on the way in.
//  Texel space, not FRAGCOORD: the integer upscale is per monitor.
//
//  FLASH — the punctuation. `flash_color` is composited over the sprite at
//  `flash_amount` opacity, a plain mix: 1.0 is the flat flash colour, 0.0 is
//  the sprite. This is the alpha-fade path (alpha is free under the palette
//  rule; a white sprite at alpha t over the art is exactly this mix).
//
// Both default to "off" (reveal 1.0, flash 0.0), so a material that never
// touches them renders the sprite untouched.

uniform float flash_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec4 flash_color : source_color = vec4(1.0);

uniform float reveal_amount : hint_range(0.0, 1.0) = 1.0;
uniform vec2 reveal_from = vec2(0.0, 0.0);
uniform vec2 reveal_to = vec2(0.0, 1.0);
uniform float reveal_band : hint_range(0.01, 1.0) = 0.35;

// Threshold in (0, 1) for the texel at `texel` (integer texel coordinates).
// Recursive Bayer: M4(x, y) = 4 * M2(x & 1, y & 1) + M2(x >> 1, y >> 1), with
// M2 = [[0, 2], [3, 1]]. Integer ops only — WebGL2-safe, no const array.
float _bayer4(vec2 texel) {
	ivec2 p = ivec2(mod(floor(texel), 4.0));
	int fine = ((p.x ^ p.y) & 1) * 2 + (p.y & 1);
	int cx = (p.x >> 1) & 1;
	int cy = (p.y >> 1) & 1;
	int coarse = ((cx ^ cy) & 1) * 2 + (cy & 1);
	return (float(fine * 4 + coarse) + 0.5) / 16.0;
}

// 0 at reveal_from, 1 at reveal_to, clamped, for the world point `p`.
float _reveal_progress(vec2 p) {
	vec2 d = reveal_to - reveal_from;
	float l2 = max(dot(d, d), 1e-6);
	return clamp(dot(p - reveal_from, d) / l2, 0.0, 1.0);
}

// True when this fragment is currently drawn. At reveal_amount 1.0 everything
// is; at 0.0 nothing is; between, the band sweeps from `from` to `to`.
bool _revealed(vec2 world_p, vec2 uv, vec2 texel_size) {
	if (reveal_amount >= 1.0) {
		return true;
	}
	float local = (reveal_amount * (1.0 + reveal_band) - _reveal_progress(world_p)) / reveal_band;
	return _bayer4(uv / texel_size) < local;
}

// `c` with the flash colour composited over it. Alpha is the sprite's own.
vec4 _flash(vec4 c) {
	c.rgb = mix(c.rgb, flash_color.rgb, flash_amount);
	return c;
}
