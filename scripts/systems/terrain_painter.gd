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
const SOURCE_DIRT: int = 2
const SOURCE_WATER: int = 3
const SOURCE_SNOW: int = 4
const SOURCE_ROCK: int = 5

# Custom-data layer name carrying per-tile walkability. Read at runtime by
# `_resolve_rock_block_tile` so the south-cliff skirt always paints whatever
# (coord, alternative) the artist marked walkable=false on the rock source —
# no hardcoded coord or alt id.
const _WALKABLE_LAYER: String = "walkable"
const _TILE_KIND_LAYER: String = "tile_kind"


# Variant selection. Any kind on any ground biome source (grass / dirt / rock /
# snow) with 2+ painted variants is randomized via `_pick_variant_coord`. Today
# only grass FULL_CUBE has multiple variants, but the picker is wired uniformly
# across every biome — paint a 2nd variant on any source and randomization
# kicks in with no code change. Single-variant kinds bypass the picker.
const _PA_LAYER: String = "preferred_altitude"
const _PD_LAYER: String = "preferred_density"
const _SW_LAYER: String = "selection_weight"
const _SIGMA_ALT: float = 3.0
# Floor on per-variant weight. Tiny — purely a divide-by-zero / fully-zero
# safety net for the cumulative-weight roll. Per-variant variation comes from
# `selection_weight` (multiplier) and per-biome `noise_strength` (lerp on the
# roll); a larger floor here would re-introduce visible noise at high mismatch
# (the old 0.05 value made variants with sw>1 appear ~5–10% at altitudes far
# from their pa, defeating the gaussian).
const _EPSILON: float = 1e-6
# Clumping multiplier on the neighbor-density pull. Each already-painted face
# neighbor contributes its variant's pd to `pull` (range [0, 4]). The variant's
# clumping factor is `1 + _CLUMP_GAIN * pull * v.pd`. With gain=1, a pd=1
# variant fully surrounded by pd=1 neighbors gets a 5x score boost relative to
# a pd=0 candidate at the same cell. Tunable; per-biome exposure can come
# later if needed.
const _CLUMP_GAIN: float = 1.0


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
#
# `params` is required: the painter resolves biome-band thresholds and the
# grass-band top from it (used by cliff-back biome stacking and the grass
# variant density picker), and reads the rng seed for deterministic variant
# selection.
static func paint(
	grid: TerrainGrid,
	layers_by_altitude: Dictionary,
	tile_set: TileSet,
	params: TerrainGenerationParams,
) -> void:
	if tile_set == null:
		push_error("TerrainPainter.paint: tile_set is null.")
		return
	if params == null:
		push_error("TerrainPainter.paint: params is null.")
		return

	# Cache one TileKindIndex per source we'll touch.
	var indices: Dictionary[int, TileKindIndex] = {}
	for src in [SOURCE_GRASS, SOURCE_DIRT, SOURCE_WATER, SOURCE_SNOW, SOURCE_ROCK]:
		indices[src] = TileKindIndex.new(tile_set, src)

	# Per-source variant tables keyed by tile_kind. Built once for every ground
	# biome source we paint; water is excluded — its tile selection is fully
	# driven by shore_mask/flow and randomization would break flow-coherent art.
	# Inner dicts only contain kinds with 2+ painted variants; everything else
	# short-circuits to the fallback coord in `_resolve_variant_coord`. Adding
	# a 2nd dirt/rock/snow variant is a pure-data change — no code edits needed.
	var variants_by_source: Dictionary[int, Dictionary] = {}
	for src in [SOURCE_GRASS, SOURCE_DIRT, SOURCE_ROCK, SOURCE_SNOW]:
		variants_by_source[src] = _build_variants_by_kind(indices[src])

	# Resolve once and thread through. Pure function of params — stable across
	# the whole paint pass and cheap (single linear walk over biome_bands).
	var thresholds: Array = params.resolve_biome_thresholds()
	var seed: int = params.seed
	# Per-biome variant-selection noise. Keyed by TerrainCell.Biome int. Bands
	# with noise_strength == 0 are omitted so the picker takes the legacy
	# uniform-hash path with zero overhead. Last band wins on duplicate biome
	# (designer can have multiple GRASS bands; the topmost-listed one's noise
	# settings apply).
	var biome_noise: Dictionary[int, Dictionary] = _build_biome_noise(params)
	# Per-biome record of painted-variant pd. Keyed by TerrainCell.Biome int →
	# {pos → pd}. Each biome clumps independently — a rock cell's pd doesn't
	# pull a grass neighbor, since pd is a per-source affinity (different
	# atlases have unrelated affinity scales). Cliff-back tiers still pass an
	# empty per-tier scratch dict; vertical stacks don't bias horizontal
	# clumping in any biome. Iteration is y outer, x inner — deterministic, so
	# paint output stays stable per seed.
	var painted_pd_by_biome: Dictionary[int, Dictionary] = {}

	# Tracks which altitudes we've already warned about during this paint pass
	# to keep `_paint_cell` from spamming stderr once per cell when a generation
	# run produces cells outside the layer ceiling. ProceduralWorld already
	# validates `top_altitude` up front, so this is a defense-in-depth limiter.
	var warned_altitudes: Dictionary = {}

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
			_paint_cell(
				grid, layers_by_altitude, indices, variants_by_source,
				thresholds, seed, biome_noise, painted_pd_by_biome,
				warned_altitudes, x, y, c,
			)

	# After the playable grid is fully painted, drop the south-edge cliff
	# skirt. The skirt lives at synthetic coordinates beyond the grid (y >=
	# grid.height for the SW edge, x >= grid.width for the SE edge) and
	# paints into whichever altitudes the caller registered with
	# `layers_by_altitude`. Pathfinder-bound layers MUST NOT be in that dict
	# (or the cliff cubes would pollute the walkability grid). The default
	# wiring in procedural_base.tscn provides dedicated CliffN<N> layers at
	# negative altitudes only.
	_paint_south_cliff_skirt(grid, layers_by_altitude, tile_set, params)


