class_name TerrainGenerator
extends RefCounted

# ============================================================================
# TerrainGenerator
# ============================================================================
#
# Pure-data procedural terrain generator. Produces a `TerrainGrid` of fully
# resolved `TerrainCell` records — no Godot scene API calls anywhere in here.
# A separate `TerrainPainter` translates the grid into TileMapLayer paints.
#
# Pipeline:
#   1. Heightfield  (Euclidean cone descending from an apex near the visual N
#                   corner of the iso diamond; apex jittered per seed along
#                   the NE/NW edges; Perlin noise; snapped to even half-steps;
#                   cells past the cone base flatten to alt 0)
#   2. Carve summit lake  (~5x5 disc centered on the apex)
#   3. River trace  (south-biased walk from lake outlet to south edge,
#                   branches at waterfalls; force-finishes if it stalls)
#   4. Slope placement  (one slope per altitude-step boundary, plus ~30% extras)
#   5. Biome assignment  (altitude bands ± noise perturbation)
#   6. Water flow direction  (toward downstream neighbor; lake = still)
#   7. Shore mask  (4-bit land-neighbor mask → tile_kind at paint time)
#
# All compass and altitude conventions match tile_slots.gd / tile_grid.gd:
#   - Diamond compass: cell ( 0,-1)→NE, (-1,0)→NW, ( 1,0)→SE, ( 0,1)→SW.
#   - Altitudes are integer half-steps. FULL_CUBE = 2 half-steps.
#   - Slopes painted on LOW-end layer, rising toward their named direction.
#
# ============================================================================


# Public parameters live on `TerrainGenerationParams` (Resource-backed, in
# `scripts/data/terrain_generation_params.gd`). Internal references below
# use the new type name directly; old `TerrainGenerator.Params` callers
# should migrate to `TerrainGenerationParams`.


# Compass directions and shore-mask bits live on DiamondCompass — single
# source of truth shared with TerrainPainter, TerrainCell, and ProceduralWorld.
# Re-exported here so existing call sites (TerrainGenerator.DIR_NE, etc.)
# keep compiling without touching every file.
const DIR_NE: Vector2i = DiamondCompass.DIR_NE
const DIR_NW: Vector2i = DiamondCompass.DIR_NW
const DIR_SE: Vector2i = DiamondCompass.DIR_SE
const DIR_SW: Vector2i = DiamondCompass.DIR_SW
const _DIRS: Array[Vector2i] = DiamondCompass.FACE_DIRS

const DIR_APEX_N: Vector2i = DiamondCompass.DIR_APEX_N
const DIR_APEX_E: Vector2i = DiamondCompass.DIR_APEX_E
const DIR_APEX_S: Vector2i = DiamondCompass.DIR_APEX_S
const DIR_APEX_W: Vector2i = DiamondCompass.DIR_APEX_W
const _APEX_DIRS: Array[Vector2i] = DiamondCompass.APEX_DIRS

const _DIR_BITS: Array[int] = DiamondCompass.FACE_BITS
const _APEX_BITS: Array[int] = DiamondCompass.APEX_BITS

# Per-pass seed offsets so independent stochastic systems (biome noise, lake
# shape jitter) don't lock-step with the master seed. Truncated golden-ratio
# constant (0x9E3779B9) for biome — same trick splitmix64 uses to decorrelate
# adjacent seeds. Lake offset is an arbitrary distinct value.
const _SEED_OFFSET_BIOME: int = 0x9E3779B9
const _SEED_OFFSET_LAKE_JITTER: int = 0xBEEF1010
# Decorrelated stream for the south-cliff sweep order so randomizing visit order
# doesn't shift the apex/lake/river RNG sequence the rest of the pipeline reads.
const _SEED_OFFSET_SOUTH_CLIFF: int = 0xC11FF

# Top-left offsets of the four 2x2 squares a cell can be a member of. Used by
# _has_2x2_same_alt_block.
const _2X2_TL_OFFSETS: Array[Vector2i] = [
	Vector2i(0, 0),    # cell is NW (top-left) of the 2x2
	Vector2i(-1, 0),   # cell is NE (top-right)
	Vector2i(0, -1),   # cell is SW (bottom-left)
	Vector2i(-1, -1),  # cell is SE (bottom-right)
]


# ----------------------------------------------------------------------------
# Public entry
# ----------------------------------------------------------------------------

static func generate(params: TerrainGenerationParams) -> TerrainGrid:
	var grid := TerrainGrid.new(params.width, params.height)
	var rng := RandomNumberGenerator.new()
	rng.seed = params.seed

	var height_noise := _make_noise(params.seed, params.height_noise_frequency)
	var biome_noise := _make_noise(params.seed ^ _SEED_OFFSET_BIOME, params.biome_noise_frequency)

	# Cap on neighbor altitude differences (in half-steps). Cells violating
	# this cap get raised by _smooth_altitude_jumps; rivers may emit a waterfall
	# of any drop in [2, max_drop_hs].
	var max_drop_hs: int = maxi(2, params.max_drop_cubes * 2)

	# Apex (cone peak / lake center). Drawn first so its rng consumption is
	# stable across the rest of the pipeline; downstream rng calls (lake
	# aspect, slope placement, river bias) follow in a fixed order.
	var apex: Vector2i = _pick_apex(grid, params, rng)

	_fill_heightfield(grid, params, height_noise, apex)
	var peak_center: Vector2i = _carve_lake(grid, params, rng, apex)
	# Smooth jumps before tracing so the river walker sees a heightfield with
	# transitions no taller than max_drop_hs. Without smoothing, the lake can
	# sit next to ground arbitrarily far below it after carve+noise; the trace
	# would then have to fabricate intermediate altitudes.
	_smooth_altitude_jumps(grid, max_drop_hs)
	if peak_center.x >= 0:
		_trace_rivers(grid, params, rng, peak_center, max_drop_hs)
		_ensure_river_reaches_south(grid, params, rng, max_drop_hs)
	_widen_rivers(grid)
	_enforce_river_surroundings(grid)
	# Surroundings may have lifted lateral cells to a river's altitude, which
	# can re-introduce jumps a tier further out. Smooth again so slope
	# placement works on a clean heightfield (within the same cap).
	_smooth_altitude_jumps(grid, max_drop_hs)
	_fill_single_holes(grid, params)
	_smooth_thin_chains(grid, params)
	if params.enforce_south_cliff:
		_enforce_south_cliff_rule(grid, params, max_drop_hs)
	_place_slopes(grid, params, rng)
	_assign_biomes(grid, params, biome_noise)
	_assign_water_flow(grid)
	_assign_shore_masks(grid)

	return grid


# ----------------------------------------------------------------------------
# Step 1: heightfield
# ----------------------------------------------------------------------------

static func _fill_heightfield(
	grid: TerrainGrid,
	params: TerrainGenerationParams,
	noise: FastNoiseLite,
	apex: Vector2i,
) -> void:
	# Euclidean cone: altitude falls with distance from `apex`. Apex sits at
	# the visual N corner of the iso-projected grid (small x AND small y), so
	# the visible mountain face descends toward visual S/SE/SW — i.e., toward
	# the (width-1, height-1) tile corner. Cells past the cone's base clamp
	# to 0 via _snap_even and remain flat GROUND (no EMPTY clipping — the
	# river/painter rely on a contiguous walkable map). Perlin noise
	# modulates +/- a few half-steps so the cone is organic.
	#
	# Auto-fit slope: the cone reaches altitude 0 at the far diagonal corner
	# from `apex`; `cone_steepness` multiplies that rate. >1 bottoms out
	# before the corner (wider flat skirt); <1 keeps the whole map elevated.
	var far_dx: float = maxf(float(apex.x), float(grid.width - 1 - apex.x))
	var far_dy: float = float(grid.height - 1 - apex.y)
	var max_d: float = maxf(1.0, sqrt(far_dx * far_dx + far_dy * far_dy))
	var rate: float = float(params.top_altitude) / max_d * params.cone_steepness
	# Cliff bias reshapes the [-1, 1] noise via sign(n) * pow(abs(n), 1/cliff_bias).
	# At 1.0, the noise is unchanged (smooth Perlin). At >1, the distribution
	# pushes toward the extremes, so adjacent cells are more likely to land on
	# opposite tails — sharper altitude jumps. <1 flattens toward zero.
	var cliff_exp: float = 1.0 / maxf(0.01, params.cliff_bias)
	for y in grid.height:
		for x in grid.width:
			var dx: float = float(x - apex.x)
			var dy: float = float(y - apex.y)
			var d: float = sqrt(dx * dx + dy * dy)
			var cone_alt: float = float(params.top_altitude) - d * rate
			var n_raw: float = noise.get_noise_2d(x, y)
			var n: float = signf(n_raw) * pow(absf(n_raw), cliff_exp) * params.height_noise_amplitude
			var raw: float = cone_alt + n
			var snapped: int = _snap_even(int(round(raw)), 0, params.top_altitude)
			var cell: TerrainCell = grid.at(x, y)
			cell.kind = TerrainCell.Kind.GROUND
			cell.altitude = snapped
			cell.ground_shape = TerrainCell.GroundShape.FULL_CUBE


