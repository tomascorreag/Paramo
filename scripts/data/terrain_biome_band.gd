@tool
class_name TerrainBiomeBand
extends Resource

# ============================================================================
# TerrainBiomeBand
# ============================================================================
#
# One entry in TerrainGenerationParams.biome_bands. Each band claims a slice
# of the [0, top_altitude] range, sized proportionally to its `weight`
# relative to the sum of all band weights. Bands stack bottom-up in array
# order — index 0 occupies the lowest altitudes, last index occupies the
# top.
#
# Per-cell biome assignment uses `altitude + biome_noise * biome_noise_amplitude`
# (see TerrainGenerator._assign_biomes), so band boundaries are noisy rather
# than hard altitude lines. Set biome_noise_amplitude to 0 in the params for
# strict bands.
#
# Default preset (resolve_biome_thresholds in TerrainGenerationParams):
#   GRASS weight 3, DIRT weight 1, ROCK weight 1, SNOW weight 1
#   → 50% / 16.7% / 16.7% / 16.7% of the altitude range.
#
# ============================================================================


## Biome occupying this altitude band. Values match TerrainCell.Biome:
##   0 = GRASS, 1 = DIRT, 2 = ROCK, 3 = SNOW
## Painter sources: GRASS has all tile shapes; DIRT has FLAT/FULL_CUBE; ROCK
## and SNOW only have FULL_CUBE (slopes fall back to grass tiles).
@export_enum("Grass:0", "Dirt:1", "Rock:2", "Snow:3") var biome: int = 0

## Relative size of this band. Each band's altitude span =
## (weight / sum_of_weights) * top_altitude. Setting to 0 effectively
## removes the band. Negative values are clamped to 0 in the resolver.
@export_range(0.0, 10.0, 0.05) var weight: float = 1.0


# --- Per-biome variant-selection noise --------------------------------------
#
# Both fields drive the painter's tile-variant picker (currently grass
# FULL_CUBE; any future multi-variant biome inherits this for free). They are
# independent of params.biome_noise_* — that one jitters BAND BOUNDARIES (which
# biome a cell gets); these tune VARIANT SELECTION within the biome.

## Spatial coherence of variant selection. The picker normally rolls each cell
## with a hash-based uniform [0,1] value. Strength blends a per-biome noise
## sample into that roll (lerp(hash, noise, strength)).
##   0.0 = no noise; pure uniform random within the gaussian preferences (legacy)
##   0.5 = noticeable clumping; same-variant patches form but breaks of single
##         cells still appear
##   1.0 = roll is fully driven by noise; large coherent same-variant patches
##         (a single hill paints uniformly with one variant)
## When 0, `noise_frequency` has no effect and no FastNoiseLite is allocated.
@export_range(0.0, 1.0, 0.05) var noise_strength: float = 0.0

## Spatial frequency of the variant-selection noise. Lower = larger patches of
## the same variant; higher = smaller, more cellular variation.
##   ~0.02 = whole-mountain patches
##   ~0.05 = recommended starting point
##   ~0.2  = noisy, patches only a few cells across
## Ignored when `noise_strength` is 0.
@export_range(0.005, 0.5, 0.005) var noise_frequency: float = 0.05
