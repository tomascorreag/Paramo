class_name VisitorAppearance
extends RefCounted

# ============================================================================
# VisitorAppearance
# ============================================================================
#
# Rolls one visitor's look out of a VisitorPalette and writes it to a
# visitor_recolor.gdshader material.
#
# The roll happens HERE, in GDScript, not in the shader: the palette rule
# (CLAUDE.md "Color Palette") says every RGB on screen must be a palette2
# entry, and that is only checkable where it is decided. The shader receives
# finished colours and has no way to invent one.
#
# A variant is (which ramp, which `top` stop) per body part — a window into a
# ramp rather than a hand-picked pair of tones. See VisitorRamp for why.
#
# `roll` takes an explicit RandomNumberGenerator and never touches the global
# stream: visitors are spawned from a seeded per-system stream like every other
# stochastic system here (ObjectPainter.OBJECT_SEED_XOR and friends), so the
# same seed produces the same crowd.
#
# ============================================================================

const UNIFORM: StringName = &"slot_colors"

## The indexed sheets a visitor's BUILD can come from — a different body, not a
## different colour. Recolouring alone gives a crowd one silhouette in many
## outfits, which reads as a costume change rather than as different people.
##
## Every sheet must be an INDEX sheet (the output of index_character_sheet.gd),
## share the 4-facing x 6-frame rig, and decode against the same VisitorSlots
## encoding — the recolour shader is the same one for all of them, so a sheet
## with an extra body colour would render holes where it could not decode.
## test_visitor_palette.gd checks each of these.
const SHEETS: PackedStringArray = [
	"res://assets/sprites/characters/Visitor_1_general.png",
	"res://assets/sprites/characters/Visitor_2_general.png",
	"res://assets/sprites/characters/Visitor_3_general.png",
]


## The loaded sheets, resolved once on first use. `load` is a path hash plus a
## resource-cache lookup even on a hit, and this runs per spawned visitor; the
## textures are immutable and shared by every visitor anyway. Lazy rather than a
## preload const so a tool that never spawns anyone does not pay for them, and so
## the paths stay declared in one place above.
static var _sheets: Array[Texture2D] = []


## Pick one sheet for one visitor. Uniform: the sheets are alternatives, not
## rarities. Drawn from the caller's stream like everything else about a look.
static func roll_sheet(rng: RandomNumberGenerator) -> Texture2D:
	if SHEETS.is_empty():
		return null
	if _sheets.size() != SHEETS.size():
		_sheets.clear()
		for path in SHEETS:
			_sheets.append(load(path) as Texture2D)
	return _sheets[rng.randi_range(0, _sheets.size() - 1)]

## Stand-in for an unauthored slot. Not a palette2 entry, deliberately — it can
## only appear if VisitorPalette is missing a ramp, and it should be impossible
## to mistake for a design choice.
const MISSING_RAMP_COLOR := Color.MAGENTA


## One visitor's choices: [[ramp_index, top_stop], ...] indexed by
## VisitorSlots.Slot. Kept separate from the resolved colours so a visitor can
## be re-resolved after a palette edit (the preview tool relies on this) and so
## a look is savable as two small ints per slot.
static func roll(palette: VisitorPalette, rng: RandomNumberGenerator) -> Array:
	var choices: Array = []
	for slot in VisitorSlots.SLOT_COUNT:
		var ramps := palette.slot_ramps(slot)
		# Weighted by VisitorRamp.weight — see VisitorPalette.pick_ramp. The roll
		# stays here rather than in the palette so the (ramp, top) pair is decided
		# in one place; the palette only answers "which ramp".
		var ramp_idx := palette.pick_ramp(slot, rng)
		if ramp_idx < 0:
			choices.append([-1, 0])
			continue
		var ramp: VisitorRamp = ramps[ramp_idx]
		var lo := mini(palette.min_top_index, ramp.max_top())
		choices.append([ramp_idx, rng.randi_range(lo, ramp.max_top())])
	return choices


## Turn choices into the flat colour array the shader indexes, ordered by
## VisitorSlots.uniform_index(slot, step).
static func resolve(palette: VisitorPalette, choices: Array) -> PackedColorArray:
	var out := PackedColorArray()
	out.resize(VisitorSlots.uniform_count())
	for slot in VisitorSlots.SLOT_COUNT:
		var ramps := palette.slot_ramps(slot)
		var pick: Array = choices[slot] if slot < choices.size() else [-1, 0]
		var ramp: VisitorRamp = null
		if pick[0] >= 0 and pick[0] < ramps.size():
			ramp = ramps[pick[0]]
		for step in VisitorSlots.STEPS_PER_SLOT:
			var c := MISSING_RAMP_COLOR
			if ramp != null:
				c = ramp.at_step(pick[1], step, VisitorSlots.STEPS_PER_SLOT)
			out[VisitorSlots.uniform_index(slot, step)] = c
	return out


## Roll and resolve in one go — what a spawning visitor wants.
static func roll_colors(palette: VisitorPalette, rng: RandomNumberGenerator) -> PackedColorArray:
	return resolve(palette, roll(palette, rng))


## Push colours onto a ShaderMaterial. Sent as vec3 (not vec4/source_color):
## alpha comes from the index sheet, and a `source_color` hint would invite a
## colour-space conversion between what GDScript rolled and what the shader
## emits, which is exactly what verify_visitor_palette.gd exists to rule out.
static func apply(material: ShaderMaterial, colors: PackedColorArray) -> void:
	if material == null:
		return
	var packed := PackedVector3Array()
	packed.resize(colors.size())
	for i in colors.size():
		var c := colors[i]
		packed[i] = Vector3(c.r, c.g, c.b)
	material.set_shader_parameter(UNIFORM, packed)