# Picks the cone apex / lake center near the visual N corner of the iso-
# projected diamond. The grid is rendered as a diamond, so the visual top of
# the screen is the (0, 0) tile corner — NOT the y=0 row (which is the NE
# edge of the diamond running from N corner to E corner).
#
# Default apex sits at (inset, inset), placing the lake at the visual top of
# the screen with enough margin for the lake disc. Jitter slides the apex
# along the upper edges of the diamond:
#   t > 0  → grid (inset+t, inset)        — slides along NE edge (visual right)
#   t < 0  → grid (inset, inset-t)        — slides along NW edge (visual left)
# This keeps the apex on the visual top of the screen at every seed, just
# offset horizontally by jitter.
static func _pick_apex(grid: TerrainGrid, params: TerrainGenerationParams, rng: RandomNumberGenerator) -> Vector2i:
	var inset: int = int(ceil(params.lake_radius)) + 1
	var max_extent: int = maxi(grid.width, grid.height) - 1 - 2 * inset
	var jitter_range: float = float(maxi(0, max_extent)) * params.apex_x_jitter_frac
	var t: float = rng.randf_range(-jitter_range, jitter_range)
	var dx: int = int(round(maxf(0.0, t)))
	var dy: int = int(round(maxf(0.0, -t)))
	var apex_x: int = clampi(inset + dx, inset, maxi(inset, grid.width - 1 - inset))
	var apex_y: int = clampi(inset + dy, inset, maxi(inset, grid.height - 1 - inset))
	return Vector2i(apex_x, apex_y)


static func _snap_even(v: int, lo: int, hi: int) -> int:
	v = clampi(v, lo, hi)
	if v % 2 != 0:
		v -= 1
	return clampi(v, lo, hi)


static func _make_noise(seed: int, frequency: float) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = seed
	n.frequency = frequency
	# Simplex's hexagonal lattice is far more isotropic than Perlin's square one.
	# Perlin features align with grid x/y axes, which iso-project to screen
	# diagonals and produce stair-stepped diagonal cliff lines. Simplex breaks
	# that alignment.
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	# Domain warp distorts sample coordinates with a second noise field, scrambling
	# any residual axis preferences. Amplitude is in noise-space units (cells in
	# our case); 30 is "noticeable but not chaotic" at our typical 32x48 maps.
	n.domain_warp_enabled = true
	n.domain_warp_type = FastNoiseLite.DOMAIN_WARP_SIMPLEX
	n.domain_warp_amplitude = 30.0
	n.domain_warp_frequency = 0.5 * frequency
	n.domain_warp_fractal_type = FastNoiseLite.DOMAIN_WARP_FRACTAL_PROGRESSIVE
	n.domain_warp_fractal_octaves = 2
	return n


# ----------------------------------------------------------------------------
# Step 2: carve summit lake
# ----------------------------------------------------------------------------

# Carves a randomly-shaped lake at the cone apex. The apex sits at the visual
# N corner of the iso diamond with per-seed jitter along the upper edges (see
# _pick_apex), so the lake reads as the peak of the mountain both visually
# (top of screen) and in altitude.
# Per-seed aspect ratio (lake_aspect_min..max along each axis) and large noise
# jitter produce visibly different silhouettes from one generation to the
# next — round, oblong, tilted, etc. Lake cells are forced to `top_altitude`
# regardless of the heightfield underneath.
#
# Returns the lake center cell (the apex), used downstream for river outlet.
static func _carve_lake(
	grid: TerrainGrid,
	params: TerrainGenerationParams,
	rng: RandomNumberGenerator,
	apex: Vector2i,
) -> Vector2i:
	var center: Vector2i = apex

	var r2: float = params.lake_radius * params.lake_radius
	var jitter_amp: float = params.lake_jitter_strength * r2
	var aspect_x: float = rng.randf_range(params.lake_aspect_min, params.lake_aspect_max)
	var aspect_y: float = rng.randf_range(params.lake_aspect_min, params.lake_aspect_max)
	var n := _make_noise(params.seed ^ _SEED_OFFSET_LAKE_JITTER, 0.4)
	# The disc may extend further along its longer axis; size the scan box
	# to the worst-case stretched radius so we don't miss boundary cells.
	var max_r: int = int(ceil(params.lake_radius * maxf(aspect_x, aspect_y))) + 1
	max_r = mini(max_r, maxi(grid.width, grid.height))
	for dy in range(-max_r, max_r + 1):
		for dx in range(-max_r, max_r + 1):
			var x: int = center.x + dx
			var y: int = center.y + dy
			if not grid.in_bounds(x, y):
				continue
			# Stretched distance: dividing the offset by the aspect makes the
			# implicit threshold radius along that axis equal to lake_radius *
			# aspect, so aspect > 1 widens the lake along that axis.
			var sdx: float = float(dx) / aspect_x
			var sdy: float = float(dy) / aspect_y
			var d2: float = sdx * sdx + sdy * sdy
			var jitter: float = n.get_noise_2d(x, y) * jitter_amp
			if d2 <= r2 + jitter:
				var cell: TerrainCell = grid.at(x, y)
				cell.kind = TerrainCell.Kind.WATER
				cell.altitude = params.top_altitude

	return center


# ----------------------------------------------------------------------------
# Step 3: river trace
# ----------------------------------------------------------------------------

