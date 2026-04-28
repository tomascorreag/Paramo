class_name TerrainPainter
extends RefCounted

# ============================================================================
# TerrainPainter
# ============================================================================
#
# Pure translation: TerrainGrid → TileMapLayer.set_cell calls. Contains zero
# generation logic. Given a resolved abstract grid plus the layer stack and
# tileset, paints every cell on the correct layer with the correct atlas
# source / coord / alternative.
#
# Source ID convention (matches resources/tiles/base_tileset.tres):
#   GRASS  → 0
#   DIRT   → 2
#   ROCK   → 5    (only FULL_CUBE painted; falls back to grass for other shapes)
#   SNOW   → 4    (same fallback)
#   WATER  → 3
#
# Slope tiles paint on the LOW-end layer (per tile_grid.gd convention) — the
# painter reads `cell.altitude` directly because the generator stores the LOW
# altitude there for SLOPE_* cells.
# ============================================================================


const SOURCE_GRASS: int = 0
const SOURCE_DIRT:  int = 2
const SOURCE_WATER: int = 3
const SOURCE_SNOW:  int = 4
const SOURCE_ROCK:  int = 5


# Water alternative_tile mapping. Indexed by direction → alt id painted in
# resources/tiles/base_tileset.tres on tile (0,0) of the water source:
#   alt 0 = still
#   alt 1 = NE
#   alt 2 = SE
#   alt 3 = SW
#   alt 4 = NW
const _WATER_ALT_STILL: int = 0
const _WATER_ALT_NE: int = 1
const _WATER_ALT_SE: int = 2
const _WATER_ALT_SW: int = 3
const _WATER_ALT_NW: int = 4


# ----------------------------------------------------------------------------
# Public entry
# ----------------------------------------------------------------------------

# `layers_by_altitude` maps altitude (int half-steps) → TileMapLayer.
# Caller supplies the dict so the painter doesn't need to know the layer-naming
# scheme; missing altitudes are skipped with a warning.
static func paint(
	grid: TerrainGrid,
	layers_by_altitude: Dictionary,
	tile_set: TileSet,
) -> void:
	if tile_set == null:
		push_error("TerrainPainter.paint: tile_set is null.")
		return

	# Cache one TileKindIndex per source we'll touch.
	var indices: Dictionary[int, TileKindIndex] = {}
	for src in [SOURCE_GRASS, SOURCE_DIRT, SOURCE_WATER, SOURCE_SNOW, SOURCE_ROCK]:
		indices[src] = TileKindIndex.new(tile_set, src)

	# Clear all target layers first so re-runs don't leave stale tiles.
	for alt_key in layers_by_altitude:
		var l: TileMapLayer = layers_by_altitude[alt_key]
		if l != null:
			l.clear()

	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind == TerrainCell.Kind.EMPTY:
				continue
			_paint_cell(grid, layers_by_altitude, indices, x, y, c)


# ----------------------------------------------------------------------------
# Per-cell paint
# ----------------------------------------------------------------------------

static func _paint_cell(
	grid: TerrainGrid,
	layers_by_altitude: Dictionary,
	indices: Dictionary,
	x: int,
	y: int,
	c: TerrainCell,
) -> void:
	var layer: TileMapLayer = layers_by_altitude.get(c.altitude, null)
	if layer == null:
		push_warning(
			"TerrainPainter: no layer registered for altitude %d (cell %d,%d) — skipping."
			% [c.altitude, x, y]
		)
		return

	var pos := Vector2i(x, y)

	match c.kind:
		TerrainCell.Kind.GROUND:
			_paint_ground(layer, indices, pos, c)
		TerrainCell.Kind.WATER:
			_paint_water(layer, indices, pos, c)
			# Water shader is semi-transparent. Fill the volume directly under
			# the water surface with dirt (floor + back walls on NE/NW only)
			# so the basin reads visually instead of looking like void.
			_paint_underwater_fill(
				grid, layers_by_altitude, indices, pos, c.altitude, c.shore_mask
			)
		TerrainCell.Kind.WATERFALL:
			_paint_waterfall(layer, indices, pos, c)
			# Waterfall tile only covers the cliff's wall face (upper layer).
			# The cell directly under it would otherwise be void, so paint
			# flowing water on the layer below to form the floor of the cliff
			# basin. Flow points downstream (away from the rise direction).
			var lower_layer: TileMapLayer = layers_by_altitude.get(c.altitude - 2, null)
			if lower_layer != null:
				_paint_under_waterfall(grid, lower_layer, indices, pos, c)
				# Underwater fill UNDER the basin water (basin_alt = T - 2).
				# Same treatment as WATER cells: dirt floor on layer T-4 plus
				# NE/NW back walls at the lateral bank coords.
				var basin_alt: int = c.altitude - 2
				var basin_mask: int = _basin_shore_mask(grid, pos, basin_alt)
				_paint_underwater_fill(
					grid, layers_by_altitude, indices, pos, basin_alt, basin_mask
				)
		_:
			pass


