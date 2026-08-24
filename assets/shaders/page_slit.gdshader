shader_type canvas_item;
render_mode blend_premul_alpha;

// Cuts a SLIT through the journal's paper and shows whatever sits behind it.
// Used for the season wheel: the wheel is a physical disc mounted behind the
// book, not something printed on the page, so it must NOT bend with the paper —
// but the hole it shows through is cut INTO the paper, so the hole's two lips do.
//
// So this is the exact complement of page_warp.gdshader:
//   page_warp  moves the CONTENT and leaves the rect alone   (ink on paper)
//   page_slit  moves the RECT and leaves the content alone   (a cut in paper)
// Both read the same page_curl_*.tres curves, so a curve edit re-bends the text
// and re-cuts the slot together.
//
// GEOMETRY, and why the container is taller than the slit: identical trick to
// page_warp — the SubViewport is padded by the warp amplitude above and below the
// visible band (scripts/ui/page_slit.gd `slit_inset_px`), so the band can travel
// its full sweep without ever leaving the rect. Everything outside the band is
// multiplied to zero; the paper drawn underneath shows through.
//
// The slit is THIN, so its vertical position is one value per column rather than
// a per-row function: page_slit.gd evaluates page_warp's weighting ONCE at the
// band's centre row and folds it into amp_px. That keeps the band a rigid strip
// (a cut cannot change width as it slides) and keeps the whole shader to a single
// curve fetch.

// Same baked page-edge profile page_warp samples: one texel per PAGE column,
// u = 0 at the page's outer edge -> 1 at the spine. filter_nearest for the same
// two reasons as there — the sample is exact at one texel per column, and WebGL2
// cannot be relied on to filter R32F linearly (OES_texture_float_linear).
uniform sampler2D curve_tex : filter_nearest, repeat_disable;

// Signed pixel travel of the band at the spine, ALREADY multiplied by page_warp's
// vertical weighting for this band's row (see the header). Negative = upward.
uniform float amp_px = -7.0;

// This rect's horizontal span expressed in the PAGE's curve domain. Mirrored on
// the CPU for a flipped page, so u_min > u_max there and the mix() below reverses
// with it — no flip_x branch needed.
uniform float u_min = 0.0;
uniform float u_max = 1.0;

// Rect size, and the visible band inside it, in texels. Pushed from the real node
// sizes; the height divisor must equal the true texture height or the integer
// snap stops landing on texel boundaries.
uniform float rect_w_px = 64.0;
uniform float rect_h_px = 38.0;
uniform float slit_top_px = 9.0;
uniform float slit_bottom_px = 29.0;

// Cut-edge shadow, drawn BEHIND whatever is in the slot — it replaces a 32px
// gradient that used to sit behind the wheel and bleed past the mask. Ramps up
// from the BOTTOM lip over shadow_h_px texels, so it slides with that lip for
// free instead of being a separately-positioned node that would have to be
// re-warped. Bottom only: the top lip's shade read as a bar floating on the page
// wherever the disc was too narrow to catch it.
uniform vec4 shadow_color : source_color = vec4(0.078431, 0.137255, 0.227451, 1.0);
uniform float shadow_h_px = 4.0;
uniform float shadow_strength = 0.5;

// Tapers the shadow's HEIGHT to nothing across this many texels at each end of
// the slot, rounding off its two top corners. The bottom row survives the taper
// (it is at zero distance from the lip, so its ramp is 1 for any height above
// zero) — what feathers away is the stack above it, which is what made the shade
// read as a rectangle laid on the page rather than as shade inside a cut.
uniform float shadow_feather_px = 10.0;

void fragment() {
	float cu = mix(u_min, u_max, UV.x);
	// Whole texels only, for the same reason page_warp rounds: a fractional cut
	// would resample the wheel's pixels and soften a 64px sprite the whole art
	// style depends on staying hard-edged.
	float off = round(texture(curve_tex, vec2(cu, 0.0)).r * amp_px);

	float y = floor(UV.y * rect_h_px);
	float top = slit_top_px + off;
	float bottom = slit_bottom_px + off - 1.0;
	// step(top, y) * step(y, bottom) keeps row slit_bottom_px itself out, so the
	// band is exactly (slit_bottom_px - slit_top_px) texels tall at every column.
	float band = step(top, y) * step(y, bottom);

	// Premultiplied throughout: SubViewport.transparent_bg emits premultiplied
	// alpha, so `src over sh` is a plain add weighted by the source's coverage.
	vec4 src = texture(TEXTURE, UV);
	float x = floor(UV.x * rect_w_px);
	float to_end = min(x + 0.5, rect_w_px - 0.5 - x);
	float taper = shadow_feather_px > 0.0
		? clamp(to_end / shadow_feather_px, 0.0, 1.0)
		: 1.0;
	// max(..., 1.0) keeps a single shaded row alive right into the corner rather
	// than letting the shade blink out a few texels early.
	float h = max(shadow_h_px * taper, 1.0);
	float sa = shadow_h_px > 0.0
		? shadow_color.a * shadow_strength * clamp(1.0 - (bottom - y) / h, 0.0, 1.0)
		: 0.0;
	vec4 sh = vec4(shadow_color.rgb * sa, sa);

	COLOR = (src + sh * (1.0 - src.a)) * band;
}