# Walk water downhill from the lake. Each step considers diamond-face
# neighbors of the current water cell:
#   - same altitude WATER neighbor → continue along the river (already water)
#   - same altitude GROUND neighbor at the current tier → can convert to WATER
#   - lower altitude (T-2) GROUND neighbor → place WATERFALL on the LAND cell,
#     resume river at altitude T-2 starting from that waterfall cell.
#
# Branching: at each waterfall, with probability `branch_chance`, also spawn a
# second walker into a different valid downhill direction.
#
# South-bias: among multiple equally-valid candidates the walker prefers
# south-going steps (positive Y) by `params.south_bias`. Combined with the
# north-high heightfield, this drives walkers toward the south edge.
#
# Force-finish: a walker only stops on its own when it reaches `y == height-1`
# (south edge), or when it merges into an already-existing river (its SW
# neighbor is WATER/WATERFALL). If it would otherwise terminate before that,
# it takes a "stall step" SW into whatever GROUND cell sits there, regardless
# of altitude. Stall steps are capped per walker; if the cap is hit, the
# walker aborts with a warning.
static func _trace_rivers(
	grid: TerrainGrid,
	params: TerrainGenerationParams,
	rng: RandomNumberGenerator,
	lake_center: Vector2i,
	max_drop_hs: int,
) -> void:
	var outlet: Vector2i = _find_lake_outlet(grid, params, lake_center)
	if outlet.x < 0:
		return

	# A walker is [cell, altitude, last_dir, stall_count, width].
	var initial_width: int = maxi(1, params.initial_river_width)
	var walkers: Array = [[outlet, params.top_altitude, Vector2i.ZERO, 0, initial_width]]
	var steps: int = 0

	while not walkers.is_empty() and steps < params.max_river_steps:
		var w: Array = walkers.pop_back()
		var cell_xy: Vector2i = w[0]
		var alt: int = w[1]
		var last_dir: Vector2i = w[2]
		var stall_count: int = w[3]
		var width: int = w[4]
		steps += 1

		var here: TerrainCell = grid.at_or_null(cell_xy.x, cell_xy.y)
		if here == null:
			continue

		# Convert to water if not already (lake interior is already water).
		if here.kind == TerrainCell.Kind.GROUND:
			here.kind = TerrainCell.Kind.WATER
			here.altitude = alt
		# Tag as river so the widening pass knows to thicken this cell. Lake
		# interior cells stay at width 0 (no widening) since they were carved
		# before the trace started.
		here.river_width = maxi(here.river_width, width)

		# Walker reached the south edge — its job is done.
		if cell_xy.y >= grid.height - 1:
			continue

		var cands: Dictionary = _collect_walk_candidates(
			grid, cell_xy, alt, last_dir, max_drop_hs
		)
		var same_tier: Array[Vector2i] = cands["same"]
		var down_tier: Array[Vector2i] = cands["down"]

		# Prefer dropping to a lower tier; otherwise meander on the same tier.
		if not down_tier.is_empty():
			var drop_dir_idx: int = _pick_drop_candidate(
				down_tier, grid, cell_xy, alt,
				params.south_bias, params.drop_height_bias, rng,
			)
			var fall_to: Vector2i = down_tier[drop_dir_idx]
			var fall_dir: Vector2i = fall_to - cell_xy
			var lower_alt: int = grid.at(fall_to.x, fall_to.y).altitude
			# Record this cell's flow toward the cliff edge.
			here.water_flow = fall_dir
			# WATERFALL cell sits at the LOWER neighbor's grid coord but is
			# stored on the UPPER tier (`alt`). drop_height records the column
			# span (alt - lower_alt half-steps); the painter expands this into
			# stacked TOP/NONE*/BOTTOM tiles across multiple layers.
			var fall_cell: TerrainCell = grid.at(fall_to.x, fall_to.y)
			fall_cell.kind = TerrainCell.Kind.WATERFALL
			fall_cell.altitude = alt
			fall_cell.fall_rise_dir = -fall_dir   # rise dir = back toward the higher cliff
			fall_cell.drop_height = alt - lower_alt
			# Branching produces a SAME-TIER wander, never a second drop from
			# this cell. Two simultaneous drops from the same source would
			# always be in the SE+SW pair (the only paintable rises are NE/NW,
			# so legal fall_dirs are SW/SE), creating an inner waterfall corner
			# at the upper plateau's south apex. The waterfall atlas has no
			# inner-corner variant, so we route the branch laterally instead.
			# The branch may drop later, from a different cell that doesn't
			# share an upper plateau apex with the main drop.
			var branching: bool = rng.randf() < params.branch_chance \
					and not same_tier.is_empty()
			var main_width: int = _next_width(width, rng) if branching else width
			fall_cell.river_width = main_width
			# Continue river one step beyond the waterfall, at the basin tier.
			var beyond: Vector2i = fall_to + fall_dir
			walkers.append([beyond, lower_alt, fall_dir, 0, main_width])
			if branching:
				var br_idx: int = _pick_south_biased(same_tier, cell_xy, params.south_bias, rng)
				var br_to: Vector2i = same_tier[br_idx]
				var br_dir: Vector2i = br_to - cell_xy
				var br_width: int = _next_width(width, rng)
				here.river_width = maxi(here.river_width, maxi(main_width, br_width))
				walkers.append([br_to, alt, br_dir, 0, br_width])
			continue

		if not same_tier.is_empty():
			var idx: int = _pick_south_biased(same_tier, cell_xy, params.south_bias, rng)
			var nx: Vector2i = same_tier[idx]
			var ndir: Vector2i = nx - cell_xy
			# Record flow direction along the river path for this cell.
			here.water_flow = ndir
			# Same-tier wandering does NOT bump stall_count: the walker is
			# still progressing along the river path, and an east-west
			# meander on a long ridge is legitimate. The walker can't loop
			# forever here — the U-turn check prevents 2-cycle oscillation,
			# and `max_river_steps` (4096) caps total steps. Stall accounting
			# only applies to the forced-south fallback path below, which is
			# the truly degenerate case.
			walkers.append([nx, alt, ndir, 0, width])
			continue

		# Neither downhill nor same-tier GROUND candidate exists. If SW is
		# already WATER/WATERFALL the walker has merged into an existing
		# river — record the merge as flow and stop.
		var sw_neighbor: TerrainCell = grid.at_or_null(cell_xy.x + DIR_SW.x, cell_xy.y + DIR_SW.y)
		if sw_neighbor != null and (
				sw_neighbor.kind == TerrainCell.Kind.WATER
				or sw_neighbor.kind == TerrainCell.Kind.WATERFALL):
			here.water_flow = DIR_SW
			continue
		var stalled := _force_south_step(grid, cell_xy, last_dir, alt)
		if stalled.cell == cell_xy:
			# No legal forward step at all (corner-trapped or off-grid south).
			push_warning(
				"TerrainGenerator: river walker boxed in at %s (alt %d); aborting branch."
				% [cell_xy, alt]
			)
			continue
		var stall_next: int = stall_count + 1
		if stall_next > params.max_stall_steps:
			push_warning(
				"TerrainGenerator: river walker exceeded stall cap at %s (alt %d); aborting branch."
				% [cell_xy, alt]
			)
			continue
		# Stall step is south-going by construction. If it also drops a
		# tier (the SW neighbor was lower GROUND), place a waterfall —
		# without it the river would silently descend a cliff edge with no
		# falling-water graphic. Stall steps are SW-only so rise is always
		# NE (paintable). The indent check is intentionally skipped here:
		# the regular trace already rejected SW as a normal drop, so we're
		# in a fallback path. A tall NW neighbor at the basin renders as a
		# normal cube (its SE face is the back side, hidden in iso), so
		# allowing the waterfall there is visually sound and keeps the
		# river continuous instead of vanishing at a cliff.
		if stalled.alt < alt:
			here.water_flow = stalled.dir
			var fall_cell: TerrainCell = grid.at(stalled.cell.x, stalled.cell.y)
			fall_cell.kind = TerrainCell.Kind.WATERFALL
			fall_cell.altitude = alt
			fall_cell.fall_rise_dir = DIR_NE
			fall_cell.drop_height = alt - stalled.alt
			fall_cell.river_width = width
			var beyond: Vector2i = stalled.cell + stalled.dir
			walkers.append([beyond, stalled.alt, stalled.dir, stall_next, width])
			continue
		here.water_flow = stalled.dir
		walkers.append([stalled.cell, stalled.alt, stalled.dir, stall_next, width])


# Gathers `same_tier` (GROUND face neighbors at the walker's altitude) and
# `down_tier` (GROUND face neighbors at any even altitude in [alt-max_drop_hs,
# alt-2]) for one step of the river walker.
#
# NE (the only -Y diamond step) is forbidden — the walker must never head
# north, otherwise it can spiral. The U-turn check skips immediate reversals
# of `last_dir` to prevent tight 2-cycle oscillation on lateral wandering.
#
# Down-tier candidates are constrained to NE-rise / NW-rise drops (only
# paintable directions in the atlas) and rejected if they would form an
# indented (concave) corner that the atlas can't render.
#
# Returns a dict {"same": Array[Vector2i], "down": Array[Vector2i]} so the
# caller can pick from either bucket without re-scanning. Pure (no rng, no
# mutation), to keep `_trace_rivers` focused on the decision logic.
static func _collect_walk_candidates(
	grid: TerrainGrid,
	cell_xy: Vector2i,
	alt: int,
	last_dir: Vector2i,
	max_drop_hs: int,
) -> Dictionary:
	var same_tier: Array[Vector2i] = []
	var down_tier: Array[Vector2i] = []
	for d in _DIRS:
		if d == DIR_NE:
			continue
		if last_dir != Vector2i.ZERO and d == -last_dir:
			continue
		var n: Vector2i = cell_xy + d
		var nc: TerrainCell = grid.at_or_null(n.x, n.y)
		if nc == null:
			continue
		if nc.kind != TerrainCell.Kind.GROUND:
			continue
		if nc.altitude == alt:
			same_tier.append(n)
		elif nc.altitude < alt and nc.altitude >= alt - max_drop_hs:
			var rise: Vector2i = -d
			if rise != DIR_NE and rise != DIR_NW:
				continue
			if _would_indent_corner(grid, n, rise, alt):
				continue
			down_tier.append(n)
	return {"same": same_tier, "down": down_tier}


# True iff placing a waterfall at `cell` with rise direction `rise_dir` would
# form an indented (concave) corner: a lower cell with upper plateaus on
# BOTH its NE and NW sides. Those configurations would need a corner-shaped
# wall tile to render correctly; the painted set only has straight NE-rise
# and NW-rise variants, so the river must drop somewhere else.
#
# Outer corners (where two upper cubes share an edge but each cliff goes to
# a separate lower cell) are unaffected — they paint as two independent
# waterfall tiles on different cells.
static func _would_indent_corner(
	grid: TerrainGrid,
	cell: Vector2i,
	rise_dir: Vector2i,
	alt: int,
) -> bool:
	# Only the NE-rise / NW-rise pair is paintable and conflict-prone.
	var other_rise: Vector2i
	if rise_dir == DIR_NE:
		other_rise = DIR_NW
	elif rise_dir == DIR_NW:
		other_rise = DIR_NE
	else:
		return false
	var other_pos: Vector2i = cell + other_rise
	var other_cell: TerrainCell = grid.at_or_null(other_pos.x, other_pos.y)
	if other_cell == null:
		return false
	# The other side is "upper" if it sits at or above the source's altitude
	# and is solid (GROUND or WATER, including the lake).
	if other_cell.altitude < alt:
		return false
	# Only solid plateaus (GROUND or lake-like WATER) form a wall on the other
	# side. A WATERFALL at the same altitude is a sibling cliff face — two
	# adjacent cliff faces are exactly what a wide river produces, so they
	# should be allowed.
	return other_cell.kind == TerrainCell.Kind.GROUND \
			or other_cell.kind == TerrainCell.Kind.WATER


# Picks the width of a child segment at a branch point. Each side independently
# rolls to either keep the parent's width or shrink by one (clamped to >= 1).
static func _next_width(parent_width: int, rng: RandomNumberGenerator) -> int:
	if rng.randf() < 0.5:
		return parent_width
	return maxi(1, parent_width - 1)


