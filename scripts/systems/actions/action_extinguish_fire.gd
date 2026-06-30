class_name ActionExtinguishFire
extends TileAction

# Put out a burning cell by spending water from the ResourceLedger. Available
# when the clicked cell is on fire AND the player can afford the cost. A burning
# cell is grass→dirt-swapped (walkable), so the standard interaction gate reaches
# it with no special-casing.
#
# FireManager and ResourceLedger are autoloads (referenced by their global
# names). Water is the firefighting resource: every extinguish ticks the ledger
# down, so fire is a drain on the same pool planting will draw from — triage has
# a cost.
#
# Uses the bucket glyph as a stand-in "water" icon; a dedicated extinguish glyph
# can replace it later.

## Water spent per extinguish. Tunable; migrate to data with the balance pass.
const WATER_COST: float = 10.0


func _init() -> void:
	id = &"extinguish_fire"
	icon = preload("res://assets/sprites/UX/icons/bucket.tres")
	group = &""  # top-level


func _applies(ctx: ActionContext) -> bool:
	if not ResourceLedger.has(&"water", WATER_COST):
		return false
	return FireManager.is_burning(ctx.cell)


func execute(ctx: ActionContext) -> void:
	if not FireManager.is_burning(ctx.cell):
		return
	if ResourceLedger.try_spend(&"water", WATER_COST, &"extinguish_fire"):
		FireManager.extinguish(ctx.cell)
