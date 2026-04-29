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

## Maximum altitude in half-steps (1 cube = 2 half-steps). Caps the lake
## (always at top_altitude) and the heightfield's tallest peak. The scene's
## TileMapLayer stack must have enough layers to render this — default
## scene supports up to altitude 16 (8 cubes / 9 layers). Must be even.
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
@export_range(0.0, 2.0, 0.05) var weight_n: float = 1.0

## Weight of the SW→NE gradient. Peaks along y=0 (the visual NE back edge).
## Adds height to the NE wall so it reads as a ridge, not just an apex.
## 0 = no NE wall lift; the NE edge follows pure noise.
@export_range(0.0, 2.0, 0.05) var weight_ne: float = 0.6

## Weight of the SE→NW gradient. Peaks along x=0 (the visual NW back edge).
## Symmetric companion to `weight_ne` — together they raise both back walls.
## 0 = no NW wall lift.
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