# Pick an index into `cands` weighted by both south-direction (dy > 0) and
# drop height (alt - candidate.altitude). Used for selecting which lower
# neighbor a river drops into when multiple legal drops exist.
#
# Weight per candidate: pow(2, drop_bias * (drop_cubes - 1)) * (1 + south_bias
# if south-going else 1). With drop_bias == 0 (default) the drop term is 1.0
# for every candidate, so this reduces to plain south-bias weighting.
static func _pick_drop_candidate(
	cands: Array[Vector2i],
	grid: TerrainGrid,
	from: Vector2i,
	alt: int,
	south_bias: float,
	drop_bias: float,
	rng: RandomNumberGenerator,
) -> int:
	if cands.size() == 1:
		return 0
	var weights: Array[float] = []
	weights.resize(cands.size())
	for i in cands.size():
		var nc: TerrainCell = grid.at(cands[i].x, cands[i].y)
		var drop_cubes: int = (alt - nc.altitude) / 2
		var drop_w: float = pow(2.0, drop_bias * float(drop_cubes - 1))
		var dy: int = cands[i].y - from.y
		var south_w: float = 1.0 + (south_bias if dy > 0 else 0.0)
		weights[i] = drop_w * south_w
	return _weighted_pick(weights, rng)


# Pick an index into `cands` weighted toward south-going (dy > 0) candidates.
# Stable, simple weighting: each south-going candidate gets weight 1+south_bias,
# others get weight 1. Falls back to a uniform pick if nothing is south-going.
static func _pick_south_biased(
	cands: Array[Vector2i],
	from: Vector2i,
	south_bias: float,
	rng: RandomNumberGenerator,
) -> int:
	if cands.size() == 1:
		return 0
	var weights: Array[float] = []
	weights.resize(cands.size())
	for i in cands.size():
		var dy: int = cands[i].y - from.y
		weights[i] = 1.0 + (south_bias if dy > 0 else 0.0)
	return _weighted_pick(weights, rng)


# Linear-scan weighted pick. Returns an index into `weights`, with each
# index's selection probability proportional to its weight. Assumes weights
# are non-negative and at least one is positive; falls back to the last
# index if floating-point rounding overshoots the cumulative roll.
static func _weighted_pick(weights: Array[float], rng: RandomNumberGenerator) -> int:
	var total: float = 0.0
	for w in weights:
		total += w
	var roll: float = rng.randf() * total
	var acc: float = 0.0
	for i in weights.size():
		acc += weights[i]
		if roll <= acc:
			return i
	return weights.size() - 1


# Helper return for `_force_south_step`. Stays a tiny inner class so the call
# site reads clearly; perf doesn't matter here (rare path).
class _StalledStep extends RefCounted:
	var cell: Vector2i
	var alt: int
	var dir: Vector2i


# Push the walker south even if every "normal" rule would terminate it.
# Only the SW step is +Y on the iso compass (NE=(0,-1), NW=(-1,0), SE=(1,0),
# SW=(0,1)), so SW is the only true south step. Walks INTO the SW neighbor
# regardless of altitude, adopting its tier — this can produce flat WATER on
# a same-altitude cell or an uphill WATER (rare) when noise really fights us.
# Returns the original cell (with the original alt/dir) if nothing legal.
static func _force_south_step(
	grid: TerrainGrid,
	from: Vector2i,
	_last_dir: Vector2i,
	alt: int,
) -> _StalledStep:
	var out := _StalledStep.new()
	out.cell = from
	out.alt = alt
	out.dir = Vector2i.ZERO
	# Only consider truly south-bound diamond steps (+Y component).
	var tries: Array[Vector2i] = [DIR_SW]
	for d in tries:
		var n: Vector2i = from + d
		var nc: TerrainCell = grid.at_or_null(n.x, n.y)
		if nc == null:
			continue
		if nc.kind == TerrainCell.Kind.WATER or nc.kind == TerrainCell.Kind.WATERFALL:
			continue
		if nc.kind != TerrainCell.Kind.GROUND:
			continue
		# Refuse to flow uphill, even on a stall: a higher SW neighbor would
		# produce visible water-on-top-of-cliff. Caller's "boxed in" warning
		# fires instead.
		if nc.altitude > alt:
			continue
		# Adopt the neighbor's altitude so the river sits flush with the cell.
		out.cell = n
		out.alt = nc.altitude
		out.dir = d
		return out
	return out


# Guarantees that at least one river path reaches the south edge of the map
# (y == height - 1). Walkers in `_trace_rivers` can terminate early by getting
# boxed in, exceeding `max_stall_steps`, or merging into a sibling branch that
# itself didn't reach south. This pass fixes those cases:
#
#   1. If any WATER/WATERFALL cell already sits on the south row, no-op.
#   2. Otherwise, find the southmost river tip and walk SW from it. The walker
#      reuses `_collect_walk_candidates` (drop / same-tier) and the same
#      south-bias picks as the main trace, so its choices match the rest of
#      the river. When no candidate exists, it forces SW with NO stall cap,
#      walking through pre-existing water, lowering uphill GROUND, or clamping
#      over-tall drops. The forced path may carve a slot canyon through tall
#      terrain — preferable to silently failing the "river reaches the sea"
#      invariant. After smoothing already capped jumps to max_drop_hs, this
#      fallback rarely triggers.
#
# Runs before `_widen_rivers` and `_enforce_river_surroundings` so the extended
# segment picks up width, banks, and a final smoothing pass like any other
# river cell.
static func _ensure_river_reaches_south(
	grid: TerrainGrid,
	params: TerrainGenerationParams,
	rng: RandomNumberGenerator,
	max_drop_hs: int,
) -> void:
	if _river_reaches_south(grid):
		return
	var tip: Vector2i = _find_southmost_river_tip(grid)
	if tip.x < 0:
		return
	var width: int = maxi(1, grid.at(tip.x, tip.y).river_width)
	var cur: Vector2i = tip
	var alt: int = grid.at(tip.x, tip.y).altitude
	var last_dir: Vector2i = Vector2i.ZERO

	# A waterfall's grid position sits at the basin's coord but stores the
	# UPPER-tier altitude — walking from there at upper alt would treat the
	# basin as a fresh drop. Step past the waterfall to the basin tier first.
	if grid.at(tip.x, tip.y).kind == TerrainCell.Kind.WATERFALL:
		var lip: TerrainCell = grid.at(tip.x, tip.y)
		var fd: Vector2i = -lip.fall_rise_dir
		var basin_pos: Vector2i = tip + fd
		if grid.in_bounds(basin_pos.x, basin_pos.y):
			var basin_alt: int = lip.altitude - lip.drop_height
			var bcell: TerrainCell = grid.at(basin_pos.x, basin_pos.y)
			if bcell.kind == TerrainCell.Kind.GROUND:
				bcell.kind = TerrainCell.Kind.WATER
				bcell.altitude = basin_alt
				bcell.water_flow = fd
				bcell.river_width = maxi(bcell.river_width, width)
			cur = basin_pos
			alt = basin_alt
			last_dir = fd

	var safety: int = grid.width + grid.height + 8
	while cur.y < grid.height - 1 and safety > 0:
		safety -= 1
		var here_cell: TerrainCell = grid.at(cur.x, cur.y)
		var cands: Dictionary = _collect_walk_candidates(grid, cur, alt, last_dir, max_drop_hs)
		var same_tier: Array[Vector2i] = cands["same"]
		var down_tier: Array[Vector2i] = cands["down"]

		if not down_tier.is_empty():
			var di: int = _pick_drop_candidate(
				down_tier, grid, cur, alt,
				params.south_bias, params.drop_height_bias, rng,
			)
			var fall_to: Vector2i = down_tier[di]
			var fall_dir: Vector2i = fall_to - cur
			var fall_cell: TerrainCell = grid.at(fall_to.x, fall_to.y)
			var lower_alt: int = fall_cell.altitude
			if here_cell.kind == TerrainCell.Kind.WATER:
				here_cell.water_flow = fall_dir
			fall_cell.kind = TerrainCell.Kind.WATERFALL
			fall_cell.altitude = alt
			fall_cell.fall_rise_dir = -fall_dir
			fall_cell.drop_height = alt - lower_alt
			fall_cell.river_width = maxi(fall_cell.river_width, width)
			var beyond: Vector2i = fall_to + fall_dir
			var bc: TerrainCell = grid.at_or_null(beyond.x, beyond.y)
			if bc != null and bc.kind == TerrainCell.Kind.GROUND:
				bc.kind = TerrainCell.Kind.WATER
				bc.altitude = lower_alt
				bc.water_flow = fall_dir
				bc.river_width = maxi(bc.river_width, width)
			if not grid.in_bounds(beyond.x, beyond.y):
				break
			cur = beyond
			alt = lower_alt
			last_dir = fall_dir
			continue

		if not same_tier.is_empty():
			var si: int = _pick_south_biased(same_tier, cur, params.south_bias, rng)
			var nx: Vector2i = same_tier[si]
			var ndir: Vector2i = nx - cur
			if here_cell.kind == TerrainCell.Kind.WATER:
				here_cell.water_flow = ndir
			var nc: TerrainCell = grid.at(nx.x, nx.y)
			nc.kind = TerrainCell.Kind.WATER
			nc.altitude = alt
			nc.water_flow = ndir
			nc.river_width = maxi(nc.river_width, width)
			cur = nx
			last_dir = ndir
			continue

		# No legal forward step — force SW. The candidate collector excludes
		# uphill GROUND, water neighbors, and over-cap drops; this branch
		# handles each of those by tunneling rather than aborting.
		var sw: Vector2i = cur + DIR_SW
		var swc: TerrainCell = grid.at_or_null(sw.x, sw.y)
		if swc == null:
			break
		if here_cell.kind == TerrainCell.Kind.WATER:
			here_cell.water_flow = DIR_SW

		if swc.kind == TerrainCell.Kind.WATER or swc.kind == TerrainCell.Kind.WATERFALL:
			# Walk through existing water; adopt its altitude so subsequent
			# steps flow at the correct tier.
			cur = sw
			alt = swc.altitude
			last_dir = DIR_SW
			continue

		# GROUND neighbor that the candidate collector rejected: either uphill,
		# or a drop deeper than max_drop_hs.
		if swc.altitude > alt:
			# Uphill — tunnel by lowering it. Smoothing has already run, so
			# the delta is small (≤ max_drop_hs); leaves a slot-canyon-style
			# gap with the lateral banks staying tall.
			swc.kind = TerrainCell.Kind.WATER
			swc.altitude = alt
			swc.water_flow = DIR_SW
			swc.river_width = maxi(swc.river_width, width)
			cur = sw
			last_dir = DIR_SW
		else:
			# Drop > max_drop_hs. Clamp basin altitude so the painted column
			# fits the atlas's stacked TOP/NONE/BOTTOM range.
			var lower_alt: int = maxi(alt - max_drop_hs, swc.altitude)
			swc.kind = TerrainCell.Kind.WATERFALL
			swc.altitude = alt
			swc.fall_rise_dir = DIR_NE
			swc.drop_height = alt - lower_alt
			swc.river_width = maxi(swc.river_width, width)
			var beyond2: Vector2i = sw + DIR_SW
			var bc2: TerrainCell = grid.at_or_null(beyond2.x, beyond2.y)
			if bc2 != null and bc2.kind == TerrainCell.Kind.GROUND:
				bc2.kind = TerrainCell.Kind.WATER
				bc2.altitude = lower_alt
				bc2.water_flow = DIR_SW
				bc2.river_width = maxi(bc2.river_width, width)
			if not grid.in_bounds(beyond2.x, beyond2.y):
				break
			cur = beyond2
			alt = lower_alt
			last_dir = DIR_SW

	if not _river_reaches_south(grid):
		push_warning(
			"TerrainGenerator: failed to extend river to south edge from %s"
			% [tip]
		)


