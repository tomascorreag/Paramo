@tool
class_name PlantObjectData
extends WorldObjectData

# ============================================================================
# PlantObjectData
# ============================================================================
#
# WorldObjectData specialization for plant-like occupants whose `variants`
# array represents *growth stages* rather than random variations:
#
#   variants[0] = newly planted
#   variants[N-1] = mature
#
# The consumer (e.g. Frailejon) advances `growth_stage` over time and swaps
# the Sprite2D texture to `variants[growth_stage]`.
#
# ============================================================================


## Probability per in-game hour that the plant advances one growth stage.
## 0.0 disables growth; 1.0 advances every hour. Ignored once the plant has
## reached the final variant (variants.size() - 1).
@export_range(0.0, 1.0) var growth_chance: float = 0.1

## Water-proximity bias for procgen placement. When > 0, the per-cell density
## roll in ObjectPainter.assign_object_kinds is multiplied by
##   exp(-water_affinity * dist_to_water^2)
## where `dist_to_water` is the 4-connected BFS step count from the cell to
## the nearest WATER cell on the TerrainGrid (a cell touching water has
## dist=1). Larger values produce a tighter ring around lakes/rivers:
##   0.05 → reach ~6 cells (gentle pull toward shorelines)
##   0.25 → reach ~3 cells (frailejón cluster on the bank)
##   1.00 → reach 1–2 cells (water-locked)
## When <= 0 (default), the term is dropped — placement is uniform with
## respect to water, matching `preferred_altitude <= 0` opt-out semantics.
##
## Plant-only because real-world plant distributions track water tables;
## boulders don't, so this lives on PlantObjectData rather than the base
## WorldObjectData. ObjectPainter checks `data is PlantObjectData` before
## reading this.
@export var water_affinity: float = 0.0
