class_name ActionExtinguishFire
extends TileAction

# Put out fire in a 3×3 block centred on the clicked cell — the target tile and
# all 8 neighbours. Always available (no resource cost, no inventory gate):
# firefighting is a free, unlimited player verb. Offered whenever ANY of the 9
# cells is on fire, and extinguishes every burning cell in that block at once.
#
# A burning cell is grass→dirt-swapped (walkable), so the standard interaction
# gate reaches the clicked tile with no special-casing.
#
# FireManager is an autoload (referenced by its global name); extinguish() is a
# no-op on a cell that isn't burning, so execute() can blanket the whole 3×3
# without pre-checking each cell.
#
# Uses the bucket glyph as a stand-in "water" icon; a dedicated extinguish glyph
# can replace it later.

## Chebyshev radius of the extinguish footprint. 1 = the clicked cell + its 8
## neighbours (3×3). Bump to widen the splash.
const RADIUS: int = 1


func _init() -> void:
	id = &"extinguish_fire"
	icon = preload("res://assets/sprites/UX/icons/bucket.tres")
	group = &""  # top-level


func _applies(ctx: ActionContext) -> bool:
	# Available if any cell in the footprint is burning — you can douse a fire by
	# clicking the tile next to it, not only the tile that's alight.
	for cell in _footprint(ctx.cell):
		if FireManager.is_burning(cell):
			return true
	return false


func execute(ctx: ActionContext) -> void:
	# extinguish() no-ops on non-burning cells, so blanket the whole block.
	for cell in _footprint(ctx.cell):
		FireManager.extinguish(cell)


## The clicked cell plus every cell within RADIUS (Chebyshev). RADIUS 1 → the 3×3
## block. Side-effect free.
func _footprint(center: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dy in range(-RADIUS, RADIUS + 1):
		for dx in range(-RADIUS, RADIUS + 1):
			out.append(center + Vector2i(dx, dy))
	return out