static func _paint_ground(
	layer: TileMapLayer,
	indices: Dictionary,
	pos: Vector2i,
	c: TerrainCell,
) -> void:
	var primary_src: int = _source_for_biome(c.biome)
	var kind: StringName = _ground_shape_to_kind(c.ground_shape)
	var src: int = primary_src
	var idx: TileKindIndex = indices[src]
	# Fallback: rock/snow only have FULL_CUBE painted. For any other shape on
	# those biomes, paint the slope/flat using grass tiles so the geometry is
	# still correct even if the biome look "leaks" at slope edges.
	if not idx.has(kind):
		src = SOURCE_GRASS
		idx = indices[src]
	if not idx.has(kind):
		push_warning(
			"TerrainPainter: tile_kind '%s' missing on source %d AND grass fallback — skipping cell %s."
			% [kind, primary_src, pos]
		)
		return
	var coord: Vector2i = idx.coord(kind)
	layer.set_cell(pos, src, coord, 0)


static func _paint_water(
	layer: TileMapLayer,
	indices: Dictionary,
	pos: Vector2i,
	c: TerrainCell,
) -> void:
	var idx: TileKindIndex = indices[SOURCE_WATER]
	var kind: StringName = _shore_kind_for_mask(c.shore_mask)
	# Universal fallback: any unpainted tile_kind defaults to WATER_FLAT,
	# preserving the cell's flow direction via the water-flow alternatives
	# painted on WATER_FLAT.
	_set_water_cell(layer, idx, pos, kind, c.water_flow)


static func _paint_waterfall(
	layer: TileMapLayer,
	indices: Dictionary,
	pos: Vector2i,
	c: TerrainCell,
) -> void:
	var idx: TileKindIndex = indices[SOURCE_WATER]
	var kind: StringName = _waterfall_kind_for_rise(c.fall_rise_dir)
	# A waterfall cell flows in the opposite direction of its rise (downhill,
	# away from the cliff above). The flow is meaningful for the WATER_FLAT
	# fallback only — painted FALL_* variants are single-alt.
	var flow: Vector2i = -c.fall_rise_dir
	_set_water_cell(layer, idx, pos, kind, flow)


# Shared painter for any water/waterfall cell. Tries `kind` first; if not
# painted on the water source, falls back to WATER_FLAT. WATER_FLAT is painted
# with the flow alternative so direction is preserved across the fallback.
# Specific shore variants (EDGE_*/CORNER_*/INNER_*/FALL_*) are painted with
# alt 0 — they're single-alternative tiles.
static func _set_water_cell(
	layer: TileMapLayer,
	idx: TileKindIndex,
	pos: Vector2i,
	kind: StringName,
	flow: Vector2i,
) -> void:
	var resolved: StringName = kind
	if not idx.has(resolved):
		resolved = TileSlots.WATER_FLAT
	if not idx.has(resolved):
		push_warning(
			"TerrainPainter: WATER_FLAT not painted on water source — skipping %s." % pos
		)
		return
	var coord: Vector2i = idx.coord(resolved)
	var alt_id: int = 0
	if resolved == TileSlots.WATER_FLAT:
		alt_id = _water_alt_for_flow(flow)
	layer.set_cell(pos, SOURCE_WATER, coord, alt_id)


