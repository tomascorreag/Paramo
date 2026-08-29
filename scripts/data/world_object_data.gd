@tool
class_name WorldObjectData
extends Resource

# ============================================================================
# WorldObjectData
# ============================================================================
#
# Per-kind metadata for a Node2D occupant of the TileGrid (frailejon, rock,
# future fences/signage). Authored as a `.tres` under `resources/objects/` and
# referenced by ObjectPainter (procedural spawn) or the action layer (player
# placement, future).
#
# This is the metadata side. The visuals live in the referenced scene; the
# behavior lives in the scene's script. WorldObjectData centralizes the
# pieces other systems need without instantiating: whether the cell becomes
# blocked, what pathfinding penalty to charge, and the visual variants used
# by the rendered Sprite2D.
#
# Variant semantics on the base class are *random variations* — the consumer
# (e.g. rocks) picks one variant at spawn and never changes it. For
# *growth-stage* sequences (plants), use the PlantObjectData subclass instead.
#
# Note on scene wiring: the kind → PackedScene mapping lives on the spawner
# (ObjectPainter for procgen, TileInteractionController for plants) — NOT on
# this resource. Putting the scene here would create a load-time cycle when
# the scene's root @exports a WorldObjectData (rock.tscn → rock.tres →
# rock.tscn) which Godot's text resource loader cannot resolve.
#
# Not used for tile-painted Structures (bridges, ladders) — those keep the
# Traversal subclass approach. WorldObjectData is for sprite-rendered Node2D
# occupants only.
#
# ============================================================================


## Identity used by the registry on TileGrid (occupants_of_kind(id)). Must
## match the Node2D's occupant_kind() return value.
@export var id: StringName = &""

## TRANSLATION KEY for the name a player reads — what ActionInspect prints when
## it identifies this thing. A key, not a string, so the name follows the locale
## (assets/translations/paramo.csv, `FLORA_*`); empty means "nothing to say",
## which is what the rocks author.
##
## It lives on the data rather than in a table beside the action because that is
## how everything else about a kind is authored: a new species is a new .tres,
## and this is one more line in it. tests/test_localization.gd scans
## resources/objects for these keys, so an unlisted one fails there rather than
## printing "FLORA_CHUSQUE" at the player.
@export var name_key: StringName = &""

## When true, TileGrid.is_walkable returns false for any cell this object
## occupies. Pathfinder routes around. Set false for things like plants and
## signs that should be steppable.
@export var blocks_movement: bool = false

## Per-biome procgen spawn density. Keys are `TerrainCell.Biome` int values;
## each value is the per-cell roll probability in [0, 1] applied during
## `ObjectPainter.assign_object_kinds`. Missing biome keys default to 0.0,
## so an empty dict means this kind never spawns procedurally — the right
## default for player-only-placed objects (e.g. frailejones).
##
## Eligible cells are restricted to `kind == GROUND` and
## `ground_shape ∈ {FULL_CUBE, FLAT}` (slopes/stairs are excluded so the
## sprite never sits on a tilted surface). When multiple kinds have a
## non-zero density on the same biome, they're rolled in dictionary-key
## order and the first hit wins.
@export var density_by_biome: Dictionary = {}

## Preferred placement altitude in TerrainCell.altitude half-steps. When > 0,
## the per-cell density roll is multiplied by a Gaussian centered on this
## altitude (σ = ObjectPainter._SIGMA_ALT, in half-steps), so the kind
## clusters around the preferred elevation and tapers off above/below.
##
## Use to push snow-flecked rocks toward peaks (e.g. preferred_altitude = 24)
## or moss-covered rocks toward the valley floor (e.g. 4) without having to
## hand-author per-altitude density curves.
##
## When <= 0 (default), the altitude term is dropped entirely — placement is
## flat across all eligible altitudes, identical to behavior before this
## field existed. Mirrors the `<= 0 → ignore` opt-out semantics used by the
## tile painter's `preferred_altitude` custom_data layer.
@export var preferred_altitude: int = 0

## Inclusive altitude plateau in TerrainCell.altitude half-steps, for kinds
## whose real range is a band rather than a peak (every plant species). Inside
## the band the density multiplier is 1; outside it decays as a Gaussian on the
## distance to the nearest band edge (σ = ObjectPainter._SIGMA_ALT). `x < 0`
## (default) disables the band and the kind falls back to `preferred_altitude`
## (or to flat placement when that is also off). When both are set, the band
## wins — a kind should author one or the other, not both.
@export var altitude_band: Vector2i = Vector2i(-1, -1)

