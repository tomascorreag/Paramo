class_name TileSlots
extends RefCounted

# ============================================================================
# Paramo tile slot schema
# ============================================================================
#
# Declarative list of valid tile slot names, expressed as StringName constants.
# These names are the shared vocabulary between:
#   - the Godot editor, where each painted tile's `tile_kind` custom data
#     field is set to one of these strings, and
#   - gameplay code, which resolves a name to an atlas coord via
#     TileKindIndex.coord(TileSlots.FOO).
#
# ----------------------------------------------------------------------------
# Source of truth
# ----------------------------------------------------------------------------
#
# The `tile_kind` custom data on each painted tile is THE source of truth
# for the name->coord mapping. TileKindIndex scans the atlas once at startup
# and builds the lookup dict; no manual hand-syncing of atlas coords into
# this file is needed. Adding a new slot is two steps:
#
#   1. Add a new `const` below with the slot's StringName.
#   2. Paint a tile in the editor and set its `tile_kind` custom data to
#      match. (Step is reversible — unpainted slots warn at startup but
#      don't crash; the index returns Vector2i(-1, -1) for unknown names.)
#
# TileKindIndex validates both directions on startup and push_warning()s:
#   - declared here but unpainted  -> slot will silently no-op at runtime
#   - painted but not declared     -> typo in the editor's custom data field
#
# ----------------------------------------------------------------------------
# Compass convention (LOCKED — Convention A: diamond-corner compass)
# ----------------------------------------------------------------------------
#
# Iso tiles use Godot's "Diamond Down" layout. Compass directions map to the
# four CORNERS of the diamond tile (screen-cardinal), and grid axes run along
# the four EDGES of the diamond (screen-diagonal).
#
#                          N                        (straight up on screen)
#                         / \
#                        /   \
#                      NW     NE                    (visible cube faces)
#                      /       \
#                     /         \
#                    W           E                  (straight left / right)
#                     \         /
#                      \       /
#                      SW     SE                    (hidden cube faces)
#                        \   /
#                         \ /
#                          S                        (straight down on screen)
#
# Grid-to-screen mapping (from any cell (x, y) in Diamond Down):
#
#     cell ( 0, -1)  ->  visually UP-RIGHT  ->  NE
#     cell (-1,  0)  ->  visually UP-LEFT   ->  NW
#     cell ( 1,  0)  ->  visually DOWN-RIGHT->  SE
#     cell ( 0,  1)  ->  visually DOWN-LEFT ->  SW
#     cell (-1, -1)  ->  visually STRAIGHT UP    ->  N
#     cell ( 1, -1)  ->  visually STRAIGHT RIGHT ->  E
#     cell ( 1,  1)  ->  visually STRAIGHT DOWN  ->  S
#     cell (-1,  1)  ->  visually STRAIGHT LEFT  ->  W
#
# ----------------------------------------------------------------------------
# Directional naming rules
# ----------------------------------------------------------------------------
#
# Slopes and stairs in the BaseTiles.png art rise ALONG grid axes, which is
# visually screen-diagonal. Their suffix is therefore always NW/NE/SE/SW and
# indicates the direction they RISE TOWARD (high end of the slope).
#
#     SLOPE_NE = rises toward upper-right (low end SW, high end NE)
#     STAIR_NW = rises toward upper-left
#     ...
#
# Walls and edges of a cube-footprint tile face the four screen-diagonals
# (the visible cube faces are NW and NE; SW and SE are the far sides).
#
#     WALL_NE = the wall on the NE face of a block (upper-right face on screen)
#     EDGE_SW = a tile-edge feature on the SW side
#
# FLAT, FULL_CUBE, HALF_CUBE are non-directional structural pieces.
#
# HALF_* variants (HALF_CUBE, HALF_SLOPE_*, HALF_STAIR_*) are half-height
# elevation steps. They live on the same mid TileMapLayer as their full-height
# counterparts — no dedicated layer. To sort correctly against full-height
# neighbors on the same layer, each half-height tile must have its TileData
# `y_sort_origin` set to `+8` during the editor paint pass. Full-height tiles
# on the same layer keep `y_sort_origin = 0`.
#
# ============================================================================


# --- Biome source IDs (inside resources/tiles/base_tileset.tres) ------------
const BIOME_BASE_SOURCE_ID: int = 0    # BaseTiles.png (dirt/earth)
# Future: const BIOME_GRASS_SOURCE_ID: int = 1, etc.


# --- Non-directional structural pieces --------------------------------------
const FLAT: StringName              = &"FLAT"
const FULL_CUBE: StringName         = &"FULL_CUBE"
const HALF_CUBE: StringName         = &"HALF_CUBE"


# --- Slopes (rise toward the named diagonal) --------------------------------
const SLOPE_NW: StringName          = &"SLOPE_NW"
const SLOPE_NE: StringName          = &"SLOPE_NE"
const SLOPE_SE: StringName          = &"SLOPE_SE"
const SLOPE_SW: StringName          = &"SLOPE_SW"


# --- Half-height slopes (rise one half-step toward the named diagonal) ------
const HALF_SLOPE_NW: StringName     = &"HALF_SLOPE_NW"
const HALF_SLOPE_NE: StringName     = &"HALF_SLOPE_NE"
const HALF_SLOPE_SE: StringName     = &"HALF_SLOPE_SE"
const HALF_SLOPE_SW: StringName     = &"HALF_SLOPE_SW"


# --- Stairs (rise toward the named diagonal) --------------------------------
const STAIR_NW: StringName          = &"STAIR_NW"
const STAIR_NE: StringName          = &"STAIR_NE"
const STAIR_SE: StringName          = &"STAIR_SE"
const STAIR_SW: StringName          = &"STAIR_SW"


# --- Half-height stairs (rise one half-step toward the named diagonal) ------
const HALF_STAIR_NW: StringName     = &"HALF_STAIR_NW"
const HALF_STAIR_NE: StringName     = &"HALF_STAIR_NE"
const HALF_STAIR_SE: StringName     = &"HALF_STAIR_SE"
const HALF_STAIR_SW: StringName     = &"HALF_STAIR_SW"


# --- Walls (face the named diagonal; NW/NE are the visible faces) -----------
const WALL_NW: StringName           = &"WALL_NW"
const WALL_NE: StringName           = &"WALL_NE"
const WALL_SE: StringName           = &"WALL_SE"
const WALL_SW: StringName           = &"WALL_SW"


# --- Ladders (camera-facing variants — hang on NE/NW walls, Minecraft-style)
# Non-walkable like walls (absent from tile_grid._SHAPES); traversal wiring is
# handled by the Ladder traversal + Pathfinder.add_traversal_edge.
const LADDER_NE: StringName         = &"LADDER_NE"
const LADDER_NW: StringName         = &"LADDER_NW"


# --- Edges (tile-edge features along the named diagonal side) ---------------
const EDGE_NW: StringName           = &"EDGE_NW"
const EDGE_NE: StringName           = &"EDGE_NE"
const EDGE_SE: StringName           = &"EDGE_SE"
const EDGE_SW: StringName           = &"EDGE_SW"


# --- Water (flat overlay tiles with flow direction via alternatives) --------
const WATER_FLAT: StringName        = &"WATER_FLAT"