# Paints the floor under a waterfall — flowing water on the lower layer at
# the same grid coord. Without this the cliff basin renders as void because
# the waterfall tile only occupies the upper cube's side face.
#
# The basin lives at altitude T-2 (one tier below the waterfall). The cliff
# side (= rise_dir) is intentionally NOT marked as shore — that face is already
# covered by the waterfall paint above, so a corner tile would double-render.
# Only the lateral bank gets the shore decoration: a single EDGE_* tile on
# whichever side the river bank sits. If both lateral sides are banks (a
# 1-wide drop) we pick one arbitrarily; if neither is (a 3+-wide drop with
# water siblings on both sides) we fall back to flat water.
static func _paint_under_waterfall(
	grid: TerrainGrid,
	lower_layer: TileMapLayer,
	indices: Dictionary,
	pos: Vector2i,
	c: TerrainCell,
) -> void:
	var idx: TileKindIndex = indices[SOURCE_WATER]
	var basin_alt: int = c.altitude - 2
	var mask: int = _basin_shore_mask(grid, pos, basin_alt)
	var kind: StringName = _basin_kind_for_mask(mask, c.fall_rise_dir)
	var flow: Vector2i = -c.fall_rise_dir
	_set_water_cell(lower_layer, idx, pos, kind, flow)


# Computes a 4-bit face-shore mask for the basin under a waterfall. A
# neighboring grid cell counts as OPEN WATER on the basin's lower layer iff:
#   - it is itself a WATERFALL (the painter places a basin under each
#     waterfall, so the lower-layer cell at that coord is water at T-2), OR
#   - it is WATER stored at the basin's altitude (downstream / upstream
#     continuation of the river at the lower tier).
# Anything else (off-grid, GROUND, WATER stored at the upper tier, EMPTY) is
# treated as land for shore-edge purposes.
static func _basin_shore_mask(grid: TerrainGrid, pos: Vector2i, basin_alt: int) -> int:
	var dirs: Array[Vector2i] = [
		TerrainGenerator.DIR_NE,
		TerrainGenerator.DIR_NW,
		TerrainGenerator.DIR_SE,
		TerrainGenerator.DIR_SW,
	]
	var bits: Array[int] = [1, 2, 4, 8]
	var mask: int = 0
	for i in dirs.size():
		var n: Vector2i = pos + dirs[i]
		if not _basin_neighbor_is_basin_water(grid, n, basin_alt):
			mask |= bits[i]
	return mask


static func _basin_neighbor_is_basin_water(
	grid: TerrainGrid,
	pos: Vector2i,
	basin_alt: int,
) -> bool:
	var nc: TerrainCell = grid.at_or_null(pos.x, pos.y)
	if nc == null:
		return false
	if nc.kind == TerrainCell.Kind.WATERFALL:
		return true
	if nc.kind == TerrainCell.Kind.WATER and nc.altitude == basin_alt:
		return true
	return false


# Basin-specific shore resolver. The cliff face is rendered by the waterfall
# tile on the upper layer, so we strip the cliff direction from the mask and
# then resolve to a single EDGE_* tile pointing at the river bank. No corner
# tiles — the basin shows at most one shore edge.
static func _basin_kind_for_mask(mask: int, rise_dir: Vector2i) -> StringName:
	var face: int = mask & 0xF
	face &= ~_face_bit_for_dir(rise_dir)
	if face == 0:
		return TileSlots.WATER_FLAT
	if face == 1: return TileSlots.EDGE_NE
	if face == 2: return TileSlots.EDGE_NW
	if face == 4: return TileSlots.EDGE_SE
	if face == 8: return TileSlots.EDGE_SW
	# Both lateral sides are banks (1-wide drop with banks on NW+SE for
	# NE-rise, or NE+SW for NW-rise). Pick a single bank arbitrarily — either
	# is "toward the river edge" since both are land.
	if face & 2: return TileSlots.EDGE_NW
	if face & 4: return TileSlots.EDGE_SE
	if face & 8: return TileSlots.EDGE_SW
	if face & 1: return TileSlots.EDGE_NE
	return TileSlots.WATER_FLAT


static func _face_bit_for_dir(dir: Vector2i) -> int:
	if dir == TerrainGenerator.DIR_NE: return 1
	if dir == TerrainGenerator.DIR_NW: return 2
	if dir == TerrainGenerator.DIR_SE: return 4
	if dir == TerrainGenerator.DIR_SW: return 8
	return 0