# ----------------------------------------------------------------------------
# Per-cell paint
# ----------------------------------------------------------------------------

static func _paint_cell(
	grid: TerrainGrid,
	layers_by_altitude: Dictionary,
	indices: Dictionary,
	variants_by_source: Dictionary,
	thresholds: Array,
	seed: int,
	biome_noise: Dictionary,
	painted_pd_by_biome: Dictionary,
	warned_altitudes: Dictionary,
	x: int,
	y: int,
	c: TerrainCell,
) -> void:
	var layer: TileMapLayer = layers_by_altitude.get(c.altitude, null)
	if layer == null:
		# One warning per missing altitude per paint pass — without this guard
		# a misconfigured layer stack floods stderr with thousands of identical
		# messages (one per cell at that altitude).
		if not warned_altitudes.has(c.altitude):
			warned_altitudes[c.altitude] = true
			push_warning(
				"TerrainPainter: no layer registered for altitude %d (first cell %d,%d) — skipping further cells at this altitude."
				% [c.altitude, x, y]
			)
		return

	var pos := Vector2i(x, y)

	match c.kind:
		TerrainCell.Kind.GROUND:
			_paint_ground(
				layer, indices, variants_by_source, seed, biome_noise,
				painted_pd_by_biome, pos, c,
			)
			# A GROUND cell's cube only renders at one altitude. When a face
			# neighbor sits more than one cube below, the cliff face exposes
			# a void on the layers between this cell's altitude and the
			# neighbor's. Stack biome-matched FULL_CUBEs at this cell's coord
			# down to (lowest neighbor + 2) to fill that void.
			_paint_ground_cliff_back(
				grid, layers_by_altitude, indices, variants_by_source,
				thresholds, seed, biome_noise, pos, c,
			)
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
			#
			# `void_basin` (set by the south-cliff exit converter) opts out:
			# the river falls into the painted rock skirt past the south
			# boundary, where no real basin exists. Painting a basin pool +
			# dirt floor + back walls there would float water tiles in front
			# of the cliff face. Skip both helpers entirely.
			if not c.void_basin:
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
	variants_by_source: Dictionary,
	seed: int,
	biome_noise: Dictionary,
	painted_pd_by_biome: Dictionary,
	pos: Vector2i,
	c: TerrainCell,
) -> void:
	var primary_src: int = _source_for_biome(c.biome)
	var kind: StringName = _ground_shape_to_kind(c.ground_shape)
	var src: int = primary_src
	var idx: TileKindIndex = indices[src]
	# Fallback chain when the biome's source doesn't paint this kind:
	#   1. Stay on the biome's source but substitute FULL_CUBE — preserves
	#      biome look at the cost of slope geometry (a SLOPE_SE on rock
	#      becomes a rock cube; the cliff reads as a step instead of a ramp,
	#      but no grass leaks into rocky terrain).
	#   2. If the biome's source has no FULL_CUBE either, fall through to the
	#      grass source for the original kind — geometry-correct but biome-
	#      incorrect. This is a true degenerate case and a sign the biome's
	#      atlas is incomplete (every painted source SHOULD have FULL_CUBE).
	if not idx.has(kind):
		if idx.has(TileSlots.FULL_CUBE):
			kind = TileSlots.FULL_CUBE
		else:
			src = SOURCE_GRASS
			idx = indices[src]
	if not idx.has(kind):
		push_warning(
			"TerrainPainter: tile_kind '%s' missing on source %d AND grass fallback — skipping cell %s."
			% [kind, primary_src, pos]
		)
		return
	var coord: Vector2i = idx.coord(kind)
	# Variant resolution runs for every biome. When the source has <2 painted
	# variants of `kind`, the resolver returns `coord` unchanged (cheap no-op).
	# Clumping pull is per-biome — `painted_pd_by_biome` is keyed by biome int
	# so a rock cell's pd doesn't influence a neighboring grass cell and vice
	# versa.
	var pd_for_biome: Dictionary = painted_pd_by_biome.get_or_add(c.biome, {})
	coord = _resolve_variant_coord(
		variants_by_source.get(src, {}), kind, coord,
		c.altitude, pos, c.altitude, seed, c.biome,
		biome_noise, pd_for_biome,
	)
	layer.set_cell(pos, src, coord, 0)


# ----------------------------------------------------------------------------
# South cliff skirt
# ----------------------------------------------------------------------------

