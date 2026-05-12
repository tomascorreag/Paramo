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
