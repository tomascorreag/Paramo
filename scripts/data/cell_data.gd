class_name CellData
extends RefCounted

# ============================================================================
# CellData
# ============================================================================
#
# Typed per-cell state held by TileGrid. Replaces the old
# `Dictionary[Vector2i, Dictionary]` dict shape with concrete fields so
# consumers get autocomplete and type safety.
#
# Named "CellData" (not "TileData") because Godot's TileSet system already
# ships a class_name TileData — clashing would shadow a built-in.
#
# Fields mirror what TileGrid previously stored in its dict entries. Extra
# fields are reserved for upcoming runtime systems (health, moisture,
# biodiversity) — defaults are inert so systems that don't use them see sane
# values.
#
# Not a Godot Resource: RefCounted is enough (no serialization needed; grid
# is rebuilt from TileMapLayers on load).
#
# ============================================================================


# --- Shape / layer (set by TileGrid.build) ---------------------------------

var walkable: bool = false
var layer: TileMapLayer
var tile_kind: StringName = &""
var rise_dir: Vector2i = Vector2i.ZERO

# --- Altitude (half-steps; see TileGrid doc-block) -------------------------

var altitude_low: int = 0
var altitude_high: int = 0
var altitude_center: float = 0.0

# Altitude of the tile's topmost visible pixel (walkable surface for
# walkables, top of wall art for non-walkables). Derived from the tile's
# texture_origin at ingest so hover hit-testing respects the art convention:
#   - texture_origin.y < 0 (FULL_CUBE): walkable on top, sides extend DOWN
#     → visual_top == altitude_high.
#   - texture_origin.y > 0 AND ramp_size == 0 (e.g. FULL_CUBE high-variant):
#     art extends UP from paint layer, walkable at the top of the art
#     → visual_top == altitude_high + 2.
#   - Ramps (ramp_size > 0): walkable surface reaches altitude_high
#     → visual_top == altitude_high.
#   - Non-walkable walls / decoration (texture_origin.y > 0):
#     → visual_top == altitude_low + 2.
var visual_top: int = 0

# --- Runtime state (reserved — default values until systems land) ----------

var health: float = 1.0
var moisture: float = 0.0
var biodiversity: float = 0.0


static func make_walkable(
	cell_layer: TileMapLayer,
	kind: StringName,
	rise: Vector2i,
	alt_low: int,
	alt_high: int,
	visual_top_alt: int = -1,
) -> CellData:
	var t := CellData.new()
	t.walkable = true
	t.layer = cell_layer
	t.tile_kind = kind
	t.rise_dir = rise
	t.altitude_low = alt_low
	t.altitude_high = alt_high
	t.altitude_center = (alt_low + alt_high) / 2.0
	t.visual_top = alt_high if visual_top_alt == -1 else visual_top_alt
	return t


static func make_blocked(
	cell_layer: TileMapLayer,
	altitude: int,
	visual_top_alt: int = -1,
) -> CellData:
	var t := CellData.new()
	t.walkable = false
	t.layer = cell_layer
	t.altitude_low = altitude
	t.altitude_high = altitude
	t.altitude_center = float(altitude)
	t.visual_top = (altitude + 2) if visual_top_alt == -1 else visual_top_alt
	return t