# Paints a paint-only rock cliff at the disc-carved south silhouette. For
# every non-EMPTY cell whose SW or SE face neighbor is EMPTY (or off-grid),
# the painter emits two passes:
#
#   1. Vertical cliff face DOWN at the lip cell's own coord, stacking rock
#      FULL_CUBEs at altitudes [c.altitude - 2 .. cliff_floor]. This sits on
#      the same (x, y) as the playable lip cell and writes into in-grid
#      coordinates of layers in `layers_by_altitude`. Walkability stays
#      correct: positive-altitude paints overwrite cliff_back's biome-tier
#      cubes with rock at an existing in-grid coord (no new positions added,
#      the lip's own walkable cube above is unaffected); negative-altitude
#      paints land in cliff layers, which ProceduralWorld keeps out of
#      Pathfinder/LayerConfigurator wirings.
#
#   2. Skirt extending in the carved direction (DIR_SW or DIR_SE) into the
#      EMPTY area beyond the silhouette. Each skirt cell stacks rock cubes
#      from its top altitude down to cliff_floor — both positive and
#      negative altitudes. Pathfinder pollution from synth-coord paints
#      into positive Ground layers is prevented at the TileGrid level:
#      ProceduralWorld sets `pathfinder.bounds_clip = Rect2i(0, 0, w, h)`
#      so cells outside the playable disc stay out of the walkability graph
#      regardless of how far Ground layers' used_rects extend. Per-row
#      cumulative drop + FastNoiseLite jitter shape the descent; rows
#      further from the lip drop less per step (when bottom < top),
#      producing a tapered ramp.
#
# Why iterate the disc-carved silhouette instead of literal grid edges:
# procedural maps almost never reach the literal y=height-1 / x=width-1 rows
# — the disc carves them away. The visual "south edge" of the playable area
# is the silhouette boundary inside the grid. Anchoring there (and emitting
# skirts INTO the EMPTY interior coords beyond) is what actually paints
# cliffs the player sees.
#
# Walkability invariant: non-walkability of the cliff is achieved structurally
# (cliff layers absent from Pathfinder/LayerConfigurator wirings), not via
# per-tile walkable=false. The rock FULL_CUBE atlas entry stays walkable
# everywhere it's used in the playable region.
static func _paint_south_cliff_skirt(
	grid: TerrainGrid,
	layers_by_altitude: Dictionary,
	tile_set: TileSet,
	params: TerrainGenerationParams,
) -> void:
	if params.cliff_depth_steps <= 0 or params.cliff_skirt_rows <= 0:
		return
	# Resolve every (atlas_coord, alternative) on the rock source whose
	# walkable=false AND tile_kind=FULL_CUBE. Per-cube selection then picks
	# from this list deterministically (hash by position+altitude+seed) so
	# adding a 2nd/3rd non-walkable variant in the atlas automatically gives
	# the cliff visual variety with no code change. Today there's typically
	# one entry, in which case selection collapses to that single tile.
	var blocks: Array = _resolve_rock_block_tiles(tile_set)
	if blocks.is_empty():
		push_warning(
			"TerrainPainter: no rock FULL_CUBE with walkable=false found in tile_set — "
			+ "skipping south cliff skirt. Mark a rock-source FULL_CUBE tile non-walkable."
		)
		return

	var noise := FastNoiseLite.new()
	# Decorrelated stream — different patterns per seed without lock-stepping
	# any other generator/painter noise field.
	noise.seed = params.seed ^ 0x5C111F1F
	noise.frequency = params.cliff_noise_frequency
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH

	var cliff_floor: int = -2 * params.cliff_depth_steps
	var rows: int = params.cliff_skirt_rows

	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind == TerrainCell.Kind.EMPTY:
				continue
			# A cell can have its SW carved, its SE carved, or both (south
			# corner of the disc). Treat each independently — both directions
			# get their own skirt ray + lip face fill at the same lip coord
			# (the lip-face fill is idempotent rock cubes; double-writing is
			# harmless).
			for d in [DiamondCompass.DIR_SW, DiamondCompass.DIR_SE]:
				if not _is_carved_neighbor(grid, x, y, d):
					continue
				_stack_rock_at_coord(
					layers_by_altitude, blocks, params.seed,
					Vector2i(x, y), c.altitude - 2, cliff_floor,
				)
				_paint_skirt_ray(
					layers_by_altitude, blocks, params.seed, noise, params,
					Vector2i(x, y), d, c.altitude, cliff_floor, rows,
				)


