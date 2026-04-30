@tool
class_name TerrainGenerationParams
extends Resource

# ============================================================================
# TerrainGenerationParams
# ============================================================================
#
# Resource-backed input to TerrainGenerator.generate(). Designer tunes a
# preset in the inspector and saves it as a `.tres` under
# `resources/terrain/`. Per-map ProceduralWorld nodes reference one of these.
#
# Heightfield = noise + three gradients (S→N, SW→NE, SE→NW), snapped to
# even half-steps. A noisy disc mask carves the iso footprint into a
# roughly circular shape with the back walls (NW/NE) intact. Grass-only
# biome — DIRT/ROCK/SNOW bands are not produced.
#
# Coordinate convention (matches DiamondCompass / TileMapLayer iso):
#   - grid (0, 0)            = visual N corner (top of screen)
#   - grid (W-1, 0)          = visual NE corner (top-right)
#   - grid (0, H-1)          = visual NW corner (top-left in iso, bottom-left in raw grid)
#   - grid (W-1, H-1)        = visual S corner (bottom of screen)
#   - DIR_SE = ( 1, 0), DIR_SW = (0, 1)  → both step "south" visually
#
# ============================================================================


# --- Map dimensions ---------------------------------------------------------

## RNG seed for ALL stochastic systems (heightfield noise, lake jitter, biome
## noise, disc edge noise, river walker). The same seed reproduces an
## identical map. Each subsystem uses a decorrelated stream derived from this
## seed so changing one doesn't lock-step with another.
@export var seed: int = 0

## Grid width in cells (X axis = NW→SE diagonal in iso). Total cell count
## = width × height. Larger = more space but more memory and slower
## generation.
@export_range(8, 200, 1) var width: int = 48

## Grid height in cells (Y axis = NE→SW diagonal in iso). Width and height
## need not be equal; the disc silhouette is sized off `min(W, H)` so a
## rectangular grid still produces a roughly circular footprint.
@export_range(8, 200, 1) var height: int = 48

## Maximum altitude in half-steps (1 cube = 2 half-steps). Caps the
## heightfield's tallest peak; the lake sits at `top_altitude - lake_depth_hs`.
## The scene's TileMapLayer stack must have enough layers to render this —
## `procedural_base.tscn` ships with Ground0..Ground16 covering altitudes
## 0..32. Setting top_altitude beyond the tallest layer triggers a warning at
## regenerate() and cells above the ceiling are dropped from the paint.
## Must be even.
@export_range(2, 32, 2) var top_altitude: int = 16


# --- Heightfield ------------------------------------------------------------

## Spatial frequency of the FBM noise driving altitude. Lower values produce
## larger, smoother plateaus (broad terraces); higher values produce more,
## smaller bumps (chaotic terrain).
##   ~0.02 = very broad features, few terraces
##   ~0.05 = moderate (recommended starting point)
##   ~0.15 = busy, many small bumps
@export_range(0.005, 0.5, 0.005) var noise_frequency: float = 0.05

## How strongly noise perturbs the normalized gradient. The gradient is
## normalized to [0, 1] before noise is added, so this value is independent
## of the weight_n/ne/nw values — only `noise_strength` and `noise_frequency`
## determine how rugged the terrain is.
##   0.0 = pure gradient cone (smooth, predictable, no waterfalls)
##   0.4 = mild variation, mostly 1-cube terrace drops
##   0.6 = noticeable terraces with occasional 2-cube drops (recommended)
##   1.0 = pronounced 2–4-cube cliffs; multiple waterfalls per map
##   2.5 = noise dominates; gradient barely visible
## Combined with `noise_frequency`, controls the "ruggedness" of the terrain.
@export_range(0.0, 2.5, 0.05) var noise_strength: float = 1.0

## Weight of the S→N envelope. Peaks at grid (0, 0) — the visual N corner —
## and falls to 0 at grid (W-1, H-1). This is the "main" gradient pulling
## the lake high in the N region. 0 = no overall north-up bias.
##
## Weights are ADDITIVE (not relative). The three gradients sum directly into
## the final altitude; the sum is then clamped to [0, 1]. If `w_n + w_ne + w_nw`
## exceeds 1.0 the back corner pins flat at top_altitude (a clipped plateau)
## and noise terraces in that region disappear. To avoid clipping, keep the
## sum near 1.0; to grow the lake plateau intentionally, push the sum higher.
@export_range(0.0, 2.0, 0.05) var weight_n: float = 1.0

## Weight of the SW→NE gradient. Peaks along y=0 (the visual NE back edge).
## Adds height to the NE wall so it reads as a ridge, not just an apex.
## 0 = no NE wall lift; the NE edge follows pure noise. Stacks additively
## with `weight_n` and `weight_nw` (see `weight_n` docs).
@export_range(0.0, 2.0, 0.05) var weight_ne: float = 0.6

## Weight of the SE→NW gradient. Peaks along x=0 (the visual NW back edge).
## Symmetric companion to `weight_ne` — together they raise both back walls.
## 0 = no NW wall lift. Stacks additively with the other two weights.
@export_range(0.0, 2.0, 0.05) var weight_nw: float = 0.6


