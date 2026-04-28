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


# Diamond-axis directions — re-exported from DiamondCompass so consumers
# can write `TerrainCell.DIR_NE` without round-tripping through the compass
# class. Values are authoritative there; do not redefine here.
const DIR_NE: Vector2i = DiamondCompass.DIR_NE
const DIR_NW: Vector2i = DiamondCompass.DIR_NW
const DIR_SE: Vector2i = DiamondCompass.DIR_SE
const DIR_SW: Vector2i = DiamondCompass.DIR_SW


# Half-step altitude this cell occupies. For SLOPE_* cells, this is the LOW
# end (the layer the slope lives on). Snapped to even values 0..top_altitude.
var altitude: int = 0

var kind: int = Kind.EMPTY  # use Kind enum values

# Only meaningful when kind == GROUND.
var biome: int = Biome.GRASS
var ground_shape: int = GroundShape.FULL_CUBE

# Continuous biome score (= altitude + biome_noise * amplitude) computed in
# TerrainGenerator._assign_biomes. The painter uses it to derive a "centrality"
# value for grass variant selection: cells with low score are deep in grass,
# cells near 4.0 sit at the grass/dirt boundary.
var biome_score: float = 0.0

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

# Only meaningful when kind == WATERFALL. Vertical span of the drop in
# half-steps (even values, >= 2). The cell is stored at the LIP altitude;
# the basin sits at altitude - drop_height. drop_height == 2 reproduces the
# original single-cube drop. The painter expands the column across multiple
# layers using FALL_*_TOP/NONE/BOTTOM tiles.
var drop_height: int = 2

# Width of the river segment passing through this cell, in cells. 0 means
# "not a river cell" (lake interior or any non-river water). The river
# starts at width 2 leaving the lake and may shrink at branches.
var river_width: int = 0


static func make_empty() -> TerrainCell:
	var c := TerrainCell.new()
	c.kind = Kind.EMPTY
	return c