# Scans the rock source for every (atlas_coord, alternative) pair whose
# `walkable` custom_data is false AND whose `tile_kind` is FULL_CUBE. Returns
# an Array of {"coord": Vector2i, "alt": int} entries, in atlas scan order.
# Empty when the artist hasn't marked any rock cube non-walkable.
#
# Why scan: the painter previously assumed the non-walkable variant lived at
# `coord(FULL_CUBE)` with alt id 1. `TileKindIndex.coord(FULL_CUBE)` returns
# the first FULL_CUBE coord in atlas scan order, which is not necessarily
# (0,0). When it returned a different coord (0:2, 1:4, 1:6 — all walkable
# variants with no alt 1), the painter wrote a non-existent (coord, alt) pair
# and the editor rendered `!` placeholders.
#
# FULL_CUBE filter: keeps a designer from accidentally steering the cliff
# onto a non-walkable slope/wall and producing geometry-incoherent stacks.
# If the tile_kind layer is missing entirely, we fall back to "any
# non-walkable rock tile" rather than refusing.
static func _resolve_rock_block_tiles(tile_set: TileSet) -> Array:
	var out: Array = []
	var src: TileSetAtlasSource = tile_set.get_source(SOURCE_ROCK) as TileSetAtlasSource
	if src == null:
		return out
	var walk_layer_id: int = -1
	var kind_layer_id: int = -1
	for i in tile_set.get_custom_data_layers_count():
		match tile_set.get_custom_data_layer_name(i):
			_WALKABLE_LAYER: walk_layer_id = i
			_TILE_KIND_LAYER: kind_layer_id = i
	if walk_layer_id < 0:
		return out
	for i in src.get_tiles_count():
		var coord: Vector2i = src.get_tile_id(i)
		for j in src.get_alternative_tiles_count(coord):
			var alt: int = src.get_alternative_tile_id(coord, j)
			var data: TileData = src.get_tile_data(coord, alt)
			if data == null:
				continue
			var w: Variant = data.get_custom_data_by_layer_id(walk_layer_id)
			if not (w is bool) or w:
				continue
			if kind_layer_id >= 0:
				var k: Variant = data.get_custom_data_by_layer_id(kind_layer_id)
				if k != "FULL_CUBE":
					continue
			out.append({"coord": coord, "alt": alt})
	return out


# Picks one of the discovered non-walkable rock variants by hashing the
# painted cell's (x, y, altitude, seed). Deterministic per (seed, position),
# so the same map always renders the same way — and a stable seed reproduces
# the exact cliff art across runs. Single-entry input (today's case) collapses
# to a no-op.
static func _pick_rock_block(blocks: Array, pos: Vector2i, alt: int, seed: int) -> Dictionary:
	if blocks.size() == 1:
		return blocks[0]
	var h: int = hash([pos.x, pos.y, alt, seed, 0x52434B5F]) & 0x7FFFFFFF
	return blocks[h % blocks.size()]


# True iff the face neighbor at `(x, y) + d` is off-grid OR EMPTY (i.e., the
# disc was carved on that side). The painter uses this to find south-facing
# silhouette cells regardless of where the disc sits in the grid.
static func _is_carved_neighbor(grid: TerrainGrid, x: int, y: int, d: Vector2i) -> bool:
	var n: TerrainCell = grid.at_or_null(x + d.x, y + d.y)
	return n == null or n.kind == TerrainCell.Kind.EMPTY


# Stacks rock FULL_CUBEs at `pos` from `top_alt` down to `floor_alt` (inclusive
# of both ends), stepping by -2. Each cube independently picks one of the
# non-walkable rock variants in `blocks` (deterministic hash on pos+alt+seed),
# so a 2-row vertical stack with two variants in the atlas naturally shows
# two different rock textures. With a single variant in the atlas (today's
# case) every cube collapses to that same tile. Cubes never enter the
# walkability graph because every block in `blocks` has walkable=false; the
# lip's TOP cube is still painted by the regular ground pass on the layer
# above and stays walkable via "tallest wins" merge. Altitudes whose layer
# is absent from `layers_by_altitude` are silently skipped.
static func _stack_rock_at_coord(
	layers_by_altitude: Dictionary,
	blocks: Array,
	seed: int,
	pos: Vector2i,
	top_alt: int,
	floor_alt: int,
) -> void:
	var alt: int = top_alt
	while alt >= floor_alt:
		var layer: TileMapLayer = layers_by_altitude.get(alt, null)
		if layer != null:
			var pick: Dictionary = _pick_rock_block(blocks, pos, alt, seed)
			layer.set_cell(pos, SOURCE_ROCK, pick["coord"], pick["alt"])
		alt -= 2


# Skirt ray extends in `direction` for `rows` steps. Per-row cumulative drop is
# linearly interpolated from `cliff_drop_per_row_top` (near the lip) to
# `cliff_drop_per_row_bottom` (far edge); per-cell altitude jittered by noise.
# Each skirt cell stacks rock FULL_CUBEs from its top altitude down to
# `cliff_floor`, painting at both positive and negative altitudes — the
# Pathfinder bounds_clip set by ProceduralWorld keeps the synth coords out
# of the walkability graph despite landing in Ground layers' used_rects.
static func _paint_skirt_ray(
	layers_by_altitude: Dictionary,
	blocks: Array,
	seed: int,
	noise: FastNoiseLite,
	params: TerrainGenerationParams,
	anchor_pos: Vector2i,
	direction: Vector2i,
	edge_alt: int,
	cliff_floor: int,
	rows: int,
) -> void:
	var top: float = float(params.cliff_drop_per_row_top)
	var bottom: float = float(params.cliff_drop_per_row_bottom)
	var cumulative: float = 0.0
	for step in range(1, rows + 1):
		var t: float = 0.0
		if rows > 1:
			t = float(step - 1) / float(rows - 1)
		cumulative += lerpf(top, bottom, t)
		var synth_pos: Vector2i = anchor_pos + direction * step
		var noise_sample: float = noise.get_noise_2d(float(synth_pos.x), float(synth_pos.y))
		var jitter: float = noise_sample * params.cliff_noise_amplitude
		var cell_top_f: float = float(edge_alt) - cumulative + jitter
		var cell_top: int = _snap_even_int(cell_top_f)
		# Cap top strictly below the lip altitude (otherwise the skirt cell
		# would visually rise above the playable lip and break the silhouette)
		# and at-or-above the floor (cubes below cliff_floor have no layer).
		var hi: int = edge_alt - 2
		if cell_top > hi:
			cell_top = hi
		if cell_top < cliff_floor:
			cell_top = cliff_floor
		_stack_rock_at_coord(
			layers_by_altitude, blocks, seed,
			synth_pos, cell_top, cliff_floor,
		)