# --- Disc silhouette --------------------------------------------------------

## Disc center X as a fraction of grid width. ~0.35 puts the center north of
## center, biased toward the N corner — the disc reaches grid (0, 0) so the
## lake can sit there. Push toward 0.5 for a more centered playable region;
## push above 0.5 and the disc may not reach the N corner, which can leave
## the apex picker without GROUND in the N quadrant (no lake / no river).
@export_range(0.0, 1.0, 0.01) var disc_center_x_frac: float = 0.35

## Disc center Y as a fraction of grid height. Same logic as
## `disc_center_x_frac`. Default ~0.35 keeps the disc reaching the grid N
## corner. Set equal to `disc_center_x_frac` for a symmetric disc.
@export_range(0.0, 1.0, 0.01) var disc_center_y_frac: float = 0.35

## Disc radius as a fraction of `min(W, H)`. Cells beyond this radius from
## the disc center (with noise jitter on the edge) are carved EMPTY.
##   ~0.4 = small disc, lots of EMPTY space
##   0.55 = covers most of the grid (recommended)
##   ~0.7+ = barely any carving; footprint approaches the full rectangle
##
## Also doubles as a gradient steepening factor: heightfield gradient
## denominators scale by `max(0.05, 1 - disc_radius_frac)`, so a larger disc
## produces a steeper gradient that hits 0 well inside the disc, leaving the
## SW portion as a flat plain (noise-only altitude). At low frac the
## denominators approach the full grid extent and the gradient spreads
## evenly across the disc as before.
@export_range(0.2, 1.2, 0.01) var disc_radius_frac: float = 0.55

## Frequency of the noise that wobbles the disc boundary. Lower = long,
## smooth bays/peninsulas along the edge; higher = small irregular ripples.
@export_range(0.005, 0.3, 0.005) var disc_edge_frequency: float = 0.06

## How much the noise perturbs the disc edge. 0 = perfect circle. Higher
## values produce more irregular shorelines, with bays cutting inward and
## peninsulas extending outward.
##   0.0 = clean geometric circle
##   0.35 = natural irregular outline (recommended)
##   1.0 = highly fragmented edge; may produce isolated patches
@export_range(0.0, 1.0, 0.05) var disc_edge_jitter: float = 0.35


# --- Biome / grass picker ---------------------------------------------------

## Frequency of the biome noise. The painter's grass variant picker uses
## the resulting `biome_score` (= altitude + biome_noise) to pick which grass
## variant to paint per cell. Lower = larger same-variant clumps; higher =
## more per-cell variation.
@export_range(0.005, 0.2, 0.005) var biome_noise_frequency: float = 0.15

## Amplitude of the biome noise added to altitude when computing
## `biome_score`. Effectively how much the per-cell grass variant can drift
## away from the altitude-preferred variant. 0 = strict altitude bands;
## higher = more visual variety per altitude tier.
@export_range(0.0, 6.0, 0.1) var biome_noise_amplitude: float = 4.0


# --- Lake -------------------------------------------------------------------

## Lake disc radius in cells (before aspect stretching and noise jitter).
## The lake's actual footprint is roughly an ellipse `radius * aspect` cells
## across each axis, then perturbed by noise. ~3 = tiny pond, ~6+ = sizable
## lake covering most of the N quadrant.
@export_range(0.5, 12.0, 0.1) var lake_radius: float = 2.8

## How strongly noise perturbs the lake's outline. 0 = perfect ellipse
## (geometric, reads as artificial); higher = more irregular shoreline
## with bays and protrusions. Recommended ~1.5 for a natural shore.
@export_range(0.0, 2.0, 0.05) var lake_jitter_strength: float = 1.5

## Per-seed random aspect-ratio range. Each generation picks an aspect_x and
## aspect_y uniformly from [min, max], producing a stretched (or
## compressed) lake disc.
##   min < 1.0 = lake can be compressed along an axis (tall-thin or
##               short-wide depending on which axis)
##   max > 1.0 = lake can be stretched along an axis
## Setting min = max = 1 forces a perfect circle; default [0.5, 2.0]
## produces visibly different lake shapes per seed (round, oblong, tilted).
@export_range(0.3, 1.0, 0.05) var lake_aspect_min: float = 0.5
@export_range(1.0, 2.5, 0.05) var lake_aspect_max: float = 2.0

## Minimum number of dry GROUND cells between the lake's northern edge and
## the back walls. Bumps the apex inset so the lake never sits directly
## against the NW/NE walls — there's always a strip of ground behind it.
@export_range(0, 6, 1) var lake_back_margin: int = 2

## Size of the apex-search window as a fraction of `min(W, H)`. The lake
## center is the highest GROUND cell within an inset×inset box anchored at
## the N corner — smaller values pull the lake closer to the (0, 0) corner;
## larger values let it land anywhere in the N quadrant (potentially far
## from the corner if noise produces a peak there).
##   ~0.15 = lake hugs the N corner, very little spread
##   0.25  = lake stays in the N quarter (recommended)
##   0.5+  = lake can land deep into the map's interior
@export_range(0.05, 0.6, 0.01) var lake_apex_window_frac: float = 0.25