static func _river_reaches_south(grid: TerrainGrid) -> bool:
	var y: int = grid.height - 1
	for x in grid.width:
		var c: TerrainCell = grid.at(x, y)
		if c.kind == TerrainCell.Kind.WATER or c.kind == TerrainCell.Kind.WATERFALL:
			return true
	return false


# Southmost river cell, tiebreak by lowest altitude (closer to having descended
# the cone). Used as the start of the south-edge extension.
static func _find_southmost_river_tip(grid: TerrainGrid) -> Vector2i:
	var best: Vector2i = Vector2i(-1, -1)
	var best_y: int = -1
	var best_alt: int = 0x7FFFFFFF
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.WATER and c.kind != TerrainCell.Kind.WATERFALL:
				continue
			if y > best_y or (y == best_y and c.altitude < best_alt):
				best_y = y
				best_alt = c.altitude
				best = Vector2i(x, y)
	return best


static func _find_lake_outlet(
	grid: TerrainGrid,
	params: TerrainGenerationParams,
	lake_center: Vector2i,
) -> Vector2i:
	# Outlet = the lake-edge cell whose lowest GROUND face neighbor is the
	# lowest in the lake. Tie-break first by `x + y` (further down the cone),
	# then by distance to lake_center. Ranking by neighbor altitude (rather
	# than the older `x + y` heuristic) is robust to apex jitter, lake
	# stretching, and post-smoothing terrain — wherever the actual lowest
	# neighbor sits, that's where the river leaves.
	var best_neighbor_alt: int = 0x7FFFFFFF
	var best_score: int = -1
	var best_dist: int = 0x7FFFFFFF
	var best: Vector2i = Vector2i(-1, -1)
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.WATER:
				continue
			var min_neighbor_alt: int = 0x7FFFFFFF
			for d in _DIRS:
				var n: Vector2i = Vector2i(x, y) + d
				var nc: TerrainCell = grid.at_or_null(n.x, n.y)
				if nc == null or nc.kind != TerrainCell.Kind.GROUND:
					continue
				if nc.altitude < min_neighbor_alt:
					min_neighbor_alt = nc.altitude
			if min_neighbor_alt == 0x7FFFFFFF:
				continue  # no GROUND face neighbor
			var score: int = x + y
			var dist: int = absi(x - lake_center.x) + absi(y - lake_center.y)
			var better: bool = false
			if min_neighbor_alt < best_neighbor_alt:
				better = true
			elif min_neighbor_alt == best_neighbor_alt:
				if score > best_score:
					better = true
				elif score == best_score and dist < best_dist:
					better = true
			if better:
				best_neighbor_alt = min_neighbor_alt
				best_score = score
				best_dist = dist
				best = Vector2i(x, y)
	return best


# ----------------------------------------------------------------------------
# Step 4: slope placement
# ----------------------------------------------------------------------------

# For each ground cell at altitude T with an uphill neighbor at altitude T+2,
# convert this cell into a SLOPE_<dir> rising toward that neighbor with some
# probability. To guarantee reachability, we also force at least one slope
# per (upper-plateau) connected component.
static func _place_slopes(
	grid: TerrainGrid,
	params: TerrainGenerationParams,
	rng: RandomNumberGenerator,
) -> void:
	# First pass: probabilistic slopes.
	# Iteration order is shuffled so multiple uphill-edge candidates per upper
	# plateau don't always pick the same orientation.
	var coords: Array[Vector2i] = []
	for y in grid.height:
		for x in grid.width:
			coords.append(Vector2i(x, y))
	coords.shuffle()

	for c in coords:
		var here: TerrainCell = grid.at(c.x, c.y)
		if here.kind != TerrainCell.Kind.GROUND or here.ground_shape != TerrainCell.GroundShape.FULL_CUBE:
			continue
		var uphill_dirs: Array[Vector2i] = _uphill_neighbors(grid, c, here.altitude)
		# Filter to rise directions where the slope is geometrically valid:
		# walkable low approach AND no lateral drops. Slopes have a tapered
		# body, so any face neighbor below the slope's altitude exposes the
		# underside as void — better to reject the placement than back-fill.
		var valid_dirs: Array[Vector2i] = []
		for d in uphill_dirs:
			if _is_slope_geometrically_valid(grid, c, d, here.altitude):
				valid_dirs.append(d)
		if valid_dirs.is_empty():
			continue
		if rng.randf() >= params.slope_chance:
			continue
		var d: Vector2i = valid_dirs[rng.randi_range(0, valid_dirs.size() - 1)]
		here.ground_shape = _slope_shape_for(d)

	# Second pass: per-component reachability. Group same-altitude GROUND cells
	# into connected plateaus (face-adjacency flood-fill). For each plateau at
	# altitude > 0, ensure at least ONE cell in the plateau has an incoming
	# slope from a tier-(alt-2) neighbor; if not, force one. Per-component
	# (rather than per-cell) keeps total slope count proportional to the
	# number of plateaus, not the number of cells, so slope_chance dominates
	# the visual density on the slopes themselves.
	var visited: Dictionary = {}
	for y in grid.height:
		for x in grid.width:
			var start := Vector2i(x, y)
			if visited.has(start):
				continue
			visited[start] = true
			var c0: TerrainCell = grid.at(x, y)
			if c0.kind != TerrainCell.Kind.GROUND or c0.altitude == 0:
				continue
			var alt: int = c0.altitude
			var component: Array[Vector2i] = [start]
			var queue: Array[Vector2i] = [start]
			while not queue.is_empty():
				var cur: Vector2i = queue.pop_back()
				for d2 in _DIRS:
					var n: Vector2i = cur + d2
					if visited.has(n):
						continue
					var nc: TerrainCell = grid.at_or_null(n.x, n.y)
					if nc == null:
						continue
					if nc.kind != TerrainCell.Kind.GROUND or nc.altitude != alt:
						continue
					visited[n] = true
					component.append(n)
					queue.append(n)
			var has_entry: bool = false
			for cell_xy in component:
				if _has_incoming_slope(grid, cell_xy, alt):
					has_entry = true
					break
			if has_entry:
				continue
			# No incoming slope yet — force one. Find any (alt-2) FULL_CUBE
			# face-neighbor of any plateau cell that ALSO has a walkable cell
			# at its low approach (so the slope is usable from the lower side
			# rather than dangling off a cliff). If no such neighbor exists,
			# leave this plateau without an entry — it's intentionally
			# cliff-only reachable.
			var placed: bool = false
			for cell_xy in component:
				if placed:
					break
				for d3 in _DIRS:
					var lower: Vector2i = cell_xy + d3
					var lc: TerrainCell = grid.at_or_null(lower.x, lower.y)
					if lc == null or lc.kind != TerrainCell.Kind.GROUND:
						continue
					if lc.altitude != alt - 2:
						continue
					if lc.ground_shape != TerrainCell.GroundShape.FULL_CUBE:
						continue
					var rise_dir: Vector2i = -d3
					if not _is_slope_geometrically_valid(grid, lower, rise_dir, alt - 2):
						continue
					lc.ground_shape = _slope_shape_for(rise_dir)
					placed = true
					break