# Rounds `f` to the nearest even integer (half-step quantization). The
# generator uses the same convention; matching it here keeps cliff altitudes
# consistent with grid altitudes for any future system that compares them.
static func _snap_even_int(f: float) -> int:
	var r: int = int(roundf(f))
	if (r & 1) != 0:
		# Round half-toward-zero on ties. Direction doesn't matter for noise
		# jitter — picking a consistent rule just keeps output reproducible.
		if f >= 0.0:
			r -= 1
		else:
			r += 1
	return r


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
	variants_by_source: Dictionary,
	thresholds: Array,
	seed: int,
	biome_noise: Dictionary,
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
			var tier_biome: int = _biome_for_altitude_band(alt, thresholds)
			# Snow only paints at the surface tier — any cliff-back tier that
			# would otherwise resolve to snow is demoted to rock so the column
			# under a snow cap reads as rocky peak with a thin snow layer on
			# top, not a solid block of snow. Surface paint (`_paint_ground`)
			# is unaffected; this loop only runs strictly below the surface.
			if tier_biome == TerrainCell.Biome.SNOW:
				tier_biome = TerrainCell.Biome.ROCK
			var src: int = _source_for_biome(tier_biome)
			var idx: TileKindIndex = indices[src]
			if not idx.has(TileSlots.FULL_CUBE):
				src = SOURCE_GRASS
				idx = indices[src]
			if idx.has(TileSlots.FULL_CUBE):
				var coord: Vector2i = idx.coord(TileSlots.FULL_CUBE)
				# Cliff-back tiers paint vertical stacks at the same (x,y); they
				# have no horizontal neighbor relationships worth clumping over.
				# Each tier passes a fresh empty pd dict so the picker takes the
				# pull=0 fast path and the column doesn't pollute surface
				# clumping in any biome.
				var no_pd: Dictionary = {}
				var stack_coord: Vector2i = _resolve_variant_coord(
					variants_by_source.get(src, {}), TileSlots.FULL_CUBE, coord,
					alt, pos, alt, seed, tier_biome,
					biome_noise, no_pd,
				)
				layer.set_cell(pos, src, stack_coord, 0)
		alt -= 2


# Resolves the biome for a cliff-back tier from the band thresholds (no
# noise — cliff-back paint doesn't have access to the generator's biome
# noise field, so band boundaries on cliff faces are sharp horizontal lines
# even when surface tiles next to them are biome-jittered. Designer can
# lower biome_noise_amplitude to minimize visible mismatch at cliff lips,
# or accept the seam as a stylistic break between surface and cliff).
static func _biome_for_altitude_band(alt: int, thresholds: Array) -> int:
	var a: float = float(alt)
	for entry in thresholds:
		if a < entry[0]:
			return entry[1]
	return thresholds.back()[1]


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
	# Stacked waterfall: one tile per altitude tier from the highest lip down
	# to the basin+2 row.
	#
	# Single-face fall (fall_rise_dir_b == ZERO):
	#   - drop_height == 2  → FALL_*_BOTH single tile (lip + splash)
	#   - drop_height >= 4  → FALL_*_TOP at the lip, FALL_*_BOTTOM at basin+2,
	#                         FALL_*_NONE for any tier in between
	#
	# Corner fall (fall_rise_dir_b != ZERO):
	#   - Tiers where BOTH faces have water → single FALL_NENW tile
	#   - Tiers above the shorter face's lip (asymmetric drops) → solo face
	#     uses the existing FALL_*_TOP/NONE family for the taller column
	#   - Both faces share the basin at altitude - drop_height; lip_b is
	#     basin + drop_height_b (may differ from altitude / lip_a)
	var idx: TileKindIndex = indices[SOURCE_WATER]
	var rise_a: Vector2i = c.fall_rise_dir
	var rise_b: Vector2i = c.fall_rise_dir_b
	var has_b: bool = rise_b != Vector2i.ZERO
	var basin: int = c.altitude - c.drop_height
	var lip_a: int = c.altitude
	var lip_b: int = basin + c.drop_height_b
	var bottom: int = basin + 2
	var top: int = maxi(lip_a, lip_b) if has_b else lip_a
	var alt: int = top
	while alt >= bottom:
		var a_active: bool = alt <= lip_a
		var b_active: bool = has_b and alt <= lip_b
		var kind: StringName = &""
		var flow: Vector2i = - rise_a
		if a_active and b_active:
			kind = TileSlots.FALL_NENW
		elif a_active:
			kind = _fall_kind_for_rise_and_position(
				rise_a, _fall_position_for(alt, lip_a, basin, c.drop_height)
			)
		elif b_active:
			kind = _fall_kind_for_rise_and_position(
				rise_b, _fall_position_for(alt, lip_b, basin, c.drop_height_b)
			)
			flow = - rise_b
		var layer: TileMapLayer = layers_by_altitude.get(alt, null)
		if layer != null:
			_set_water_cell(layer, idx, pos, kind, flow)
		alt -= 2


