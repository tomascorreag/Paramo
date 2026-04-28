class_name TerrainCell
extends RefCounted

# ============================================================================
# TerrainCell
# ============================================================================
#
# Plain data record for one cell in the abstract procedural terrain model.
# This is NOT the runtime CellData (`scripts/data/cell_data.gd`) — that one
# is read back from painted TileMapLayers. TerrainCell is the pre-paint
# intermediate produced by TerrainGenerator and consumed by TerrainPainter.
#
# All fields are independently meaningful so the painter can lay out tiles
# without re-deriving anything.
#
# ============================================================================


enum Kind {
	EMPTY,      # nothing here — out-of-pyramid or off-map
	GROUND,     # land tile (FULL_CUBE / FLAT / SLOPE_*)
	WATER,      # WATER_FLAT or shore EDGE_*/CORNER_*
	WATERFALL,  # vertical drop between two altitudes; FALL_* tile
}


enum Biome {
	GRASS,
	DIRT,
	ROCK,
	SNOW,
}


enum GroundShape {
	FULL_CUBE,
	FLAT,
	SLOPE_NE,
	SLOPE_NW,
	SLOPE_SE,
	SLOPE_SW,
}


# Diamond-axis directions (matches tile_slots.gd compass: cell ( 0,-1) → NE,
# (-1, 0) → NW, ( 1, 0) → SE, ( 0, 1) → SW).
const DIR_NE: Vector2i = Vector2i( 0, -1)
const DIR_NW: Vector2i = Vector2i(-1,  0)
const DIR_SE: Vector2i = Vector2i( 1,  0)
const DIR_SW: Vector2i = Vector2i( 0,  1)


# Half-step altitude this cell occupies. For SLOPE_* cells, this is the LOW
# end (the layer the slope lives on). Snapped to even values 0..top_altitude.
var altitude: int = 0

var kind: int = Kind.EMPTY  # use Kind enum values

# Only meaningful when kind == GROUND.
var biome: int = Biome.GRASS
var ground_shape: int = GroundShape.FULL_CUBE

# Only meaningful when kind == WATER. ZERO = still water (lake interior).
var water_flow: Vector2i = Vector2i.ZERO

# 4-bit mask of land-bearing diamond-face neighbors, only set on WATER cells.
# bit 0 (1)  = NE neighbor is land
# bit 1 (2)  = NW neighbor is land
# bit 2 (4)  = SE neighbor is land
# bit 3 (8)  = SW neighbor is land
var shore_mask: int = 0

# Only meaningful when kind == WATERFALL. The rise direction of the cliff
# the water is falling from. v1 supports DIR_NE and DIR_NW (matches the
# painted FALL_NE_*/FALL_NW_* atlas variants).
var fall_rise_dir: Vector2i = Vector2i.ZERO

# Width of the river segment passing through this cell, in cells. 0 means
# "not a river cell" (lake interior or any non-river water). The river
# starts at width 2 leaving the lake and may shrink at branches.
var river_width: int = 0


static func make_empty() -> TerrainCell:
	var c := TerrainCell.new()
	c.kind = Kind.EMPTY
	return c
