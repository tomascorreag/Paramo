shader_type canvas_item;

// The spawn flash on its own, for CanvasItems that carry no other material:
// the three plant species with no sway material, and the tile overlays
// SpawnFlash spawns over a freshly built structure. Swaying plants get the same
// effect through wind.gdshader, which includes the same file.

#include "res://assets/shaders/flash_common.gdshaderinc"

// World position for the reveal gradient, and the CanvasItem modulate. Both
// read in vertex(): fragment()'s incoming COLOR is already vertex colour x
// TEXTURE, and multiplying by it again squares the texel and tints the flash
// colour by it (measured: no visible flash at all).
varying vec2 world_pos;
varying vec4 v_modulate;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
	v_modulate = COLOR;
}

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	if (c.a < 0.01 || !_revealed(world_pos, UV, TEXTURE_PIXEL_SIZE)) {
		discard;
	}
	COLOR = _flash(c) * v_modulate;
}