# Resolves the TOP/BOTTOM/BOTH/NONE position suffix for one face of a
# waterfall column. `lip` and `drop` describe THAT face's column; `basin` is
# shared. drop == 2 collapses to BOTH (single-tile fall). For taller columns,
# lip → TOP, basin+2 → BOTTOM, anything between → NONE.
static func _fall_position_for(alt: int, lip: int, basin: int, drop: int) -> StringName:
	if drop == 2:
		return &"BOTH"
	if alt == lip:
		return &"TOP"
	if alt == basin + 2:
		return &"BOTTOM"
	return &"NONE"


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
	var kind: StringName = _basin_kind_for_mask(mask, c.fall_rise_dir, c.fall_rise_dir_b)
	# Basin flow follows the primary face (the secondary face's walker
	# terminates on corner upgrade, so primary's continuation owns the basin).
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
# tiles — the basin shows at most one shore edge. For corner falls (two
# perpendicular cliff faces), strip both rise directions.
static func _basin_kind_for_mask(
	mask: int,
	rise_dir: Vector2i,
	rise_dir_b: Vector2i = Vector2i.ZERO,
) -> StringName:
	var face: int = mask & 0xF
	face &= ~_face_bit_for_dir(rise_dir)
	if rise_dir_b != Vector2i.ZERO:
		face &= ~_face_bit_for_dir(rise_dir_b)
	if face == 0:
		return TileSlots.WATER_FLAT
	if face == 1: return TileSlots.EDGE_NE
	if face == 2: return TileSlots.EDGE_NW
	if face == 4: return TileSlots.EDGE_SE
	if face == 8: return TileSlots.EDGE_SW
	# 1-wide drop: lateral banks on opposite face neighbors. After stripping
	# the cliff face(s), banks land on NW+SE for an NE-rise or NE+SW for an
	# NW-rise — exactly the two channel tiles. Basin flow is -fall_rise_dir
	# (SW for NE-rise, SE for NW-rise), matching the channel art's drawn flow.
	if face == 6: return TileSlots.EDGE_NW_SE # banks NW+SE, channel NE-SW
	if face == 9: return TileSlots.EDGE_NE_SW # banks NE+SW, channel NW-SE
	# Remaining multi-bit cases (3-sided, adjacent pair after partial strip).
	# Pick the first bank by deterministic priority so paints stay stable.
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
# Variant selection
# ----------------------------------------------------------------------------

# Picks the atlas coord for a tile of `kind` on whichever biome source the
# caller has resolved. Looks `kind` up in `variants_by_kind` (the inner dict for
# this source — only kinds with 2+ painted variants appear there); single-
# variant kinds short-circuit to `fallback`. Routes multi-variant picks through
# `_pick_variant_coord` so altitude / clumping / per-biome noise apply uniformly
# across every biome (grass FULL_CUBE today; any biome's slopes, half-slopes,
# stairs as soon as a 2nd variant is authored on that source).
#
# Surface callers pass the live per-biome `painted_pd` dict so the chosen
# variant's pd is recorded for future same-biome neighbors' clumping pull.
# Cliff-back callers pass a fresh empty dict — vertical stacks shouldn't
# influence horizontal clumping in any biome.
static func _resolve_variant_coord(
	variants_by_kind: Dictionary,
	kind: StringName,
	fallback: Vector2i,
	altitude_half_steps: int,
	pos: Vector2i,
	layer_alt: int,
	seed: int,
	biome: int,
	biome_noise: Dictionary,
	painted_pd: Dictionary,
) -> Vector2i:
	var variants: Array = variants_by_kind.get(kind, [])
	if variants.size() < 2:
		return fallback
	var nb: Dictionary = biome_noise.get(biome, {})
	var picked_out: Dictionary = {}
	var coord: Vector2i = _pick_variant_coord(
		variants, altitude_half_steps, pos.x, pos.y, layer_alt, seed, fallback,
		nb, painted_pd, picked_out,
	)
	# Record the chosen pd so future cells can clump against this one. For
	# cliff-back callers `painted_pd` is a fresh per-tier scratch dict (the
	# write is harmless — discarded at end of loop iteration), so no extra
	# "is_surface" flag is needed here.
	painted_pd[pos] = picked_out.get("pd", 0.0)
	return coord


# Builds the per-kind variant table for a single source. Each entry maps a
# tile_kind that has 2+ painted variants to its `_build_variant_table` array.
# Single-variant kinds are omitted (the picker would reduce to fallback).
# Called once per ground biome source in `paint()`; the source-agnostic
# resolver looks up the right inner dict by source id.
static func _build_variants_by_kind(idx: TileKindIndex) -> Dictionary[StringName, Array]:
	var out: Dictionary[StringName, Array] = {}
	if idx == null:
		return out
	for kind in idx.all_painted_names():
		var table: Array = _build_variant_table(idx, kind)
		if table.size() >= 2:
			out[kind] = table
	return out