# A slope at `pos` rising in `rise_dir` is geometrically valid iff:
#   - The opposite-of-rise neighbor (low approach) is GROUND at altitude `alt`
#     so the player can step onto the slope's low end.
#   - The two lateral neighbors (perpendicular to rise) are GROUND at altitude
#     >= alt, so the slope's lateral sides don't expose a cliff face.
# (The uphill direction is implicitly at alt+2 — caller validates via
# `_uphill_neighbors` before calling this.)
#
# Slope tiles render with a tapered body (full-cube height at the back, zero
# at the front), so any direction with a lower neighbor leaves the slope's
# underside visible as void. Rejecting those placements is cleaner than
# back-filling cubes that would visually conflict with the slope's tapered
# graphic.
static func _is_slope_geometrically_valid(
	grid: TerrainGrid,
	pos: Vector2i,
	rise_dir: Vector2i,
	alt: int,
) -> bool:
	var low_approach: Vector2i = pos - rise_dir
	var lac: TerrainCell = grid.at_or_null(low_approach.x, low_approach.y)
	if lac == null or lac.kind != TerrainCell.Kind.GROUND or lac.altitude != alt:
		return false
	# Laterals are the two directions perpendicular to rise_dir.
	for d in _DIRS:
		if d == rise_dir or d == -rise_dir:
			continue
		var n: Vector2i = pos + d
		var nc: TerrainCell = grid.at_or_null(n.x, n.y)
		if nc == null:
			return false
		if nc.kind != TerrainCell.Kind.GROUND:
			return false
		if nc.altitude < alt:
			return false
	return true


# Returns the diamond-face directions in which (cell)'s neighbor is one
# altitude tier higher (alt + 2). These are the directions a slope could rise.
static func _uphill_neighbors(
	grid: TerrainGrid,
	cell: Vector2i,
	alt: int,
) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for d in _DIRS:
		var n: Vector2i = cell + d
		var nc: TerrainCell = grid.at_or_null(n.x, n.y)
		if nc == null:
			continue
		if nc.kind != TerrainCell.Kind.GROUND:
			continue
		if nc.altitude == alt + 2:
			out.append(d)
	return out


# True if any tier-(alt-2) neighbor of `cell` is already a slope rising INTO
# this cell.
static func _has_incoming_slope(grid: TerrainGrid, cell: Vector2i, alt: int) -> bool:
	for d in _DIRS:
		var n: Vector2i = cell + d
		var nc: TerrainCell = grid.at_or_null(n.x, n.y)
		if nc == null or nc.kind != TerrainCell.Kind.GROUND:
			continue
		if nc.altitude != alt - 2:
			continue
		var rise_dir: Vector2i = _slope_rise_vector(nc.ground_shape)
		if rise_dir == -d:
			return true
	return false


static func _slope_shape_for(dir: Vector2i) -> int:
	match dir:
		DIR_NE: return TerrainCell.GroundShape.SLOPE_NE
		DIR_NW: return TerrainCell.GroundShape.SLOPE_NW
		DIR_SE: return TerrainCell.GroundShape.SLOPE_SE
		DIR_SW: return TerrainCell.GroundShape.SLOPE_SW
	return TerrainCell.GroundShape.FULL_CUBE


static func _slope_rise_vector(shape: int) -> Vector2i:
	match shape:
		TerrainCell.GroundShape.SLOPE_NE: return DIR_NE
		TerrainCell.GroundShape.SLOPE_NW: return DIR_NW
		TerrainCell.GroundShape.SLOPE_SE: return DIR_SE
		TerrainCell.GroundShape.SLOPE_SW: return DIR_SW
	return Vector2i.ZERO


# ----------------------------------------------------------------------------
# Step 2.5 / 5.5: smooth altitude jumps
# ----------------------------------------------------------------------------

# Ensures no GROUND cell has a neighbor more than `max_drop_hs` half-steps
# higher. Any violation raises the offending cell to
# (max_neighbor_altitude - max_drop_hs). Only raises (never lowers); only
# mutates GROUND cells, leaving river/lake altitudes invariant. Iterates to
# a fixed point so cascading raises propagate outward.
#
# `max_drop_hs` must be a positive even number. With 2, this is the original
# step-1 behavior. With 8 (= 4 cubes), tall cliffs are allowed.
#
# Runs after `_carve_lake` (so the trace sees a bounded field and can decide
# how tall a waterfall to place at lake exits) and again after
# `_enforce_river_surroundings` (which lifts banks and can re-introduce
# jumps a tier further out).
static func _smooth_altitude_jumps(grid: TerrainGrid, max_drop_hs: int) -> void:
	var max_iter: int = 32
	var changed: bool = true
	while changed and max_iter > 0:
		changed = false
		max_iter -= 1
		for y in grid.height:
			for x in grid.width:
				var c: TerrainCell = grid.at(x, y)
				if c.kind != TerrainCell.Kind.GROUND:
					continue
				var max_alt: int = c.altitude
				for d in _DIRS:
					var n: Vector2i = Vector2i(x, y) + d
					var nc: TerrainCell = grid.at_or_null(n.x, n.y)
					if nc == null:
						continue
					# Solid neighbors only; EMPTY contributes nothing.
					if nc.kind == TerrainCell.Kind.EMPTY:
						continue
					if nc.altitude > max_alt:
						max_alt = nc.altitude
				if max_alt > c.altitude + max_drop_hs:
					c.altitude = max_alt - max_drop_hs
					changed = true


# ----------------------------------------------------------------------------
# Step 4.5: south-cliff readability rule
# ----------------------------------------------------------------------------

# Forces every GROUND cell's screen-south neighbor (x+1, y+1) to sit at or
# below the cell's altitude. Without this, noise-perturbed local peaks can
# render with no camera-facing cliff exposed, making elevation hard to read
# against same-screen-Y flat ground.
#
# Repair direction is downward only (lower the southern neighbor). Raising
# would cascade NW toward the apex and risk lifting cells past `top_altitude`;
# lowering cascades SE toward the map edge and terminates.
#
# Composes with previously enforced invariants so this pass doesn't re-break
# them:
#   - River surroundings: never lower below adjacent water altitude.
#   - Smoothing: never lower more than max_drop_hs below the tallest neighbor.
# When those constraints prevent the rule from being satisfied (e.g. the
# southern cell is a riverbank pinned by the river above), the local violation
# is left in place — usually near the apex where the visual ambiguity is least
# significant anyway.
#
# Iterates to a fixed point so cascading drops resolve in one call. Mutates
# GROUND cells only; WATER / WATERFALL exempt.
static func _enforce_south_cliff_rule(
		grid: TerrainGrid,
		params: TerrainGenerationParams,
		max_drop_hs: int,
) -> void:
	# Build a per-seed-randomized visit order. The deterministic y-outer/x-inner
	# sweep correlates altitudes along grid-(1,1) within a pass — visible as
	# screen-vertical streaks. Randomizing the order spreads any per-pass
	# correlation in all directions, while monotone-lowering keeps convergence
	# guaranteed (each cell can only ever be lowered, never raised).
	var rng_local := RandomNumberGenerator.new()
	rng_local.seed = params.seed ^ _SEED_OFFSET_SOUTH_CLIFF
	var positions: Array = []
	for y in grid.height - 1:
		for x in grid.width - 1:
			positions.append([rng_local.randi(), Vector2i(x, y)])
	positions.sort_custom(func(a, b): return a[0] < b[0])

	var max_iter: int = 8
	var changed: bool = true
	while changed and max_iter > 0:
		changed = false
		max_iter -= 1
		for entry in positions:
			var pos: Vector2i = entry[1]
			var here: TerrainCell = grid.at(pos.x, pos.y)
			if here.kind != TerrainCell.Kind.GROUND:
				continue
			var south_pos: Vector2i = Vector2i(pos.x + 1, pos.y + 1)
			var south: TerrainCell = grid.at(south_pos.x, south_pos.y)
			if south.kind != TerrainCell.Kind.GROUND:
				continue
			if south.altitude <= here.altitude:
				continue
			var min_alt: int = _south_min_altitude(grid, south_pos, max_drop_hs)
			var target: int = maxi(here.altitude, min_alt)
			# All sources of `target` are even (heightfield is even-snapped,
			# water altitudes are even, and max_drop_hs is even). Defensive
			# round-up in case a future change introduces an odd source.
			if target % 2 != 0:
				target += 1
			target = clampi(target, 0, params.top_altitude)
			if target < south.altitude:
				south.altitude = target
				changed = true


