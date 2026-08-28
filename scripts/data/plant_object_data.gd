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
## When == 0 (default), the term is dropped — placement is uniform with
## respect to water, matching `preferred_altitude <= 0` opt-out semantics.
## When < 0 the sign flips the term to AVOIDANCE:
##   1 - exp(-|water_affinity| * dist_to_water^2)
## so the kind is suppressed on the shore and reaches full density a few cells
## inland — dry-site species (tussock grass, xeromorphic shrubs). Half
## strength sits at dist = sqrt(ln 2 / |affinity|):
##   -0.3  → half at 1.5 cells (shoreline only)
##   -0.1  → half at 2.6 cells
##   -0.03 → half at 4.8 cells
## Measure before choosing either sign: on level1 two thirds of the eligible
## ground lies within 10 cells of water (lake + river), so even +0.02 zeroes
## the far half of the map (exp(-0.02·13²) = 0.03). A "gentle pull" is
## ~0.005; see report_flora_scatter.gd.
##
## Plant-only because real-world plant distributions track water tables;
## boulders don't, so this lives on PlantObjectData rather than the base
## WorldObjectData. ObjectPainter checks `data is PlantObjectData` before
## reading this.
@export var water_affinity: float = 0.0

## Whether spawned instances get the reparented drop shadow. Every shadow is a
## second CanvasItem with its own shader, and canvas-item count is the measured
## web-frame lever (dev-notes/performance.md), so ground cover (grasses, bamboo)
## opts out; only the species with a real silhouette (rosettes, shrubs) cast one.
@export var casts_shadow: bool = true

## Accumulated trample damage that costs the plant ONE growth stage, in the
## same units RegrowthManager wears grass in: a visitor step is
## `trample_per_step` (0.18) and the player's own step is a tenth of that. A
## plant drops a stage each time the damage fills, and is freed when it is
## trampled at stage 0 — so a mature four-stage plant takes
## `4 * trample_resistance / 0.18` crossings to clear.
##
## Damage decays at `Frailejon._TRAMPLE_HEAL_PER_DAY` (0.15/day, the grass
## ledger's own recovery rate), which is NOT scaled by this value. So the
## break-even traffic is the same ~0.83 crossings a day for every species, and
## this field sets only how long the killing takes above that line. At a
## well-used 3 crossings a day: tussock 3 days, cushion 6, cortadera 8,
## chuscal 12, shrub 15, rosette 31 — a fence, or a route that moves, is the
## counterplay.
##
## Ordering is against the GRASS, since both are visible on the same cell: at
## 0.18 a cell wears bare in ~5.5 crossings, so a tussock at 0.3 flattens just
## before the ground under it does, and a 3 m rosette at 3.0 long outlives the
## track.
##
## 0 makes the plant immune, which is the knob for isolating the mechanic in
## the balance sim.
@export var trample_resistance: float = 1.0