# Builds [{coord, pa, pd, sw}, …] from every painted variant of `kind` on `idx`.
# Reads preferred_altitude / preferred_density / selection_weight custom_data per
# variant; absent layers default to 0.0 (which the picker treats as "skip this
# term" — see field semantics below).
#
# Field semantics (interpreted by `_pick_variant_coord`):
#   ANY ATTRIBUTE <= 0 IS IGNORED for that variant — its term is dropped from
#   the score (treated as multiplicative identity 1.0). This applies uniformly
#   to all three attributes; the inspector default of 0.0 thus means "no
#   preference along this axis" and a designer never has to author a sentinel
#   value to opt out.
#
#   - pa (preferred_altitude, half-steps): when > 0, gaussian center on the
#     cell's altitude axis (closer to pa → higher weight). When <= 0, altitude
#     is ignored and the variant is equally available at any altitude.
#   - pd (preferred_density, [0, 1] when used): clumping affinity. When > 0,
#     painted neighbors with pd>0 contribute their pd to a `pull` sum; the
#     candidate's score is multiplied by `1 + _CLUMP_GAIN * pull * pd`.
#     When <= 0, the candidate gets no clumping factor AND when painted as a
#     neighbor it doesn't contribute to other cells' pull.
#   - sw (selection_weight): per-variant frequency multiplier. When > 0, used
#     as-is. When == 0, dropped from the score (treated as 1.0). When < 0, the
#     variant is excluded entirely — never sampled, regardless of other terms.
static func _build_variant_table(idx: TileKindIndex, kind: StringName) -> Array:
	var out: Array = []
	if idx == null:
		return out
	for coord in idx.coords_for(kind):
		var pa_v: Variant = idx.get_attr(coord, _PA_LAYER)
		var pd_v: Variant = idx.get_attr(coord, _PD_LAYER)
		var sw_v: Variant = idx.get_attr(coord, _SW_LAYER)
		# Store raw values; the picker is responsible for the "<=0 → ignore"
		# logic so the rule is in one place and consistent across attributes.
		out.append({
			"coord": coord,
			"pa": float(pa_v) if pa_v != null else 0.0,
			"pd": float(pd_v) if pd_v != null else 0.0,
			"sw": float(sw_v) if sw_v != null else 0.0,
		})
	return out


# Weighted variant pick.
#
# Per-variant score builds multiplicatively from three optional terms; each
# term is dropped (treated as 1.0) when its source attribute is <= 0:
#
#   w = pa_term * sw_term * clump_term + EPSILON
#
#   pa_term    = exp(-(cell_alt - v.pa)^2 / (2σ^2))   if v.pa > 0, else 1.0
#   sw_term    = v.sw                                  if v.sw > 0, else 1.0
#   clump_term = 1 + _CLUMP_GAIN * pull * v.pd         if v.pd > 0, else 1.0
#
# Variants with v.sw < 0 are excluded from the candidate set up front and
# never contribute weight, so they cannot be sampled.
#
# `pull` is the sum of pd values across the cell's already-painted face
# neighbors, with neighbors whose pd <= 0 excluded. Range [0, 4]. Empty
# `painted_pd` (cliff-back tier) → pull = 0 → clump_term = 1 regardless.
#
# Roll is hash([x, y, layer_alt, seed]) → uniform [0, 1]. When the cell's
# biome supplies a noise field (`nb` = {noise, strength}), the roll is
# `lerp(hash, noise_sample, strength)` — strength=0 keeps uniform, strength=1
# is fully spatially coherent (large same-variant patches at noise frequency).
#
# EPSILON (1e-6) is purely a divide-by-zero safety net for the cumulative
# roll; it is not a randomness source.
#
# Output: returns the chosen variant's atlas coord. Also writes
# `out["pd"] = chosen.pd` so the caller can record the chosen pd into
# `painted_pd` for future neighbors. `out` is required (caller passes a fresh
# Dictionary); on `variants.is_empty()` fallback, out["pd"] = 0.0.
static func _pick_variant_coord(
	variants: Array,
	altitude_half_steps: int,
	x: int, y: int, layer_alt: int, seed: int,
	fallback: Vector2i,
	nb: Dictionary,
	painted_pd: Dictionary,
	out: Dictionary,
) -> Vector2i:
	if variants.is_empty():
		out["pd"] = 0.0
		return fallback

	# Neighbor-density pull. Skipped when painted_pd is empty (cliff-back).
	# Neighbors with pd <= 0 don't contribute (their clumping is "off").
	var pull: float = 0.0
	if not painted_pd.is_empty():
		for d in DiamondCompass.FACE_DIRS:
			var n_key := Vector2i(x + d.x, y + d.y)
			if painted_pd.has(n_key):
				var n_pd: float = float(painted_pd[n_key])
				if n_pd > 0.0:
					pull += n_pd

	var weights: Array[float] = []
	var candidates: Array = []
	var total: float = 0.0
	for v in variants:
		var sw: float = float(v["sw"])
		if sw < 0.0:
			continue
		var w: float = 1.0
		var pa: float = float(v["pa"])
		if pa > 0.0:
			var ad: float = float(altitude_half_steps) - pa
			w *= exp(- (ad * ad) / (2.0 * _SIGMA_ALT * _SIGMA_ALT))
		if sw > 0.0:
			w *= sw
		var pd: float = float(v["pd"])
		if pd > 0.0:
			w *= 1.0 + _CLUMP_GAIN * pull * pd
		w += _EPSILON
		weights.append(w)
		candidates.append(v)
		total += w
	if candidates.is_empty():
		out["pd"] = 0.0
		return fallback
	# hash() on a typed array is stable in Godot 4.6.
	var h: int = hash([x, y, layer_alt, seed]) & 0x7FFFFFFF
	var u01: float = float(h) / float(0x7FFFFFFF)
	if not nb.is_empty():
		var noise: FastNoiseLite = nb["noise"]
		var strength: float = clampf(float(nb["strength"]), 0.0, 1.0)
		# get_noise_2d returns roughly [-1, 1]; rescale to [0, 1].
		var nval: float = (noise.get_noise_2d(float(x), float(y)) + 1.0) * 0.5
		u01 = lerpf(u01, nval, strength)
	var roll: float = u01 * total
	var acc: float = 0.0
	for i in weights.size():
		acc += weights[i]
		if roll <= acc:
			out["pd"] = float(candidates[i]["pd"])
			return candidates[i]["coord"]
	out["pd"] = float(candidates.back()["pd"])
	return candidates.back()["coord"]


