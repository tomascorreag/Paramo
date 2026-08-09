@tool
class_name VisitorRamp
extends Resource

# ============================================================================
# VisitorRamp
# ============================================================================
#
# One colour a body part can be, expressed as its whole brightness gradient
# rather than as the two tones the current art happens to use.
#
# Storing the full ramp is what makes a variant cheap: a roll picks a ramp and
# a `top` stop, the lit texels take stops[top] and the shaded texels take
# stops[top - 1]. Pick the darkest stop as the base and the shading collapses
# onto it — that falls out of the clamp, with no special case, and it is why
# the darkest skin tone still reads as a skin tone instead of a black hole.
#
# Ordering is DARKEST -> LIGHTEST and is enforced by tests/test_visitor_palette.gd,
# which also checks every stop is a palette2 entry (see CLAUDE.md "Color Palette":
# a gradient invented by interpolation would put off-palette colours on screen,
# so ramps are authored stop by stop, never generated).
#
# Ramps are shared: one "brown" serves hair and shoes. Reference the same
# sub-resource from both arrays in visitor_palette.tres rather than copying it.
#
# ============================================================================


## Author-facing label, e.g. "warm skin", "denim", "auburn". Not used by
## gameplay — it exists so the Inspector's array of ramps is readable and so
## test failures can name the ramp that broke.
@export var name: StringName = &""

## The gradient, DARKEST first. At least 2 stops for the art's two shading
## rungs; longer ramps just give the roll more variants to pick from.
@export var stops: PackedColorArray = PackedColorArray()


## Colour for shading rung `step` (0 = darkest rung the art paints) when the
## variant's lit tone is `top`. Clamped at both ends, so a `top` at the bottom
## of the ramp yields a flat, unshaded body part rather than an index error.
func at_step(top: int, step: int, steps_per_slot: int) -> Color:
	if stops.is_empty():
		return Color.MAGENTA  # unmissable: an empty ramp is an authoring error
	var idx := top - (steps_per_slot - 1 - step)
	return stops[clampi(idx, 0, stops.size() - 1)]


## Highest legal `top` for this ramp.
func max_top() -> int:
	return maxi(stops.size() - 1, 0)