## Clumping gate. When > 0, ObjectPainter samples one seeded FastNoiseLite
## per kind at this frequency (in cells⁻¹) and multiplies the per-cell density
## by `clamp((noise - patch_cut) / patch_edge, 0, 1)`, so the kind only appears
## inside noise "patches" — community-scale stands (a chuscal, a matorral)
## rather than a uniform sprinkle. Frequency sets the patch SIZE only (~0.06 →
## 15-cell blobs, ~0.10 → 8-cell); the amplitude distribution is identical at
## every frequency, so `patch_cut` and `patch_edge` mean the same thing
## whatever size the patches are. Patches are seeded per kind from the object
## rng, so they are part of the seed's identity and different species do not
## share outlines.
@export var patch_frequency: float = 0.0

## Where the patch starts, on the noise value. TYPE_SIMPLEX_SMOOTH output
## measured over 12 seeds × 48×48: range ±0.75, p50 0.00, p75 0.18, p90 0.33,
## p99 0.54. So the fraction of the map at or above the cut is ≈ 0.65 at −0.1,
## 0.50 at 0.0, 0.36 at 0.1, 0.22 at 0.2, 0.17 at 0.25.
@export_range(-1.0, 0.99) var patch_cut: float = 0.0

## Width of the ramp from `patch_cut` up to full density, on the same noise
## scale. This is what decides whether a stand has an INTERIOR: the plateau
## (cells at full density) is everything above `patch_cut + patch_edge`, and
## because the noise only reaches ±0.75 a wide ramp means the kind never
## reaches its authored density anywhere — the patch is all edge. Measured
## plateau share of the map, by (cut, edge):
##
##     cut     edge 0.08   edge 0.12   edge 0.20   edge 0.25
##     -0.20      0.67        0.62        0.50        0.43
##      0.00      0.39        0.33        0.23        0.17
##      0.20      0.14        0.11        0.05        0.03
##      0.30      0.06        0.04        0.01        0.01
##
## A narrow edge with a high cut gives few, dense, sharp-edged stands (a
## chuscal); a wide edge with a low cut gives a soft mosaic (the pajonal
## matrix). Total count is `density × mean multiplier`, so tightening the
## patch without raising `density_by_biome` just deletes plants.
@export_range(0.01, 1.0) var patch_edge: float = 0.25

## When true, placing something on this occupant's cell (planting, building)
## frees it instead of being refused. Natural ground cover (tussock grasses,
## bamboo) is displaceable; anything the player paid for, and rocks, are not.
## Read through the occupant's `is_displaceable()` by the action layer.
@export var displaceable: bool = false

## Extra enter cost added to any A* step that lands on a cell this object
## occupies. 0.0 = no penalty. >0 nudges paths around; >1 forces detours when
## an alternative exists. Ignored when blocks_movement = true.
@export var walk_penalty: float = 0.0

## Sprite variants. Each entry is a Texture2D — typically an AtlasTexture.tres
## with the region authored visually in the inspector, but a plain Texture2D
## (separate file per variant) also works. The consuming Node2D assigns one
## of these to its Sprite2D (and shadow) at spawn / on state change.
##
## Base-class semantics: *random variations*. The painter or spawner picks a
## variant deterministically (e.g. by hashing seed+cell) and the choice is
## fixed for the instance's lifetime.
@export var variants: Array[Texture2D] = []

## When true, each spawned instance flips its sprite horizontally with 50%
## probability for cheap visual variety. Set false when a variant has a
## fixed orientation (e.g. directional signage).
@export var randomize_flip_h: bool = true

## How many plants of this kind stand on one cell, rolled per cell in
## [x, y] inclusive. The GRID still holds exactly one occupant — this is a
## DRAWING count, not an occupancy count: the frontmost individual is the
## node's Sprite2D and the rest are drawn by the node's own _draw(), so a
## four-tuft cell costs the same CanvasItem as a one-tuft cell and
## ObjectPainter's plant budget (which counts cells) still means what it says.
##
## Why it exists: per-cell density saturates at 1 (ObjectPainter occupies a
## cell with probability min(Σd, 1)), so one sprite per cell is the densest
## stand the scatter can express. A real pajonal has tussocks ~0.5 m apart and
## a cell is ~2 m across, so the honest count for ground cover is several.
## Leave at (1, 1) for anything with a trunk or a rosette — an Espeletia is
## one plant on one cell.
@export var individuals_per_cell: Vector2i = Vector2i(1, 1)
