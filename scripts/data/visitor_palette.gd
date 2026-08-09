@tool
class_name VisitorPalette
extends Resource

# ============================================================================
# VisitorPalette
# ============================================================================
#
# Every colour a visitor can be, one array of VisitorRamp per body part. This
# is the file you edit to change how the crowd looks — the spritesheet, the
# shader and the entity all stay put.
#
# Authored as resources/characters/visitor_palette.tres, with the ramps inline
# as sub-resources so the whole wardrobe is one file in the Inspector.
#
# ----------------------------------------------------------------------------
# Adding a colour
# ----------------------------------------------------------------------------
#
# Add a VisitorRamp to the relevant array, ordered darkest -> lightest, with
# every stop copied from assets/palettes/palette2.txt. Nothing else changes;
# the roll picks uniformly across ramps, so a new ramp is immediately in
# circulation. tests/test_visitor_palette.gd fails if a stop is off-palette or
# a ramp is out of order.
#
# Sharing is expected: point `hair` and `shoes` at the same brown sub-resource
# rather than authoring it twice.
#
# The arrays are per-SLOT and must cover every VisitorSlots.Slot — `slot_ramps`
# is the only place that mapping lives, so a new slot needs an entry there and
# a new @export here.
#
# ============================================================================


@export var hair: Array[VisitorRamp] = []
@export var skin: Array[VisitorRamp] = []
@export var torso: Array[VisitorRamp] = []
@export var legs: Array[VisitorRamp] = []
@export var shoes: Array[VisitorRamp] = []

## Lowest `top` stop a roll may pick, i.e. how dark a variant is allowed to be.
## At 1 every variant keeps at least one rung of shading below its lit tone; at
## 0 the darkest stop is in play and those visitors render flat-shaded. Ramps
## shorter than this are clamped, never skipped.
@export var min_top_index: int = 1


## Ramps for a VisitorSlots.Slot. Empty array = that slot is unauthored, which
## VisitorAppearance renders magenta rather than guessing.
func slot_ramps(slot: int) -> Array[VisitorRamp]:
	match slot:
		VisitorSlots.Slot.HAIR: return hair
		VisitorSlots.Slot.SKIN: return skin
		VisitorSlots.Slot.TORSO: return torso
		VisitorSlots.Slot.LEGS: return legs
		VisitorSlots.Slot.SHOES: return shoes
	return []
