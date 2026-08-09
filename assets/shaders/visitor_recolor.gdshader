shader_type canvas_item;

// Palette-swap for indexed character sheets (assets/sprites/characters/*_general.png).
//
// The texture is NOT art — each opaque texel encodes which body part it belongs
// to and which rung of that part's brightness ramp it sits on. See
// scripts/data/visitor_slots.gd for the encoding; the constants below MIRROR it
// (GDScript consts cannot cross into GLSL) and the two must be changed together.
// scripts/tools/verify_visitor_palette.gd renders this and diffs the result
// against the colours GDScript rolled, which is what catches a missed mirror.
//
//   R = 32 + slot * 32   ->  32, 64, 96, 128, 160
//   G = 64 + step * 128  ->  64, 192
//
// Values are far apart on purpose, so round() cannot be fooled by a texel that
// drifts a bit. The sampler must be NEAREST — a linear filter would average two
// slots' index values at every silhouette edge and decode the blend as a third
// body part. The project default filter is Nearest and visitor.tscn also sets
// it explicitly on the Sprite2D.

const float SLOT_R_STEP = 32.0;
const float STEP_G_BASE = 64.0;
const float STEP_G_STEP = 128.0;
const int SLOT_COUNT = 5;
const int STEPS_PER_SLOT = 2;
const int SLOT_COLOR_COUNT = 10;  // SLOT_COUNT * STEPS_PER_SLOT

// Resolved colours, flat: index = slot * STEPS_PER_SLOT + step. Written per
// instance by VisitorAppearance.apply(); rolling lives in GDScript so the
// palette rule is enforced (and tested) on the CPU.
uniform vec3 slot_colors[SLOT_COLOR_COUNT];

varying vec4 v_modulate;

void vertex() {
	// Keep the node's own modulate (spawn/despawn fades) — writing COLOR wholesale
	// in fragment() would otherwise silently discard it. CanvasModulate (night
	// tint, altitude fog) is applied outside the shader and needs no help here.
	v_modulate = COLOR;
}

void fragment() {
	vec4 idx = texture(TEXTURE, UV);
	if (idx.a < 0.01) {
		discard;
	}

	int slot = int(round(idx.r * 255.0 / SLOT_R_STEP)) - 1;
	int step_i = int(round((idx.g * 255.0 - STEP_G_BASE) / STEP_G_STEP));

	// An index the schema does not define means the sheet and this shader
	// disagree. Drop the texel rather than clamping it onto an arbitrary body
	// part — a hole is visible, a wrong-coloured limb is not.
	if (slot < 0 || slot >= SLOT_COUNT || step_i < 0 || step_i >= STEPS_PER_SLOT) {
		discard;
	}

	vec3 rgb = slot_colors[slot * STEPS_PER_SLOT + step_i];
	COLOR = vec4(rgb * v_modulate.rgb, idx.a * v_modulate.a);
}