# ----------------------------------------------------------------------------
# Underwater fill (dirt floor + back walls beneath water surfaces)
# ----------------------------------------------------------------------------

# Paints a dirt floor directly under a water-surface cell, plus dirt FULL_CUBE
# "back walls" at the NE and NW bank-neighbor coords on the same lower layer.
# SE/SW directions are intentionally skipped — those walls would sit between
# the camera and the water surface and would obstruct the view.
#
# When a bank's altitude exceeds the water altitude (e.g. bank at T+2 next to
# water at T after smoothing allows a one-tier rise), a single dirt cube at
# `water_alt - 2` would float below the bank with a visual gap. The wall loop
# stacks dirt cubes from `bank_alt - 2` down to `water_alt - 2` so the column
# reads as a single tall back wall flush with the bank above.
#
# Reused for both regular WATER cells (water_alt = c.altitude, mask =
# c.shore_mask) and waterfall basins (water_alt = c.altitude - 2, mask
# computed via `_basin_shore_mask`).
static func _paint_underwater_fill(
	grid: TerrainGrid,
	layers_by_altitude: Dictionary,
	indices: Dictionary,
	water_pos: Vector2i,
	water_alt: int,
	shore_mask: int,
) -> void:
	var floor_alt: int = water_alt - 2
	var floor_layer: TileMapLayer = layers_by_altitude.get(floor_alt, null)
	if floor_layer == null:
		return
	_set_dirt_cell(floor_layer, indices, water_pos, TileSlots.FLAT)

	var wall_dirs: Array[Vector2i] = [TerrainGenerator.DIR_NE, TerrainGenerator.DIR_NW]
	for d in wall_dirs:
		var bit: int = _face_bit_for_dir(d)
		if (shore_mask & bit) == 0:
			continue
		var bank_pos: Vector2i = water_pos + d
		var bank_cell: TerrainCell = grid.at_or_null(bank_pos.x, bank_pos.y)
		if bank_cell == null:
			continue
		var top: int = bank_cell.altitude - 2
		var cur: int = top
		while cur >= floor_alt:
			var l: TileMapLayer = layers_by_altitude.get(cur, null)
			if l != null:
				_set_dirt_cell(l, indices, bank_pos, TileSlots.FULL_CUBE)
			cur -= 2


# Thin helper that resolves the dirt source's atlas coord for `kind` and sets
# the cell. Warns once per missing kind rather than crashing — the dirt source
# is expected to have FLAT and FULL_CUBE painted, but an editor accident
# shouldn't take down generation.
static func _set_dirt_cell(
	layer: TileMapLayer,
	indices: Dictionary,
	pos: Vector2i,
	kind: StringName,
) -> void:
	var idx: TileKindIndex = indices[SOURCE_DIRT]
	if not idx.has(kind):
		push_warning(
			"TerrainPainter: tile_kind '%s' missing on dirt source — skipping underwater fill at %s."
			% [kind, pos]
		)
		return
	var coord: Vector2i = idx.coord(kind)
	layer.set_cell(pos, SOURCE_DIRT, coord, 0)


# ----------------------------------------------------------------------------
# Mappings
# ----------------------------------------------------------------------------

static func _source_for_biome(biome: int) -> int:
	match biome:
		TerrainCell.Biome.GRASS: return SOURCE_GRASS
		TerrainCell.Biome.DIRT:  return SOURCE_DIRT
		TerrainCell.Biome.ROCK:  return SOURCE_ROCK
		TerrainCell.Biome.SNOW:  return SOURCE_SNOW
	return SOURCE_GRASS


static func _ground_shape_to_kind(shape: int) -> StringName:
	match shape:
		TerrainCell.GroundShape.FULL_CUBE: return TileSlots.FULL_CUBE
		TerrainCell.GroundShape.FLAT:      return TileSlots.FLAT
		TerrainCell.GroundShape.SLOPE_NE:  return TileSlots.SLOPE_NE
		TerrainCell.GroundShape.SLOPE_NW:  return TileSlots.SLOPE_NW
		TerrainCell.GroundShape.SLOPE_SE:  return TileSlots.SLOPE_SE
		TerrainCell.GroundShape.SLOPE_SW:  return TileSlots.SLOPE_SW
	return TileSlots.FULL_CUBE


