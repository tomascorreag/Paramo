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


# Grass FULL_CUBE variant selection. Picker scores each painted variant against
# the cell's altitude and biome-derived "centrality" using two gaussians, plus
# a small floor so no variant ever vanishes (preserves randomness).
const _GRASS_FULL_CUBE_KIND: StringName = &"FULL_CUBE"
const _PA_LAYER: String = "preferred_altitude"
const _PD_LAYER: String = "preferred_density"
const _SIGMA_ALT: float = 2.0
const _SIGMA_DENS: float = 0.35
const _EPSILON: float = 0.05
# Mirrors _biome_for() in terrain_generator.gd: GRASS band ends at perturbed = 4.
const _GRASS_BAND_TOP: float = 4.0


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
	seed: int = 0,
) -> void:
	if tile_set == null:
		push_error("TerrainPainter.paint: tile_set is null.")
		return

	# Cache one TileKindIndex per source we'll touch.
	var indices: Dictionary[int, TileKindIndex] = {}
	for src in [SOURCE_GRASS, SOURCE_DIRT, SOURCE_WATER, SOURCE_SNOW, SOURCE_ROCK]:
		indices[src] = TileKindIndex.new(tile_set, src)

	var grass_variants: Array = _build_variant_table(
		indices[SOURCE_GRASS], _GRASS_FULL_CUBE_KIND
	)

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
			_paint_cell(grid, layers_by_altitude, indices, grass_variants, seed, x, y, c)


# ----------------------------------------------------------------------------
# Per-cell paint
# ----------------------------------------------------------------------------

