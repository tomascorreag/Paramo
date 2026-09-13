shader_type canvas_item;

// Bends ONE rect of a journal page — a photograph — exactly the way
// page_warp.gdshader bends the page it sits on, without living inside the
// page's SubViewport.
//
// Why: the page's content is rendered into a 157x231 SubViewport at one texel
// per logical pixel, so anything drawn inside it is pixel art by construction —
// a 64x72 photograph in there is 64x72 texels blown up by the window's integer
// upscale. A photograph has to be drawn OVER the book, at window resolution,
// from a texture with more pixels than its logical rect (256x288 for a 64x72
// rect at the 4x upscale), with LINEAR filtering. But a flat picture over a
// warped page floats off it by up to the warp's amplitude near the spine, and
// the type above and below it visibly disagrees. So the picture is warped too,
// by the same arithmetic on the same curves, quantised to the same blocks.
//
// The node carrying this (scripts/ui/journal_photo_float.gd) sits at the
// photo's rect in BOOK space, padded by the warp amplitude so the displaced
// picture never leaves it. Every uniform below is pushed from the page's own
// PageWarp so the two cannot drift: one curve edit re-bends the type and the
// photograph together.

// --- identical to page_warp.gdshader -----------------------------------------
uniform sampler2D curve_top_tex : filter_nearest, repeat_disable;
uniform sampler2D curve_bottom_tex : filter_nearest, repeat_disable;
uniform float amp_top_px = -9.0;
uniform float amp_bottom_px = 9.0;
uniform float tex_h_px = 231.0;
uniform float tex_w_px = 157.0;
uniform float content_top_px = 9.0;
uniform float content_h_px = 213.0;
uniform float row_block_px = 9.0;
uniform float col_block_px = 0.0;
uniform bool flip_x = false;

// --- this rect, in the page viewport's texel space ----------------------------
// Where this node's rect sits on the page texture (top-left and size)...
uniform float rect_x_px = 0.0;
uniform float rect_y_px = 0.0;
uniform float rect_w_px = 64.0;
uniform float rect_h_px = 72.0;
// ...and where the photograph itself is, inside it (unpadded).
uniform float photo_x_px = 0.0;
uniform float photo_y_px = 0.0;
uniform float photo_w_px = 64.0;
uniform float photo_h_px = 72.0;

void fragment() {
	// This fragment's position on the PAGE texture, from the node's rect.
	float x = rect_x_px + UV.x * rect_w_px;
	float y = rect_y_px + UV.y * rect_h_px;

	// page_warp's offset, verbatim: column quantised in page texels, row
	// quantised in blocks from the content's top, weight +1 at the content's top
	// edge through 0 at its centre to -1 at its bottom.
	float xq = col_block_px > 0.0
		? (floor(x / col_block_px) + 0.5) * col_block_px
		: x;
	float u = xq / tex_w_px;
	float cu = flip_x ? 1.0 - u : u;
	float yq = y;
	if (row_block_px > 0.0) {
		yq = content_top_px
			+ (floor((y - content_top_px) / row_block_px) + 0.5) * row_block_px;
	}
	float half_h = 0.5 * content_h_px;
	float w = clamp((content_top_px + half_h - yq) / half_h, -1.0, 1.0);
	float off = w > 0.0
		? texture(curve_top_tex, vec2(cu, 0.0)).r * amp_top_px * w
		: texture(curve_bottom_tex, vec2(cu, 0.0)).r * amp_bottom_px * (-w);
	off = round(off);

	// The page shows source row (y - off) at row y; so does the photograph.
	vec2 src = vec2((x - photo_x_px) / photo_w_px, (y - off - photo_y_px) / photo_h_px);
	// Sampled unconditionally (WebGL2: no texture fetch under non-uniform
	// control flow) and masked to the photograph's own bounds.
	vec4 c = texture(TEXTURE, clamp(src, vec2(0.0), vec2(1.0)));
	float inside = step(0.0, src.x) * step(src.x, 1.0) * step(0.0, src.y) * step(src.y, 1.0);
	COLOR = vec4(c.rgb, c.a * inside);
}