# Lowest altitude a cell at `pos` can be reduced to without breaking other
# invariants:
#   - Water adjacency: must stay >= any face-adjacent WATER/WATERFALL altitude
#     so the river-surroundings rule remains satisfied.
#   - Smoothing: must stay >= max neighbor altitude minus max_drop_hs so the
#     altitude-jump cap remains satisfied.
static func _south_min_altitude(grid: TerrainGrid, pos: Vector2i, max_drop_hs: int) -> int:
	var min_alt: int = 0
	for d in _DIRS:
		var n: Vector2i = pos + d
		var nc: TerrainCell = grid.at_or_null(n.x, n.y)
		if nc == null:
			continue
		if nc.kind == TerrainCell.Kind.WATER or nc.kind == TerrainCell.Kind.WATERFALL:
			if nc.altitude > min_alt:
				min_alt = nc.altitude
		var smoothing_floor: int = nc.altitude - max_drop_hs
		if smoothing_floor > min_alt:
			min_alt = smoothing_floor
	return min_alt


# ----------------------------------------------------------------------------
# Step 4.4: fill 1-cell holes
# ----------------------------------------------------------------------------

# Raises any GROUND cell whose four face neighbors are all GROUND at strictly
# higher altitude. The cell is set to the lowest face-neighbor altitude so the
# pit fills exactly to the surrounding rim. Without this, noise or smoothing
# can leave 1-cell pockets that read as confusing dimples in the heightfield.
#
# Cells with a non-GROUND face neighbor (water, lake, off-grid) are skipped —
# those are by definition not enclosed pits. Single pass: filling a hole only
# equalizes altitude with its rim, so cascades are not produced.
static func _fill_single_holes(grid: TerrainGrid, params: TerrainGenerationParams) -> void:
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.GROUND:
				continue
			var min_higher: int = 0x7FFFFFFF
			var all_higher: bool = true
			for d in _DIRS:
				var n: Vector2i = Vector2i(x, y) + d
				var nc: TerrainCell = grid.at_or_null(n.x, n.y)
				if nc == null or nc.kind != TerrainCell.Kind.GROUND:
					all_higher = false
					break
				if nc.altitude <= c.altitude:
					all_higher = false
					break
				if nc.altitude < min_higher:
					min_higher = nc.altitude
			if all_higher and min_higher != 0x7FFFFFFF:
				c.altitude = _snap_even(min_higher, 0, params.top_altitude)


# ----------------------------------------------------------------------------
# Step 4.45: smooth thin same-altitude chains (any direction)
# ----------------------------------------------------------------------------

# Detects and smooths chains of GROUND cells that lie on a 1-cell-wide strip of
# same altitude — i.e. their local same-altitude region never forms a 2x2 block.
# In iso projection:
#   - apex-only chains  (same-alt only via grid diagonal) project to screen
#     CARDINAL thin lines (vertical / horizontal),
#   - face-only chains  (same-alt only via a single grid axis) project to
#     screen DIAGONAL thin lines (NW-SE / NE-SW).
# Both read as floating 1-cell strips against the surrounding terrain. The
# 2x2-block test catches both symmetrically: any cell that is part of a "robust
# shelf" (any 2x2 of same altitude in its neighborhood) is left alone, while
# 1-wide strips of any orientation are flagged. Components of size 1 or 2 are
# left alone (single anomalies are fine; only sustained 3+ strips fire).
#
# Smoothing strategy: each chain cell adopts the most common altitude among
# its face neighbors (tiebreak toward higher altitude to preserve elevation).
# Targets are computed from the pre-mutation state so cells in the same chain
# don't bias each other's targets via partial mid-pass altitudes.
#
# Mutates GROUND only. Mode-targeting can only land on an existing neighbor's
# altitude, which by construction is at-or-above any face-adjacent water due
# to the river-surroundings rule — so this composes safely with surroundings.
static func _smooth_thin_chains(grid: TerrainGrid, params: TerrainGenerationParams) -> void:
	# Flag cells whose local same-altitude region is "thin" (no 2x2 block) AND
	# which still have at least one same-altitude neighbor (face or apex) — that
	# last condition excludes isolated bumps with no chain at all.
	var thin_set: Dictionary = {}
	for y in grid.height:
		for x in grid.width:
			var pos: Vector2i = Vector2i(x, y)
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.GROUND:
				continue
			if _has_2x2_same_alt_block(grid, pos, c.altitude):
				continue
			if _has_same_alt_neighbor(grid, pos, c.altitude):
				thin_set[pos] = true

	if thin_set.is_empty():
		return

	# Group via combined face + apex adjacency at matching altitude. Face
	# adjacency picks up grid-axis-aligned face-only chains; apex adjacency
	# picks up grid-diagonal apex-only chains. A chain is one connected run
	# of thin same-altitude cells. Components > 2 cells get smoothed.
	var visited: Dictionary = {}
	var pending_targets: Array = []  # entries: [Vector2i pos, int target_alt]
	for start in thin_set.keys():
		if visited.has(start):
			continue
		visited[start] = true
		var chain_alt: int = grid.at(start.x, start.y).altitude
		var component: Array[Vector2i] = []
		var queue: Array[Vector2i] = [start]
		while not queue.is_empty():
			var cur: Vector2i = queue.pop_back()
			component.append(cur)
			for d in _DIRS:
				var n: Vector2i = cur + d
				if visited.has(n) or not thin_set.has(n):
					continue
				var nc: TerrainCell = grid.at(n.x, n.y)
				if nc.altitude != chain_alt:
					continue
				visited[n] = true
				queue.append(n)
			for d in _APEX_DIRS:
				var n: Vector2i = cur + d
				if visited.has(n) or not thin_set.has(n):
					continue
				var nc: TerrainCell = grid.at(n.x, n.y)
				if nc.altitude != chain_alt:
					continue
				visited[n] = true
				queue.append(n)
		if component.size() <= 2:
			continue
		for p in component:
			var target: int = _diagonal_chain_target(grid, p, params.top_altitude)
			if target >= 0:
				pending_targets.append([p, target])

	for entry in pending_targets:
		var p: Vector2i = entry[0]
		var alt: int = entry[1]
		grid.at(p.x, p.y).altitude = alt


# True if any of the four 2x2 squares containing `pos` is entirely GROUND at
# `alt`. A 2x2 block is strong evidence of a natural shelf — cells inside one
# are spared from thin-chain smoothing. Squares checked (with `pos` at each
# corner): SE-corner (pos top-left), SW-corner, NE-corner, NW-corner.
static func _has_2x2_same_alt_block(grid: TerrainGrid, pos: Vector2i, alt: int) -> bool:
	for tl in _2X2_TL_OFFSETS:
		var origin: Vector2i = pos + tl
		var ok: bool = true
		for dy in 2:
			for dx in 2:
				var c: TerrainCell = grid.at_or_null(origin.x + dx, origin.y + dy)
				if c == null or c.kind != TerrainCell.Kind.GROUND or c.altitude != alt:
					ok = false
					break
			if not ok:
				break
		if ok:
			return true
	return false


# True if `pos` has at least one GROUND neighbor (face or apex) at the same
# altitude. Excludes WATER / WATERFALL / EMPTY / off-grid neighbors.
static func _has_same_alt_neighbor(grid: TerrainGrid, pos: Vector2i, alt: int) -> bool:
	for d in _DIRS:
		var n: Vector2i = pos + d
		var nc: TerrainCell = grid.at_or_null(n.x, n.y)
		if nc != null and nc.kind == TerrainCell.Kind.GROUND and nc.altitude == alt:
			return true
	for d in _APEX_DIRS:
		var n: Vector2i = pos + d
		var nc: TerrainCell = grid.at_or_null(n.x, n.y)
		if nc != null and nc.kind == TerrainCell.Kind.GROUND and nc.altitude == alt:
			return true
	return false


