class_name ActionIgniteFire
extends TileAction

# DEBUG ONLY. Sets a grass cell alight so fire behaviour (spread, burn-down, the
# blob VFX, extinguishing) can be exercised on demand instead of waiting on
# FireManager's random ignition rolls, which are gated on a gaussian day curve,
# altitude and distance-to-water and so are slow and awkward to provoke.
#
# It starts a plain kindling at amount 0 — exactly what a random ignition
# produces, with no head start. From there it spreads and burns on its own like
# any other fire, which is the point: this is a trigger, not a special fire.
#
# Gated on `Debug.enabled` (F3), so it only appears while the debug overlay is
# up, and `Debug.enabled` itself only flips in debug builds — a release export
# can never surface it. `debug_only` keeps it out of has_meaningful_action, so
# every grass tile on the map doesn't light up its hover reticle while F3 is on.
#
# Icon is an arbitrary stand-in: there is no flame glyph on the sheet, and this
# is a dev affordance not worth new art.

func _init() -> void:
	id = &"ignite_fire"
	icon = preload("res://assets/sprites/UX/icons/trowel.tres")
	group = &""  # top-level
	debug_only = true


func _applies(ctx: ActionContext) -> bool:
	if not Debug.enabled:
		return false
	# can_ignite (not is_burning) so this is never offered alongside extinguish on
	# the same tile, and never on non-grass — see FireManager.can_ignite for why
	# the grass check is not optional.
	return FireManager.can_ignite(ctx.cell)


func execute(ctx: ActionContext) -> void:
	FireManager.ignite(ctx.cell)