static func _paint_cell(
	grid: TerrainGrid,
	layers_by_altitude: Dictionary,
	indices: Dictionary,
	grass_variants: Array,
	seed: int,
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
			_paint_ground(layer, indices, grass_variants, seed, pos, c)
			# A GROUND cell's cube only renders at one altitude. When a face
			# neighbor sits more than one cube below, the cliff face exposes
			# a void on the layers between this cell's altitude and the
			# neighbor's. Stack biome-matched FULL_CUBEs at this cell's coord
			# down to (lowest neighbor + 2) to fill that void.
			_paint_ground_cliff_back(grid, layers_by_altitude, indices, grass_variants, seed, pos, c)
		TerrainCell.Kind.WATER:
			_paint_water(layer, indices, pos, c)
			# Water shader is semi-transparent. Fill the volume directly under
			# the water surface with dirt (floor + back walls on NE/NW only)
			# so the basin reads visually instead of looking like void.
			_paint_underwater_fill(
				grid, layers_by_altitude, indices, pos, c.altitude, c.shore_mask
			)
		TerrainCell.Kind.WATERFALL:
			_paint_waterfall_column(layers_by_altitude, indices, pos, c)
			# Waterfall column covers the cliff's wall face on layers
			# [c.altitude - drop_height + 2 .. c.altitude]. The basin (the
			# floor of the drop) sits one tier below the bottommost fall tile,
			# i.e. at c.altitude - drop_height, and would render as void if
			# left unpainted.
			var basin_alt: int = c.altitude - c.drop_height
			var lower_layer: TileMapLayer = layers_by_altitude.get(basin_alt, null)
			if lower_layer != null:
				_paint_under_waterfall(grid, lower_layer, indices, pos, c)
				# Underwater fill UNDER the basin water (basin_alt - 2 floor +
				# NE/NW back walls). The wall stack already handles arbitrary
				# bank heights, so this works for any drop_height.
				var basin_mask: int = _basin_shore_mask(grid, pos, basin_alt)
				_paint_underwater_fill(
					grid, layers_by_altitude, indices, pos, basin_alt, basin_mask
				)
		_:
			pass


static func _paint_ground(
	layer: TileMapLayer,
	indices: Dictionary,
	grass_variants: Array,
	seed: int,
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
	if src == SOURCE_GRASS and kind == _GRASS_FULL_CUBE_KIND:
		var density: float = _grass_density_from_score(c.biome_score)
		coord = _pick_grass_variant_coord(
			grass_variants, c.altitude, density, pos.x, pos.y, c.altitude, seed, coord
		)
	layer.set_cell(pos, src, coord, 0)


# Stacks biome-matched FULL_CUBE tiles at `pos` from `c.altitude - 2` down to
# the highest layer above the lowest face neighbor. Without this, a 4-cube
# plateau next to a 0-cube basin would render as a single floating cube with
# 3 cubes of void below it on the cliff face. Mirrors the back-wall stacking
# done by `_paint_underwater_fill` for waterfall basins, but applies to bare
# GROUND cliffs (no adjacent water).
#
# For waterfall-adjacent plateaus, this paints first, then `_paint_underwater_fill`
# overpaints with dirt — same shape, harmless overwrite, dirt wins (matching the
# established underwater-fill convention for water-side back walls).
static func _paint_ground_cliff_back(
	grid: TerrainGrid,
	layers_by_altitude: Dictionary,
	indices: Dictionary,
	grass_variants: Array,
	seed: int,
	pos: Vector2i,
	c: TerrainCell,
) -> void:
	var min_alt: int = c.altitude
	for d in [
		DiamondCompass.DIR_NE,
		DiamondCompass.DIR_NW,
		DiamondCompass.DIR_SE,
		DiamondCompass.DIR_SW,
	]:
		var n: Vector2i = pos + d
		var nc: TerrainCell = grid.at_or_null(n.x, n.y)
		if nc == null:
			continue
		if nc.kind == TerrainCell.Kind.EMPTY:
			continue
		if nc.altitude < min_alt:
			min_alt = nc.altitude
	if min_alt >= c.altitude - 2:
		return
	var stop_alt: int = min_alt + 2
	# Resolve the source per stack tier so a tall cliff transitions through
	# biome bands (e.g. SNOW lip → ROCK → DIRT → GRASS at the basin), instead
	# of painting the entire column in the surface biome. This mirrors the
	# generator's altitude→biome mapping but without the per-cell noise
	# perturbation, which we don't have access to for cliff-back layers.
	var alt: int = c.altitude - 2
	while alt >= stop_alt:
		var layer: TileMapLayer = layers_by_altitude.get(alt, null)
		if layer != null:
			var tier_biome: int = _biome_for_altitude_band(alt)
			var src: int = _source_for_biome(tier_biome)
			var idx: TileKindIndex = indices[src]
			if not idx.has(TileSlots.FULL_CUBE):
				src = SOURCE_GRASS
				idx = indices[src]
			if idx.has(TileSlots.FULL_CUBE):
				var coord: Vector2i = idx.coord(TileSlots.FULL_CUBE)
				var stack_coord: Vector2i = coord
				if src == SOURCE_GRASS:
					var density: float = _grass_density_from_score(float(alt))
					stack_coord = _pick_grass_variant_coord(
						grass_variants, alt, density, pos.x, pos.y, alt, seed, coord
					)
				layer.set_cell(pos, src, stack_coord, 0)
		alt -= 2


# Mirrors `_biome_for` in terrain_generator.gd, sans noise. Used by
# cliff-back painting where we need a biome per altitude tier without a
# per-cell biome_score to read from. Bands: [0,4]=GRASS, (4,8]=DIRT,
# (8,12]=ROCK, (12,top]=SNOW.
static func _biome_for_altitude_band(alt: int) -> int:
	if alt <= 4:
		return TerrainCell.Biome.GRASS
	if alt <= 8:
		return TerrainCell.Biome.DIRT
	if alt <= 12:
		return TerrainCell.Biome.ROCK
	return TerrainCell.Biome.SNOW


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


static func _paint_waterfall_column(
	layers_by_altitude: Dictionary,
	indices: Dictionary,
	pos: Vector2i,
	c: TerrainCell,
) -> void:
	# Stacked waterfall: one tile per altitude tier from the lip down to the
	# bottommost fall tile. drop_height == 2 is a single-tile drop and uses
	# FALL_*_BOTH (lip + splash in one tile). Taller columns use TOP at the
	# lip, BOTTOM at the bottom, and NONE in between (continuous water, no
	# rock framing).
	var idx: TileKindIndex = indices[SOURCE_WATER]
	var rise: Vector2i = c.fall_rise_dir
	var top: int = c.altitude
	var bottom: int = c.altitude - c.drop_height + 2
	var flow: Vector2i = -rise
	var alt: int = top
	while alt >= bottom:
		var kind: StringName
		if c.drop_height == 2:
			kind = _fall_kind_for_rise_and_position(rise, &"BOTH")
		elif alt == top:
			kind = _fall_kind_for_rise_and_position(rise, &"TOP")
		elif alt == bottom:
			kind = _fall_kind_for_rise_and_position(rise, &"BOTTOM")
		else:
			kind = _fall_kind_for_rise_and_position(rise, &"NONE")
		var layer: TileMapLayer = layers_by_altitude.get(alt, null)
		if layer != null:
			_set_water_cell(layer, idx, pos, kind, flow)
		alt -= 2


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
	var basin_alt: int = c.altitude - c.drop_height
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
	var mask: int = 0
	for i in DiamondCompass.FACE_DIRS.size():
		var n: Vector2i = pos + DiamondCompass.FACE_DIRS[i]
		if not _basin_neighbor_is_basin_water(grid, n, basin_alt):
			mask |= DiamondCompass.FACE_BITS[i]
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
	# Multi-bit fallback: lateral banks on more than one side (1-wide drop
	# with banks on NW+SE for NE-rise, or NE+SW for NW-rise). Pick the first
	# bank by deterministic priority (NW > SE > SW > NE) so paints stay
	# stable seed-to-seed; either single bank reads as a shore edge.
	if face & 2: return TileSlots.EDGE_NW
	if face & 4: return TileSlots.EDGE_SE
	if face & 8: return TileSlots.EDGE_SW
	if face & 1: return TileSlots.EDGE_NE
	return TileSlots.WATER_FLAT


static func _face_bit_for_dir(dir: Vector2i) -> int:
	return DiamondCompass.face_bit_for_dir(dir)


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

	var wall_dirs: Array[Vector2i] = [DiamondCompass.DIR_NE, DiamondCompass.DIR_NW]
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
# Grass variant selection
# ----------------------------------------------------------------------------

# Builds [{coord, pa, pd}, …] from every painted variant of `kind` on `idx`.
# Reads preferred_altitude / preferred_density custom_data per variant; absent
# layers default to 0.0 (which still scores reasonably via the gaussian + floor).
static func _build_variant_table(idx: TileKindIndex, kind: StringName) -> Array:
	var out: Array = []
	if idx == null:
		return out
	for coord in idx.coords_for(kind):
		var pa_v: Variant = idx.get_attr(coord, _PA_LAYER)
		var pd_v: Variant = idx.get_attr(coord, _PD_LAYER)
		out.append({
			"coord": coord,
			"pa": float(pa_v) if pa_v != null else 0.0,
			"pd": float(pd_v) if pd_v != null else 0.0,
		})
	return out


# Maps the continuous biome score into a [0,1] "grass centrality":
#   1.0 = deep in grass region (low altitude, no noise push toward dirt)
#   0.0 = right at the grass/dirt threshold
# Mirrors the GRASS band cutoff used by _biome_for in terrain_generator.gd.
static func _grass_density_from_score(biome_score: float) -> float:
	return clampf((_GRASS_BAND_TOP - biome_score) / _GRASS_BAND_TOP, 0.0, 1.0)


# Weighted variant pick. Each variant scores against the cell via two gaussians
# (altitude in half-steps, density in [0,1]) plus EPSILON so even mismatched
# variants retain a nonzero chance — preserves randomness without making the
# preferences meaningless. Determinism via hash([x, y, layer_alt, seed]).
static func _pick_grass_variant_coord(
	variants: Array,
	altitude_half_steps: int,
	density: float,
	x: int, y: int, layer_alt: int, seed: int,
	fallback: Vector2i,
) -> Vector2i:
	if variants.is_empty():
		return fallback
	var weights: Array[float] = []
	var total: float = 0.0
	for v in variants:
		var ad: float = float(altitude_half_steps) - float(v["pa"])
		var dd: float = density - float(v["pd"])
		var w: float = exp(-(ad * ad) / (2.0 * _SIGMA_ALT * _SIGMA_ALT)) \
				* exp(-(dd * dd) / (2.0 * _SIGMA_DENS * _SIGMA_DENS)) \
				+ _EPSILON
		weights.append(w)
		total += w
	# hash() on a typed array is stable in Godot 4.6.
	var h: int = hash([x, y, layer_alt, seed]) & 0x7FFFFFFF
	var roll: float = (float(h) / float(0x7FFFFFFF)) * total
	var acc: float = 0.0
	for i in weights.size():
		acc += weights[i]
		if roll <= acc:
			return variants[i]["coord"]
	return variants.back()["coord"]


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
# Drop height is stored on the WATERFALL cell as `drop_height` (half-steps).
# `_paint_waterfall_column` walks layers between the lip and the bottom and
# resolves each layer's tile kind via this helper.
static func _fall_kind_for_rise_and_position(rise_dir: Vector2i, position: StringName) -> StringName:
	if rise_dir == DiamondCompass.DIR_NE:
		match position:
			&"BOTH":   return TileSlots.FALL_NE_BOTH
			&"TOP":    return TileSlots.FALL_NE_TOP
			&"BOTTOM": return TileSlots.FALL_NE_BOTTOM
			&"NONE":   return TileSlots.FALL_NE_NONE
	elif rise_dir == DiamondCompass.DIR_NW:
		match position:
			&"BOTH":   return TileSlots.FALL_NW_BOTH
			&"TOP":    return TileSlots.FALL_NW_TOP
			&"BOTTOM": return TileSlots.FALL_NW_BOTTOM
			&"NONE":   return TileSlots.FALL_NW_NONE
	# SE/SW rises are unpainted in the current water atlas — caller falls back.
	return &""


static func _water_alt_for_flow(flow: Vector2i) -> int:
	if flow == DiamondCompass.DIR_NE:
		return _WATER_ALT_NE
	if flow == DiamondCompass.DIR_NW:
		return _WATER_ALT_NW
	if flow == DiamondCompass.DIR_SE:
		return _WATER_ALT_SE
	if flow == DiamondCompass.DIR_SW:
		return _WATER_ALT_SW
	return _WATER_ALT_STILL