# Picks the altitude a diagonal-chain cell at `pos` should adopt: the most
# common altitude among its GROUND face neighbors. Tie broken toward HIGHER
# altitude so chains in mixed terrain rise rather than carve grooves into the
# slope (also avoids dropping below water altitude when a chain runs near a
# riverbank). Returns -1 if `pos` has no GROUND face neighbor (rare: would
# only happen on a fully water-locked land cell).
static func _diagonal_chain_target(grid: TerrainGrid, pos: Vector2i, top_alt: int) -> int:
	var counts: Dictionary = {}
	for d in _DIRS:
		var n: Vector2i = pos + d
		var nc: TerrainCell = grid.at_or_null(n.x, n.y)
		if nc == null or nc.kind != TerrainCell.Kind.GROUND:
			continue
		var a: int = nc.altitude
		counts[a] = counts.get(a, 0) + 1
	if counts.is_empty():
		return -1
	var best_alt: int = -1
	var best_count: int = -1
	for a in counts.keys():
		var ct: int = counts[a]
		if ct > best_count or (ct == best_count and a > best_alt):
			best_count = ct
			best_alt = a
	return _snap_even(best_alt, 0, top_alt)


# ----------------------------------------------------------------------------
# Step 3.5: widen rivers
# ----------------------------------------------------------------------------

# Widens river segments along a fixed +X (= SE) offset based on each cell's
# `river_width` tag. A cell with width 2 paints itself at (x, y) and a
# sibling cell at (x+1, y) inheriting its kind, altitude, flow/rise direction,
# and width. Width 3 adds (x+2, y) too, and so on.
#
# The widening direction is intentionally fixed (rather than perpendicular to
# flow per cell) so that wide segments stay contiguous when the river bends —
# (x, y) and (x+1, y) form a 2-wide strip regardless of whether the centerline
# at (x, y) flows SW, SE, or NW.
const _WIDEN_OFFSET: Vector2i = Vector2i(1, 0)


static func _widen_rivers(grid: TerrainGrid) -> void:
	# Snapshot centerline (kind, altitude, flow, width) before mutating so the
	# widened cells we add this pass don't get re-widened in turn.
	#
	# Waterfalls are intentionally NOT widened. The widening offset is fixed
	# `(+1, 0)` (SE), but for an NE-rise waterfall the fall direction is SW —
	# orthogonal to widening. The widened sibling would be a free-standing
	# waterfall whose basin cell is plain GROUND, and the surroundings pass
	# would lift that GROUND up to the lip altitude, leaving the column to
	# render onto solid plateau. Letting waterfall lips stay narrow looks fine
	# and avoids the orphan-column class of bug. Wide rivers reconverge on the
	# lower tier where regular WATER cells widen normally.
	var centerlines: Array = []
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.river_width <= 1:
				continue
			if c.kind != TerrainCell.Kind.WATER:
				continue
			centerlines.append([Vector2i(x, y), c])

	for entry in centerlines:
		var origin: Vector2i = entry[0]
		var c: TerrainCell = entry[1]
		var w: int = c.river_width
		for i in range(1, w):
			var pos: Vector2i = origin + _WIDEN_OFFSET * i
			var nc: TerrainCell = grid.at_or_null(pos.x, pos.y)
			if nc == null:
				break
			# Don't trample existing water — another branch may already own
			# this cell, or it may be lake interior.
			if nc.kind == TerrainCell.Kind.WATER or nc.kind == TerrainCell.Kind.WATERFALL:
				break
			nc.kind = c.kind
			nc.altitude = c.altitude
			nc.water_flow = c.water_flow
			nc.river_width = c.river_width
			# fall_rise_dir / drop_height are WATERFALL-only; centerline is
			# guaranteed kind == WATER above, so leave the defaults on the
			# widened sibling (no inherited stale waterfall metadata).


# ----------------------------------------------------------------------------
# Step 3.7: enforce river / lake surroundings
# ----------------------------------------------------------------------------

# Rule: every river cell (WATER or WATERFALL) and every lake cell must have
# its GROUND face neighbors at altitude >= the cell's altitude. Slopes are
# stored at their LOW altitude, so a SLOPE at T-2 next to a river at T counts
# as "lower" and gets raised; a SLOPE at T (high end at T+2) counts as same
# and is left alone — exactly the user's "same-altitude ramp is fine" rule.
#
# Iterates all 4 diamond face dirs without trying to filter by flow axis.
# Filtering would seem to skip "upstream/downstream" cells, but those are
# water (kind != GROUND) by construction and would be no-ops anyway. At
# corners (river turning) and at wide-river edges (widening parallel to flow
# axis), an axis filter incorrectly excludes real banks that happen to sit
# along the flow coordinate axis — this caused alt-drop holes next to water.
#
# Mutates GROUND only — never demotes WATER/WATERFALL.
static func _enforce_river_surroundings(grid: TerrainGrid) -> void:
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.WATER and c.kind != TerrainCell.Kind.WATERFALL:
				continue
			for d in _DIRS:
				var n: Vector2i = Vector2i(x, y) + d
				var nc: TerrainCell = grid.at_or_null(n.x, n.y)
				if nc == null:
					continue
				if nc.kind != TerrainCell.Kind.GROUND:
					continue
				if nc.altitude < c.altitude:
					nc.altitude = c.altitude
					nc.ground_shape = TerrainCell.GroundShape.FULL_CUBE


# ----------------------------------------------------------------------------
# Step 5: biome assignment
# ----------------------------------------------------------------------------

# Bands (in half-step altitude):
#   [ 0, 4]  → GRASS
#   ( 4, 8]  → DIRT
#   ( 8, 12] → ROCK
#   (12, 16] → SNOW
# Local noise perturbs the band threshold up to ±biome_noise_amplitude.
static func _assign_biomes(grid: TerrainGrid, params: TerrainGenerationParams, noise: FastNoiseLite) -> void:
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.GROUND:
				continue
			var n: float = noise.get_noise_2d(x, y) * params.biome_noise_amplitude
			var perturbed: float = float(c.altitude) + n
			c.biome_score = perturbed
			c.biome = _biome_for(perturbed)


static func _biome_for(alt: float) -> int:
	if alt <= 4.0:
		return TerrainCell.Biome.GRASS
	if alt <= 8.0:
		return TerrainCell.Biome.DIRT
	if alt <= 12.0:
		return TerrainCell.Biome.ROCK
	return TerrainCell.Biome.SNOW


# ----------------------------------------------------------------------------
# Step 6: water flow direction
# ----------------------------------------------------------------------------

# Water cells along the river are assigned `water_flow` directly during
# `_trace_rivers` — the walker knows each step's direction, so flow is
# recorded as the river is laid down. Widened siblings inherit the
# centerline's flow in `_widen_rivers`. Lake-interior cells deliberately
# stay at ZERO (still water).
#
# This pass is a safety net for the rare case where a WATER cell ended up
# adjacent to a WATERFALL whose rise points back at it (e.g. an unusual
# topology produced by widening or branch merge). It's defensive — the
# common path is already covered. Cheap O(N) scan; keep.
static func _assign_water_flow(grid: TerrainGrid) -> void:
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.WATER:
				continue
			if c.water_flow != Vector2i.ZERO:
				continue
			for d in _DIRS:
				var n: Vector2i = Vector2i(x, y) + d
				var nc: TerrainCell = grid.at_or_null(n.x, n.y)
				if nc == null:
					continue
				if nc.kind == TerrainCell.Kind.WATERFALL \
						and nc.altitude == c.altitude \
						and nc.fall_rise_dir == -d:
					c.water_flow = d
					break


# ----------------------------------------------------------------------------
# Step 7: shore mask
# ----------------------------------------------------------------------------

static func _assign_shore_masks(grid: TerrainGrid) -> void:
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.WATER:
				continue
			var mask: int = 0
			# Face neighbors (low nibble): NE/NW/SE/SW.
			for i in _DIRS.size():
				var d: Vector2i = _DIRS[i]
				var n: Vector2i = Vector2i(x, y) + d
				if _is_land_for_shore(grid, n):
					mask |= _DIR_BITS[i]
			# Apex neighbors (high nibble): N/E/S/W. Used by the painter only
			# when no face neighbor is land — picks an INNER_* concave corner.
			for i in _APEX_DIRS.size():
				var d2: Vector2i = _APEX_DIRS[i]
				var n2: Vector2i = Vector2i(x, y) + d2
				if _is_land_for_shore(grid, n2):
					mask |= _APEX_BITS[i]
			c.shore_mask = mask


# Off-grid counts as land so a lake at the map edge gets a proper shore.
static func _is_land_for_shore(grid: TerrainGrid, pos: Vector2i) -> bool:
	var nc: TerrainCell = grid.at_or_null(pos.x, pos.y)
	if nc == null:
		return true
	return nc.kind == TerrainCell.Kind.GROUND \
			or nc.kind == TerrainCell.Kind.EMPTY
