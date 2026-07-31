shader_type canvas_item;
render_mode blend_premul_alpha;

// Bends one journal page's CONTENT to sit on the drawn page in Book.png. The art
// has perspective — each page's top and bottom edge sweeps 9px outward as it
// approaches the spine — so flat horizontal text visibly floats above it. This
// shader re-samples the page's rendered content with a per-column vertical
// offset that reproduces that sweep.
//
// It runs on a SubViewportContainer (scripts/ui/page_warp.gd) whose SubViewport
// holds the page content. A shader CANNOT warp a Label directly: Godot draws each
// glyph as its own quad, so the fragment UV is per-glyph, not per-control. The
// content has to be rendered to a texture before anything can bend it.
//
// GEOMETRY, and why the viewport is taller than the content it holds:
// the content rect is the page's NARROWEST column (the outer edge, 213 rows), and
// the viewport is padded by exactly the warp amplitude — 9px above and 9px below,
// 231 total. The warp spends that padding expanding the content onto the full
// page as it nears the spine, so the sampled UV can never leave the texture. No
// clamping, no edge bleed, and the padding documents the amplitude.
//
// WEIGHTING: the top curve owns the content's top edge, the bottom curve owns its
// bottom edge, and they cross fade to ZERO deformation at the vertical centre.
// So the page stretches away from its middle, which is what the art does.

// Page-edge profiles, u = 0 at the page's OUTER edge -> 1 at the spine, value =
// fraction of the corresponding amplitude. Baked from a Curve by page_warp.gd at
// one texel per page column, so filter_nearest is EXACT, not a rounding-down.
//
// filter_nearest is also load-bearing for the web build: this project ships GL
// Compatibility / WebGL2, where CurveTexture's float format (R32F) can only be
// linearly filtered with OES_texture_float_linear — not universally present.
// filter_linear here would look right on desktop and return garbage on web.
uniform sampler2D curve_top_tex : filter_nearest, repeat_disable;
uniform sampler2D curve_bottom_tex : filter_nearest, repeat_disable;

// Signed pixel travel of each edge at u = 1 (the spine). Negative = upward.
// Measured from Book.png: both edges move 9px, mirrored.
uniform float amp_top_px = -9.0;
uniform float amp_bottom_px = 9.0;

// Viewport texture height, and the content rect inside it. Pushed from the actual
// node sizes rather than hardcoded — the divisor MUST equal the real texture
// height or the integer snap below stops landing on texel boundaries.
uniform float tex_h_px = 231.0;
uniform float tex_w_px = 157.0;
uniform float content_top_px = 9.0;
uniform float content_h_px = 213.0;

// Quantises the weight to blocks this many pixels tall, 0 = off (per-pixel).
//
// Why it exists: a linear ramp from -9 to +9 across the content is a uniform
// vertical STRETCH of 231/213 at EVERY row — zero translation at the centre, but
// never zero scale. Snapped to integers that duplicates 18 source scanlines,
// roughly one every 12px, which lands INSIDE 8px glyphs and makes random letters
// a pixel taller. Evaluating the weight at the centre of a text-line-tall block
// instead makes each line translate as a rigid unit and pushes every duplicated
// row into the leading between lines, where nothing is drawn. Measured on the
// real page (preview_page_warp.gd --rows 9 vs 0): the difference is obvious.
//
// Blocks are measured from content_top_px, so text must START at a multiple of
// this below the content's top edge — otherwise every line straddles two blocks
// and the artefact returns at glyph bottoms.
uniform float row_block_px = 9.0;

// Quantises the COLUMN the offset is sampled at, 0 = off (per-column).
//
// The companion to row_block_px, for the other axis and a different artefact. The
// offset is a stair: the curve sweeps 9px across the page, so `round` turns it into
// 9 one-texel steps at fixed columns (21, 37, 49, 60, 70, 80, 91, 103, 117 on the
// left page). A step falling in the middle of a glyph SHEARS it — the left half of
// the letter sits a texel below its right half. At full amplitude that is ~9 of the
// ~36 glyphs on a line.
//
// Quantising to the body face's advance width moves every step onto that grid, so a
// step falls BETWEEN two letters instead of through one. It only pays off if the
// text is actually on the grid: Tiny5 at 8 advances 4px for 28 of its 38 common
// glyphs, so a run starting at a multiple of 4 stays in phase until it hits a
// space, a period, or one of the narrow/wide letters. Unlike the row axis this is a
// mitigation, not a cure — the step COUNT is set by the amplitude and cannot change.
uniform float col_block_px = 0.0;

// Mirrors u so the same curve pair drives both pages. The right page's spine is
// on its LEFT, so it sets this; the left page does not.
uniform bool flip_x = false;

void fragment() {
	// Quantise in the page's OWN texel space, before mirroring, so both pages put
	// their steps on the same grid as the text drawn into them.
	float x = UV.x * tex_w_px;
	float xq = col_block_px > 0.0
		? (floor(x / col_block_px) + 0.5) * col_block_px
		: x;
	float u = xq / tex_w_px;
	float cu = flip_x ? 1.0 - u : u;

	float y = UV.y * tex_h_px;
	float yq = y;
	if (row_block_px > 0.0) {
		yq = content_top_px
			+ (floor((y - content_top_px) / row_block_px) + 0.5) * row_block_px;
	}

	float half_h = 0.5 * content_h_px;
	// +1 at the content's top edge, 0 at its centre, -1 at its bottom edge.
	float w = clamp((content_top_px + half_h - yq) / half_h, -1.0, 1.0);

	float off = w > 0.0
		? texture(curve_top_tex, vec2(cu, 0.0)).r * amp_top_px * w
		: texture(curve_bottom_tex, vec2(cu, 0.0)).r * amp_bottom_px * (-w);

	// Whole texels only, so the 8px pixel font stays crisp and the warp reads as a
	// stair-stepped baseline. This survives the window's 3x canvas upscale: every
	// fragment inside a given texel is displaced by the SAME integer texel count,
	// so magnification scales the step without ever splitting it.
	off = round(off);

	COLOR = texture(TEXTURE, UV + vec2(0.0, -off / tex_h_px));
}
