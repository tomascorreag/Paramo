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
# every stop copied from assets/palettes/palette2.txt. Nothing else changes; a
# ramp defaults to weight 1.0 and is immediately in circulation at the same rate
# as its neighbours. tests/test_visitor_palette.gd fails if a stop is
# off-palette or a ramp is out of order.
#
# ----------------------------------------------------------------------------
# Making a colour common or rare
# ----------------------------------------------------------------------------
#
# Set VisitorRamp.weight. It is a RATIO against the other ramps in the same
# slot, not a probability: skin warm 3 beside skin rosy 1 means three warm for
# every rosy (75% / 25%), and the same result comes from 6 and 2. Nothing has to
# be re-normalised when a ramp is added or removed, which is the whole reason it
# is not authored as percentages.
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


## Roll one ramp INDEX for a slot, honouring VisitorRamp.weight. -1 if the slot
## is unauthored.
##
## Linear cumulative scan rather than an alias table or a cached prefix sum: a
## slot holds a handful of ramps and this runs five times per spawned visitor, so
## the table would cost more to keep in step with Inspector edits than the scan
## costs to run. It also has to stay a PURE FUNCTION of the resource — the
## preview tool re-rolls against a palette the author is editing live.
##
## Consumes exactly ONE draw from `rng`, like the uniform pick it replaced, so a
## seed still maps to a fixed crowd.
func pick_ramp(slot: int, rng: RandomNumberGenerator) -> int:
	var ramps := slot_ramps(slot)
	if ramps.is_empty():
		return -1
	var total: float = 0.0
	for ramp in ramps:
		total += maxf(ramp.weight, 0.0)  # a negative weight is an authoring slip, not "less than never"
	var r := rng.randf()
	if total <= 0.0:
		# Every ramp parked at 0. Falling back to uniform keeps a mis-authored
		# palette LOOKING wrong (an unintended colour turns up) instead of
		# rendering magenta, which reads as a shader bug rather than a data one.
		return mini(int(r * ramps.size()), ramps.size() - 1)
	var target := r * total
	var acc: float = 0.0
	var last_eligible: int = 0
	for i in ramps.size():
		if ramps[i].weight <= 0.0:
			continue  # parked: never advances the cursor, so it can never be landed on
		last_eligible = i
		acc += ramps[i].weight
		if target < acc:
			return i
	# Float accumulation can leave `target` a hair past the final boundary. Land
	# on the last ramp with weight, NOT the last ramp — otherwise a palette whose
	# final entry is parked hands it out on that rounding case.
	return last_eligible