# Shore mask bit layout (from terrain_generator.gd):
#   bit 0 (1)   = NE face neighbor is land
#   bit 1 (2)   = NW face neighbor is land
#   bit 2 (4)   = SE face neighbor is land
#   bit 3 (8)   = SW face neighbor is land
#   bit 4 (16)  = N apex (diagonal) neighbor is land
#   bit 5 (32)  = E apex neighbor is land
#   bit 6 (64)  = S apex neighbor is land
#   bit 7 (128) = W apex neighbor is land
#
# Painted shore tiles:
#   EDGE_NE/NW/SE/SW    = single face shore
#   CORNER_N/E/S/W      = two adjacent face shores (convex water corner /
#                         concave land corner; water apex pokes into land)
#   INNER_N/E/S/W       = no face shores, but the named apex cell is land
#                         (concave water corner / convex land corner; a small
#                         notch of land pokes into the water from the apex)
static func _shore_kind_for_mask(mask: int) -> StringName:
	var face: int = mask & 0xF
	# Face shores dominate. When any face neighbor is land, the apex bits are
	# implied or ambiguous and we render the face/corner tile instead.
	match face:
		1:  return TileSlots.EDGE_NE
		2:  return TileSlots.EDGE_NW
		4:  return TileSlots.EDGE_SE
		8:  return TileSlots.EDGE_SW
		3:  return TileSlots.CORNER_N
		5:  return TileSlots.CORNER_E
		12: return TileSlots.CORNER_S
		10: return TileSlots.CORNER_W
	if face != 0:
		# Unsupported face combination (opposite-pair, 3-sided, fully enclosed).
		# Fall back to the lowest-bit single edge so something paints.
		if mask & 1: return TileSlots.EDGE_NE
		if mask & 2: return TileSlots.EDGE_NW
		if mask & 4: return TileSlots.EDGE_SE
		if mask & 8: return TileSlots.EDGE_SW
	# face == 0: open water on all four sides. Check apex bits for inner
	# (concave) corners. Multiple apex bits set is rare (would imply two
	# diagonal land cells but no face neighbors); fall through to flat water
	# in that case rather than picking arbitrarily.
	var apex: int = (mask >> 4) & 0xF
	match apex:
		1: return TileSlots.INNER_N
		2: return TileSlots.INNER_E
		4: return TileSlots.INNER_S
		8: return TileSlots.INNER_W
	return TileSlots.WATER_FLAT


# `rise_dir` is the direction of the cliff above the waterfall (i.e. -flow).
# The TOP/BOTTOM/BOTH/NONE suffix encodes position within a vertically
# stacked waterfall column: BOTH = single-tile drop (lip + splash), TOP =
# topmost of a multi-tile drop (lip only), BOTTOM = bottommost (splash only),
# NONE = middle tile (continuous water, no rock framing).
#
# The current generator only produces 1-tile drops — `_trace_rivers` places
# one waterfall per T->T-2 transition and `_smooth_altitude_jumps` caps any
# altitude jump at 2 half-steps — so every waterfall is BOTH. Multi-tier
# drops would need both a model change (storing stacked waterfalls per grid
# cell) and a painter change to inspect upstream/downstream neighbors.
static func _waterfall_kind_for_rise(rise_dir: Vector2i) -> StringName:
	if rise_dir == TerrainGenerator.DIR_NE:
		return TileSlots.FALL_NE_BOTH
	if rise_dir == TerrainGenerator.DIR_NW:
		return TileSlots.FALL_NW_BOTH
	# SE/SW rises are unpainted in the current water atlas — caller falls back.
	return &""


static func _water_alt_for_flow(flow: Vector2i) -> int:
	if flow == TerrainGenerator.DIR_NE:
		return _WATER_ALT_NE
	if flow == TerrainGenerator.DIR_NW:
		return _WATER_ALT_NW
	if flow == TerrainGenerator.DIR_SE:
		return _WATER_ALT_SE
	if flow == TerrainGenerator.DIR_SW:
		return _WATER_ALT_SW
	return _WATER_ALT_STILL
