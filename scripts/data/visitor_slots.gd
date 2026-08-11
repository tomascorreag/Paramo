class_name VisitorSlots
extends RefCounted

# ============================================================================
# Visitor sprite slot schema
# ============================================================================
#
# A character spritesheet in this project is authored as a PICTURE (Visitor_1.png)
# and shipped as an INDEX (Visitor_1_general.png). The index sheet is not art —
# every opaque texel encodes which body part it belongs to and how dark it is,
# and assets/shaders/visitor_recolor.gdshader turns that back into colour at
# draw time from a per-instance palette. One sheet, a crowd of people.
#
# This file is the single source of truth for that encoding. Three consumers
# read it and they must never disagree:
#
#   scripts/tools/index_character_sheet.gd  writes the index sheet
#   scripts/entities/visitor_appearance.gd  packs the shader's colour array
#   assets/shaders/visitor_recolor.gdshader decodes it (constants MIRRORED —
#                                           GDScript consts can't cross into GLSL)
#
# ----------------------------------------------------------------------------
# The encoding
# ----------------------------------------------------------------------------
#
#   R = SLOT_R_BASE + slot * SLOT_R_STEP    ->  32, 64, 96, 128, 160
#   G = STEP_G_BASE + step * STEP_G_STEP    ->  64, 192
#   B = 0
#   A = the source texel's alpha (unchanged, so the silhouette survives)
#
# `step` is a rung on a brightness ramp: 0 = shadow, STEPS_PER_SLOT-1 = lit.
# The shader decodes with round(), and the values are spaced a long way apart
# (32 and 128 out of 255) precisely so the decode cannot be broken by a texel
# drifting a bit or two. Do NOT pack these tighter to fit more slots — add a
# channel or widen STEPS_PER_SLOT instead.
#
# ----------------------------------------------------------------------------
# Adding a slot or a shading step
# ----------------------------------------------------------------------------
#
# 1. Add the enum entry / bump STEPS_PER_SLOT here.
# 2. Add the new source colours to SOURCE_COLOURS.
# 3. Mirror the constants into visitor_recolor.gdshader and widen its
#    slot_colors[] array to uniform_count().
# 4. Add the matching ramp array to VisitorPalette.
#
# tests/test_visitor_palette.gd asserts (1) and (4) stay in step, and
# scripts/tools/verify_visitor_palette.gd catches a missed (3) by rendering.
#
# ============================================================================


enum Slot {
	HAIR,
	SKIN,
	TORSO,
	LEGS,
	SHOES,
}

## How many rungs of shading the art uses per slot. The source sheet paints
## two (a shadow and a lit tone); hair paints only the lit one.
const STEPS_PER_SLOT: int = 2

const SLOT_COUNT: int = 5

# --- Encoding constants (MIRRORED in visitor_recolor.gdshader) ---
const SLOT_R_BASE: int = 32
const SLOT_R_STEP: int = 32
const STEP_G_BASE: int = 64
const STEP_G_STEP: int = 128


## The authored sheet's palette, keyed by hex, mapping to [slot, step].
##
## Read off assets/sprites/characters/Visitor_1.png — every one of its 9 opaque
## colours is a palette2 entry, listed here with its palette index. A repaint
## that introduces a 10th colour makes index_character_sheet.gd fail loudly
## rather than silently dropping those texels.
const SOURCE_COLOURS: Dictionary = {
	"3D3333": [Slot.HAIR, 1],   # P07 — hair is flat; the art paints no shadow rung
	"734C44": [Slot.SKIN, 0],   # P06
	"A57855": [Slot.SKIN, 1],   # P10
	"2F4D2F": [Slot.TORSO, 0],  # P18
	"44702D": [Slot.TORSO, 1],  # P17
	"303843": [Slot.LEGS, 0],   # P29
	"405273": [Slot.LEGS, 1],   # P28
	"636663": [Slot.SHOES, 0],  # P00
	"87857C": [Slot.SHOES, 1],  # P01
}


## Index into the shader's flat slot_colors[] array (and into the packed
## PackedColorArray VisitorAppearance produces).
static func uniform_index(slot: int, step: int) -> int:
	return slot * STEPS_PER_SLOT + step


## Length of that array.
static func uniform_count() -> int:
	return SLOT_COUNT * STEPS_PER_SLOT


## The index-sheet texel for a (slot, step). Alpha is the caller's business.
static func encode(slot: int, step: int) -> Color:
	return Color(
		float(SLOT_R_BASE + slot * SLOT_R_STEP) / 255.0,
		float(STEP_G_BASE + step * STEP_G_STEP) / 255.0,
		0.0,
		1.0
	)


## Inverse of `encode`, for tools and tests auditing an index sheet.
## Returns [slot, step], or [-1, -1] if the texel decodes out of range.
static func decode(c: Color) -> Array:
	var slot := int(roundf(c.r * 255.0 / float(SLOT_R_STEP))) - 1
	var step := int(roundf((c.g * 255.0 - float(STEP_G_BASE)) / float(STEP_G_STEP)))
	if slot < 0 or slot >= SLOT_COUNT or step < 0 or step >= STEPS_PER_SLOT:
		return [-1, -1]
	return [slot, step]


## Human name for a slot, used in tool output and error messages.
static func slot_name(slot: int) -> String:
	match slot:
		Slot.HAIR: return "hair"
		Slot.SKIN: return "skin"
		Slot.TORSO: return "torso"
		Slot.LEGS: return "legs"
		Slot.SHOES: return "shoes"
	return "slot%d" % slot