# Builds the per-biome variant-selection noise lookup. Returns a dict keyed by
# TerrainCell.Biome int → {"noise": FastNoiseLite, "strength": float}. Bands
# with strength <= 0 are omitted so the picker takes the cheap legacy path.
# Each biome gets its own decorrelated stream (seed XOR per-biome offset) so
# two biomes with the same frequency don't paint identical patterns.
#
# When multiple bands list the same biome (allowed: designer can split GRASS
# into multiple altitude ranges), the LAST entry's settings win — iteration
# order matches `params.biome_bands` array order.
static func _build_biome_noise(params: TerrainGenerationParams) -> Dictionary[int, Dictionary]:
	var out: Dictionary[int, Dictionary] = {}
	for band: TerrainBiomeBand in params.biome_bands:
		if band == null:
			continue
		if band.noise_strength <= 0.0:
			out.erase(band.biome)
			continue
		var n := FastNoiseLite.new()
		n.seed = params.seed ^ (0x4B10E001 + band.biome * 17)
		n.frequency = band.noise_frequency
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		out[band.biome] = {"noise": n, "strength": band.noise_strength}
	return out


# ----------------------------------------------------------------------------
# Mappings
# ----------------------------------------------------------------------------

static func _source_for_biome(biome: int) -> int:
	match biome:
		TerrainCell.Biome.GRASS: return SOURCE_GRASS
		TerrainCell.Biome.DIRT: return SOURCE_DIRT
		TerrainCell.Biome.ROCK: return SOURCE_ROCK
		TerrainCell.Biome.SNOW: return SOURCE_SNOW
	return SOURCE_GRASS


static func _ground_shape_to_kind(shape: int) -> StringName:
	match shape:
		TerrainCell.GroundShape.FULL_CUBE: return TileSlots.FULL_CUBE
		TerrainCell.GroundShape.FLAT: return TileSlots.FLAT
		TerrainCell.GroundShape.SLOPE_NE: return TileSlots.SLOPE_NE
		TerrainCell.GroundShape.SLOPE_NW: return TileSlots.SLOPE_NW
		TerrainCell.GroundShape.SLOPE_SE: return TileSlots.SLOPE_SE
		TerrainCell.GroundShape.SLOPE_SW: return TileSlots.SLOPE_SW
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
		1: return TileSlots.EDGE_NE
		2: return TileSlots.EDGE_NW
		4: return TileSlots.EDGE_SE
		8: return TileSlots.EDGE_SW
		3: return TileSlots.CORNER_N
		5: return TileSlots.CORNER_E
		12: return TileSlots.CORNER_S
		10: return TileSlots.CORNER_W
		6: return TileSlots.EDGE_NW_SE # banks NW+SE, channel runs NE-SW axis
		9: return TileSlots.EDGE_NE_SW # banks NE+SW, channel runs NW-SE axis
	if face != 0:
		# Unsupported face combination (3-sided, fully enclosed). Fall back to
		# the lowest-bit single edge so something paints.
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
			&"BOTH": return TileSlots.FALL_NE_BOTH
			&"TOP": return TileSlots.FALL_NE_TOP
			&"BOTTOM": return TileSlots.FALL_NE_BOTTOM
			&"NONE": return TileSlots.FALL_NE_NONE
	elif rise_dir == DiamondCompass.DIR_NW:
		match position:
			&"BOTH": return TileSlots.FALL_NW_BOTH
			&"TOP": return TileSlots.FALL_NW_TOP
			&"BOTTOM": return TileSlots.FALL_NW_BOTTOM
			&"NONE": return TileSlots.FALL_NW_NONE
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
