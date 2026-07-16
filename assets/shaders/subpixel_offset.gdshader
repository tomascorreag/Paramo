shader_type canvas_item;

// Subpixel-scroll display shader for a low-res world SubViewport.
//
// Applied as the material on the SubViewportContainer that shows the low-res
// world. Every frame SmoothPixelViewport snaps the SubViewport's
// canvas_transform to the integer texel grid (so the world rasterizes crisp),
// and hands the leftover sub-texel remainder here as `vertex_offset`. VERTEX +=
// offset slides the whole upscaled quad by that fraction, so the camera pans
// smoothly at monitor-pixel resolution instead of jumping a whole low-res texel
// at a time. The SubViewport is rendered 2px larger than shown (1px border each
// side, container at (-1,-1)), so the shift never exposes a blank edge.
//
// Units: with the root window in CANVAS_ITEMS + content_scale_size = window/N,
// the container is 1:1 in the logical (low-res) space and content_scale applies
// the ×N upscale. So `vertex_offset` is the raw texel remainder in logical px;
// content_scale scales it to N screen px automatically — do NOT pre-multiply by
// N here. Sign is calibrated against the driver (see SmoothPixelViewport).
uniform vec2 vertex_offset;

// Sharp-bilinear: sample nearest-with-a-clamped-bilinear-seam so tile edges
// don't shimmer while the quad slides between texels. At 1:1 nearest this is a
// no-op; the anti-shimmer only appears in the fraction of a texel around each
// edge, scaled by fwidth (the on-screen texel density post content-scale).
uniform bool sharp_bilinear = true;

void vertex() {
	VERTEX += vertex_offset;
}

void fragment() {
	if (sharp_bilinear) {
		vec2 uv_per_pixel = fwidth(UV);
		vec2 nearest = round(UV / TEXTURE_PIXEL_SIZE);
		vec2 nearest_uv = nearest * TEXTURE_PIXEL_SIZE;
		vec2 f = clamp((UV - nearest_uv) / uv_per_pixel, -0.5, 0.5);
		COLOR = texture(TEXTURE, (nearest + f) * TEXTURE_PIXEL_SIZE);
	} else {
		COLOR = texture(TEXTURE, UV);
	}
}
