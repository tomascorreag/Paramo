class_name ActionExtinguishFire
extends TileAction

# Put out fire in a 3×3 block centred on the clicked cell — the target tile and
# all 8 neighbours. Offered whenever ANY of the 9 cells is on fire.
#
# Costs WATER_PER_CELL from the ledger for each cell actually doused, so a wide
# wildfire is genuinely expensive and the reserve is what makes fire a threat
# rather than a chore. Deliberately NOT all-or-nothing: a partial douse spends
# what it can, working outward from the cell the player clicked, so the click
# always does something and the water is spent where they aimed.
#
# Two gates, and the split matters:
#   _applies    — "is anything here on fire?"   (drives whether the action shows)
#   is_enabled  — "can I afford even one cell?" (drives whether it shows DIMMED)
# Collapsing them would make the action vanish when broke, which reads as a bug
# rather than as "you are out of water".
#
# A burning cell is grass→dirt-swapped (walkable), so the standard interaction
# gate reaches the clicked tile with no special-casing.
#
# FireManager and ResourceLedger are autoloads (referenced by their global
# names); FireManager.extinguish() is a no-op on a cell that isn't burning.

## Chebyshev radius of the extinguish footprint. 1 = the clicked cell + its 8
## neighbours (3×3). Bump to widen the splash.
const RADIUS: int = 1

## Water spent per burning cell doused. Priced per cell rather than per click so
## the cost tracks the size of the fire, not the number of right-clicks.
const WATER_PER_CELL: float = 1.0

const WATER: StringName = &"water"
const SPEND_SOURCE: StringName = &"extinguish_fire"


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


## Dimmed in the radial menu below the price of a single cell. Not below the
## price of the WHOLE footprint: partial douses are allowed, so one cell's worth
## of water is a usable action.
func is_enabled(_ctx: ActionContext) -> bool:
	return ResourceLedger.has(WATER, WATER_PER_CELL)


func execute(ctx: ActionContext) -> void:
	# try_spend is atomic — it returns false without mutating when short — so the
	# loop needs no separate affordability check and can never half-charge for a
	# cell it failed to douse.
	for cell in _burning_cells_by_proximity(ctx.cell):
		if not ResourceLedger.try_spend(WATER, WATER_PER_CELL, SPEND_SOURCE):
			break
		FireManager.extinguish(cell)


## The burning cells of the footprint, nearest the clicked cell first (Chebyshev
## ring order, stable within a ring). This ordering is what makes a partial douse
## feel aimed rather than arbitrary: run out of water and the fires left standing
## are the ones furthest from where you clicked.
func _burning_cells_by_proximity(center: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for cell in footprint_by_ring(center, RADIUS):
		if FireManager.is_burning(cell):
			out.append(cell)
	return out


## Every cell within `radius` (Chebyshev) of `center`, ordered ring 0 outward,
## stable within a ring. Static + side-effect free so the balance simulator's
## bot douses in exactly the order this action does.
static func footprint_by_ring(center: Vector2i, radius: int = RADIUS) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for ring in range(radius + 1):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if maxi(absi(dx), absi(dy)) == ring:
					out.append(center + Vector2i(dx, dy))
	return out


## The clicked cell plus every cell within RADIUS (Chebyshev). RADIUS 1 → the 3×3
## block. Side-effect free. (Unordered variant of footprint_by_ring, kept for
## _applies where order is irrelevant.)
func _footprint(center: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dy in range(-RADIUS, RADIUS + 1):
		for dx in range(-RADIUS, RADIUS + 1):
			out.append(center + Vector2i(dx, dy))
	return out