## Half-step depth of the lake below its apex (the highest GROUND in the
## corner window). 0 = lake sits exactly at apex altitude (no peak nearby
## stands above the water within the search window). 4 = lake sits 2 cubes
## below the apex; surrounding GROUND peaks remain visible above the
## waterline. Must be even to preserve half-step snapping; clamped so
## lake_alt stays >= 0.
@export_range(0, 12, 2) var lake_depth_hs: int = 4

## Radius (in face-steps) of the apron lift around the lake. Each face-step
## outward, GROUND cells are lifted to at least `lake_alt - dist * falloff`.
## 0 = no apron (single-tile bank from `_support_water` only); 4 = the
## terrain ramps gradually up to lake altitude over four cells.
@export_range(0, 12, 1) var lake_apron_radius: int = 4

## Half-steps lost per face-step of distance from the lake. Must be even
## (altitudes are even half-steps). 2 = 1 cube per cell — combined with
## radius 4 produces a 4-cube total ramp. Higher values produce a steeper
## but still multi-cell apron; 0 produces a flat lifted plateau equal to
## lake altitude across the whole apron radius.
@export_range(0, 8, 2) var lake_apron_falloff_hs: int = 2


# --- River walker -----------------------------------------------------------

## Bias toward DIR_SW over DIR_SE for the river walker's south step. The
## walker is strictly south-going (SE or SW each step), and `south_bias` is
## an additive weight bonus on the SW direction so the river tends to
## spread laterally rather than shooting straight down. 0 = SE/SW chosen
## purely by altitude drop; higher values steer the river toward DIR_SW
## (visually, toward the south-west / left in iso).
@export_range(0.0, 4.0, 0.05) var south_bias: float = 1.0

## Maximum altitude drop, in full cubes (1 cube = 2 half-steps), allowed
## between adjacent cells. The smoothing pass caps any larger drops by
## raising the lower cell. The walker also won't take a step that drops
## more than this. 4 = up to 4-tile cliffs (recommended for visible terrace
## drops); 8 = up to 8-tile cliffs (more dramatic but rarer in practice
## given the heightfield's smoothness).
@export_range(1, 8, 1) var max_drop_cubes: int = 4

## Per-step probability that the river walker spawns a tributary at the
## unchosen SE/SW candidate. 0 = no branches (single river, current
## behavior). 0.1 = on a 30-step river, ~3 branches on average. Branches are
## single-depth (they don't recursively branch), run after the primary
## walker completes, and don't widen. A branch that boxes in early simply
## stops — it doesn't have to reach the south boundary.
##
## Capped at 0.5 to avoid pathological maps where a branch spawns at every
## step. Branches CAN modify cells the primary walker already touched (no
## merge logic): if a branch crosses the primary path, both cells stay WATER.
@export_range(0.0, 0.5, 0.05) var river_branch_chance: float = 0.0


# --- Corner rounding --------------------------------------------------------

## Radius (face-step distance) of the silhouette window. Each cell looks at
## all in-bounds cells within this many face-steps and computes the GROUND
## fraction of that window. 0 = silhouette unchanged. 2 = picks up corners
## formed by 2-3-cell straight runs (recommended). 4-5 = picks up large
## structural corners (4+ cell runs) but starts erasing FBM edge jitter.
@export_range(0, 5, 1) var silhouette_round_radius: int = 2

## Stickiness threshold for the silhouette majority filter. A GROUND cell
## flips to EMPTY only if its window's GROUND fraction < 0.5 - stickiness;
## an EMPTY cell flips to GROUND only if fraction > 0.5 + stickiness. Higher
## stickiness preserves more of the original outline (only very lopsided
## majorities trigger flips). 0 = pure majority (eager). 0.15 = balanced.
## 0.3+ = preserves shape strongly; only obvious corners get rounded.
@export_range(0.0, 0.4, 0.05) var silhouette_round_stickiness: float = 0.15

## Radius (face-step distance) of the altitude window. Each GROUND cell
## takes the median altitude of all GROUND/WATER/WATERFALL cells within
## this radius and pulls toward it. 0 = altitude unchanged. 2 = catches
## small altitude bumps and 90° cliff-corner taper (recommended). 4+ =
## smooths longer altitude transitions (can erode peaks).
@export_range(0, 5, 1) var altitude_round_radius: int = 2

## How strongly the altitude pull replaces the cell's current altitude.
## 0 = no change. 1 = full median replacement (classic median filter,
## edge-preserving). 0.5 = halfway between current and median (gentler).
## Median filtering naturally preserves clean cliffs (step functions) so
## even at strength 1 long straight cliff faces remain intact; only their
## corners and noise get smoothed.
@export_range(0.0, 1.0, 0.05) var altitude_round_strength: float = 0.5

## Number of (silhouette + altitude) iterations. Each iteration runs both
## passes once. 0 = rounding disabled. 1 = single light pass (recommended).
## 2-3 = progressively stronger; multi-cell promontories shrink layer by
## layer and structural corners round more deeply.
@export_range(0, 3, 1) var corner_round_passes: int = 1
