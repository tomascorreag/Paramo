@tool
class_name TerrainGenerationParams
extends Resource

# ============================================================================
# TerrainGenerationParams
# ============================================================================
#
# Resource-backed input to TerrainGenerator.generate(). All knobs are
# `@export`-ed so a designer can tune a preset in the inspector and save it
# as a `.tres` under `resources/terrain/`. The per-map `ProceduralWorld`
# node references one of these (with optional per-instance overrides for
# the most commonly-tweaked fields, like `seed`).
#
# Replaces the previous `TerrainGenerator.Params` inner RefCounted class —
# moving to Resource keeps the system data-driven (CLAUDE.md: "all systems
# are data-driven; new content = new resource files, not new code").
#
# All ranges and step values mirror the previous inspector exports on
# ProceduralWorld so existing tuning carries over by value.
#
# ============================================================================


# --- Map dimensions ---------------------------------------------------------

@export var seed: int = 0
@export_range(8, 200, 1) var width: int = 32
@export_range(8, 200, 1) var height: int = 48
@export_range(2, 32, 2) var top_altitude: int = 16


# --- Cone shape -------------------------------------------------------------

## Per-seed apex jitter as a fraction of max(width, height). The apex base
## is the visual N corner of the iso diamond; jitter slides along the NE /
## NW edges. 0 = locked to the corner; ~0.15 = visible per-seed variety.
@export_range(0.0, 0.5, 0.01) var apex_x_jitter_frac: float = 0.15

## Multiplier on the auto-fit cone slope. Auto-fit makes the cone reach
## altitude 0 at the far diagonal corner; >1 bottoms out earlier (wider
## flat skirt); <1 keeps the entire map elevated.
@export_range(0.3, 2.0, 0.05) var cone_steepness: float = 1.0

## Forces every GROUND cell's screen-south neighbor (x+1, y+1) to sit at or
## below this cell's altitude, guaranteeing a camera-facing cliff on every
## elevated stack. Improves elevation readability in iso view at the cost of
## a small amount of organic shape variation on the south face.
@export var enforce_south_cliff: bool = true


# --- River walker -----------------------------------------------------------

## Additive weight given to a south-going river step (positive Y) when the
## walker has multiple downhill candidates. 0 = uniform random.
@export_range(0.0, 4.0, 0.05) var south_bias: float = 0.5

## Per-waterfall probability of forking the river into a same-tier branch.
@export_range(0.0, 1.0, 0.05) var branch_chance: float = 0.25

## Cell width of the stream leaving the lake. May shrink at branch points.
@export_range(1, 6, 1) var initial_river_width: int = 2

## Reweights drop-candidate selection. 0 = uniform across legal drops.
## >0 favors taller drops; <0 favors shorter. Combines multiplicatively
## with `south_bias` per candidate.
@export_range(-2.0, 2.0, 0.1) var drop_height_bias: float = 0.0

## Maximum altitude drop allowed in the heightfield, in full cubes (1
## cube = 2 half-steps). Caps both smoothing and the river trace.
@export_range(1, 8, 1) var max_drop_cubes: int = 4

## Safety cap on total walker steps. Should rarely matter; raise only if
## very large maps abort with a "max_river_steps" warning.
@export_range(256, 16384, 256) var max_river_steps: int = 4096

## Cap on consecutive forced-south stall steps before a walker is aborted.
@export_range(1, 64, 1) var max_stall_steps: int = 8


# --- Terrain noise ----------------------------------------------------------

@export_range(0.005, 1.0, 0.005) var height_noise_frequency: float = 0.04
@export_range(0.0, 8.0, 0.1) var height_noise_amplitude: float = 3.0

## Power applied to the [-1, 1] height noise to sharpen transitions. 1.0
## is identity (smooth Perlin). >1 pushes values toward the extremes —
## adjacent cells more often land on opposite tails, producing taller
## cliffs. <1 flattens toward zero.
@export_range(0.1, 8.0, 0.1) var cliff_bias: float = 1.0

@export_range(0.005, 0.2, 0.005) var biome_noise_frequency: float = 0.06
@export_range(0.0, 6.0, 0.1) var biome_noise_amplitude: float = 2.0


# --- Slopes -----------------------------------------------------------------

## Per-cell probability that an uphill-edge GROUND cell becomes a slope.
## Reachability slopes (≥1 entry per plateau) are added on top regardless.
@export_range(0.0, 1.0, 0.05) var slope_chance: float = 0.35


# --- Lake -------------------------------------------------------------------

@export_range(0.5, 12.0, 0.1) var lake_radius: float = 2.6

## Strength of the noise that perturbs the lake's shape. 0 = perfect disc;
## higher = more irregular shoreline.
@export_range(0.0, 2.0, 0.05) var lake_jitter_strength: float = 0.5

## Per-seed random aspect-ratio range. Each generation picks aspect_x and
## aspect_y uniformly from [min, max].
@export_range(0.3, 1.0, 0.05) var lake_aspect_min: float = 0.7
@export_range(1.0, 2.5, 0.05) var lake_aspect_max: float = 1.4
