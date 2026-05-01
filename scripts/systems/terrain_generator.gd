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
#   1. Heightfield  (FBM noise + three gradients (S→N, SW→NE, SE→NW), weighted
#                   sum normalized then snapped to even half-steps. A separate
#                   noisy disc mask carves the iso footprint into a roughly
#                   circular shape; cells outside the disc are EMPTY.)
#   2. Pick apex + carve lake  (apex = highest GROUND cell in the N quadrant;
#                   noise-jittered ellipse at apex_alt - lake_depth_hs, then
#                   a multi-cell BFS apron lifts surrounding GROUND with a
#                   distance-based falloff so the transition isn't a single
#                   hard cliff)
#   3. Smooth altitude jumps   (caps any neighbor altitude difference at
#                   max_drop_cubes * 2 half-steps so cliffs read as 1–4 tiles)
#   3b. Round corners          (radius-R majority filter for silhouette and
#                   radius-R median filter for altitude — each iteration
#                   smooths structural corners formed by multi-cell straight
#                   runs meeting at 90°. Median preserves clean cliffs.)
#   4. Simple river            (single south-going walker from lake outlet to
#                   the open boundary; emits WATERFALL on tier drops)
#   5. Support water           (lifts every WATER cell's 4 face GROUND
#                   neighbors to ≥ the water's altitude — banks the river;
#                   WATERFALL cells are skipped so their cliff face shows)
#   5b. Slope swap             (probabilistically replaces some FULL_CUBE
#                   cells with SLOPE_NE/SLOPE_NW where the swap bridges two
#                   walkable FULL_CUBE neighbors one cube apart along the
#                   rise axis; default chance 0 leaves the grid unchanged)
#   6. Biome assignment        (always GRASS; biome_score = altitude + noise
#                   feeds the painter's grass variant picker)
#   7. Shore mask              (4-bit land-neighbor mask → tile_kind at paint)
#
# All compass and altitude conventions match tile_slots.gd / tile_grid.gd:
#   - Diamond compass: cell ( 0,-1)→NE, (-1,0)→NW, ( 1,0)→SE, ( 0,1)→SW.
#   - Altitudes are integer half-steps. FULL_CUBE = 2 half-steps.
#
# ============================================================================


# Compass directions and shore-mask bits live on DiamondCompass — single
# source of truth shared with TerrainPainter, TerrainCell, and ProceduralWorld.
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

# Per-pass seed offsets so independent stochastic systems don't lock-step
# with the master seed. Truncated golden-ratio constant (0x9E3779B9) for
# biome — same trick splitmix64 uses to decorrelate adjacent seeds.
const _SEED_OFFSET_BIOME: int = 0x9E3779B9
const _SEED_OFFSET_LAKE_JITTER: int = 0xBEEF1010
const _SEED_OFFSET_MASK: int = 0xC1FCD15C
const _SEED_OFFSET_SLOPES: int = 0xA5105E0F

# Safety cap on the river walker. Module-level constant — designers don't
# need to tune this; it should only kick in on degenerate maps.
const _MAX_RIVER_STEPS: int = 4096


# ----------------------------------------------------------------------------
# Public entry
# ----------------------------------------------------------------------------

static func generate(params: TerrainGenerationParams) -> TerrainGrid:
	var grid := TerrainGrid.new(params.width, params.height)
	var rng := RandomNumberGenerator.new()
	rng.seed = params.seed

	var height_noise := _make_noise(params.seed, params.noise_frequency)
	var biome_noise := _make_noise(params.seed ^ _SEED_OFFSET_BIOME, params.biome_noise_frequency)
	var mask_noise := _make_noise(params.seed ^ _SEED_OFFSET_MASK, params.disc_edge_frequency)

	var max_drop_hs: int = maxi(2, params.max_drop_cubes * 2)

	_fill_heightfield(grid, params, height_noise, mask_noise)
	var apex: Vector2i = _pick_apex(grid, params, rng)
	var peak_center: Vector2i = Vector2i(-1, -1)
	if apex.x >= 0:
		peak_center = _carve_lake(grid, params, rng, apex)
		_lift_lake_apron(grid, params)
	_smooth_altitude_jumps(grid, max_drop_hs)
	_round_corners(grid, params)
	# Enforce monotonic descent toward south: a cell's SW and SE neighbors
	# must sit at or below the cell. Equivalently, a cell sits at or below
	# its NW and NE neighbors. Lowers any cell that violates this. Both
	#   - guarantees the river walker can always descend (no closed basins)
	#   - reads as a consistent camera-facing cliff: every elevated tile is
	#     supported by equal-or-higher tiles along its back (NW/NE) edges.
	_enforce_south_descent(grid)
	if peak_center.x >= 0:
		_trace_simple_river(grid, params, rng, peak_center, max_drop_hs)
		_emit_perpendicular_falls(grid, max_drop_hs)
	_support_water(grid)
	_remove_islands(grid)
	_swap_full_cubes_with_slopes(grid, params)
	_assign_biomes(grid, params, biome_noise)
	_assign_shore_masks(grid)

	return grid


# ----------------------------------------------------------------------------
# Step 1: heightfield
# ----------------------------------------------------------------------------

# Per cell:
#   k   = max(0.05, 1 - disc_radius_frac)               # steepening factor
#   gN  = max(0, 1 - (x + y) / ((W + H - 2) * k))       # S→N envelope, peaks at (0,0)
#   gNE = max(0, 1 - y / ((H - 1) * k))                 # SW→NE, peaks along y=0
#   gNW = max(0, 1 - x / ((W - 1) * k))                 # SE→NW, peaks along x=0
#   gradient = w_n*gN + w_ne*gNE + w_nw*gNW             # ADDITIVE (no normalization)
#   alt_t    = clamp(gradient + noise * noise_strength, 0, 1)
#
# Gradients are tied to disc_radius_frac via the steepening factor k. With a
# big disc (high frac → small k), the denominators shrink, so each gradient
# falls to 0 well inside the disc and stays clamped there — that bottom
# region becomes a flat plain (alt_t is just noise, near 0). With a small
# disc (low frac → k near 1), denominators approach the full grid extent
# and the gradients spread across the whole disc as before. The k-floor of
# 0.05 prevents divide-by-zero at frac → 1.
#
# Weights are additive, not relative — raising w_ne from 0 to 1 ADDS a full
# NE ridge on top of the N envelope. With multiple non-zero weights, gradient
# can exceed 1.0 near the N corner and the clamp pins those cells flat at
# top_altitude, producing a peak/lake plateau that suppresses noise terraces
# in that region. Designer tunes the weights so the desired peak/back-wall
# behavior emerges; if the back corner reads as too flat, lower the weights
# so the sum at (0, 0) sits closer to 1.0 and noise can still terrace.
#
# Noise in [-1, 1] (practically [-0.7, 0.7] for FBM) directly perturbs alt_t
# in units of [0, 1]; with noise_strength=0.6 alt extremes shift by up to
# ~0.6 * top_altitude half-steps — enough to produce multi-cube drops between
# adjacent cells in noise-peak regions, which the river walker turns into
# waterfalls. Where the gradient saturates against the clamp, noise loses
# this effect on the upper side (it can still dip the cell back below 1).
# In the flat-plain region (gradient = 0), noise alone determines altitude.
#
# Cells outside the noisy disc (mask_t < 0) are EMPTY. Surviving cells get
# altitude = snap_even(round(alt_t * top_altitude), 0, top_altitude). The
# snapping IS the terrace structure — plateaus form wherever the smooth
# `alt_t` value crosses several thresholds in a short horizontal span.
static func _fill_heightfield(
	grid: TerrainGrid,
	params: TerrainGenerationParams,
	noise: FastNoiseLite,
	mask_noise: FastNoiseLite,
) -> void:
	# Gradient steepening tied to disc size: bigger disc → steeper gradient
	# → flat plain emerges in the SW portion of the disc. Floored at 0.05
	# so denominators don't collapse at frac → 1.
	var grad_factor: float = maxf(0.05, 1.0 - 1.1 * params.disc_radius_frac)
	var w_denom: float = maxf(1.0, float(grid.width + grid.height - 2) * grad_factor)
	var x_denom: float = maxf(1.0, float(grid.width - 1) * grad_factor)
	var y_denom: float = maxf(1.0, float(grid.height - 1) * grad_factor)

	var disc_cx: float = float(grid.width) * params.disc_center_x_frac
	var disc_cy: float = float(grid.height) * params.disc_center_y_frac
	var disc_r: float = maxf(0.5, float(mini(grid.width, grid.height)) * params.disc_radius_frac)

	for y in grid.height:
		for x in grid.width:
			var cell: TerrainCell = grid.at(x, y)

			var dx: float = float(x) - disc_cx
			var dy: float = float(y) - disc_cy
			var d_norm: float = sqrt(dx * dx + dy * dy) / disc_r
			var nm: float = mask_noise.get_noise_2d(x, y)
			var mask_t: float = (1.0 - d_norm) + nm * params.disc_edge_jitter
			if mask_t < 0.0:
				cell.kind = TerrainCell.Kind.EMPTY
				continue

			var g_n: float = maxf(0.0, 1.0 - float(x + y) / w_denom)
			var g_ne: float = maxf(0.0, 1.0 - float(y) / y_denom)
			var g_nw: float = maxf(0.0, 1.0 - float(x) / x_denom)
			var gradient: float = params.weight_n * g_n + params.weight_ne * g_ne + params.weight_nw * g_nw
			var n: float = noise.get_noise_2d(x, y)
			var alt_t: float = clampf(gradient + n * params.noise_strength, 0.0, 1.0)
			var snapped: int = _snap_even(
				int(round(alt_t * float(params.top_altitude))),
				0,
				params.top_altitude,
			)
			cell.kind = TerrainCell.Kind.GROUND
			cell.altitude = snapped
			cell.ground_shape = TerrainCell.GroundShape.FULL_CUBE


# Disc-mask noise and later passes (lake carve, river tracing, corner rounding)
# can leave small pockets of non-EMPTY cells separated from the main landmass
# by a ring of EMPTY. These read as floating "islands" in the painter and
# aren't intended. Keep only the largest 4-connected component of non-EMPTY
# cells (face neighbors only, no diagonals — diagonal-only adjacency still
# counts as disconnected) and carve every other non-EMPTY cell back to EMPTY.
#
# Connectivity treats GROUND, WATER, and WATERFALL as a single "terrain"
# class joined by EMPTY voids, so a continent split by a lake or river still
# reads as one component (the lake/river is a bridge, not a break). Runs at
# the very end of generation (after _support_water, before _assign_biomes /
# _assign_shore_masks) so every kind-mutating pass has had its say.
#
# Tie-break for largest: first-seen, deterministic at fixed seed.
static func _remove_islands(grid: TerrainGrid) -> void:
	var w: int = grid.width
	var h: int = grid.height
	var component_id := PackedInt32Array()
	component_id.resize(w * h)
	for i in component_id.size():
		component_id[i] = -1
	var component_sizes: Array[int] = []
	var largest_id: int = -1
	var largest_size: int = 0

	for sy in h:
		for sx in w:
			var seed_cell: TerrainCell = grid.at(sx, sy)
			if seed_cell.kind == TerrainCell.Kind.EMPTY:
				continue
			var seed_idx: int = sy * w + sx
			if component_id[seed_idx] != -1:
				continue
			var cid: int = component_sizes.size()
			component_sizes.append(0)
			var frontier: Array[Vector2i] = [Vector2i(sx, sy)]
			component_id[seed_idx] = cid
			var head: int = 0
			while head < frontier.size():
				var pos: Vector2i = frontier[head]
				head += 1
				component_sizes[cid] += 1
				for d in _DIRS:
					var np: Vector2i = pos + d
					if not grid.in_bounds(np.x, np.y):
						continue
					var nidx: int = np.y * w + np.x
					if component_id[nidx] != -1:
						continue
					var nc: TerrainCell = grid.at(np.x, np.y)
					if nc.kind == TerrainCell.Kind.EMPTY:
						continue
					component_id[nidx] = cid
					frontier.append(np)
			if component_sizes[cid] > largest_size:
				largest_size = component_sizes[cid]
				largest_id = cid

	if largest_id == -1:
		return
	for y in h:
		for x in w:
			var idx: int = y * w + x
			var cell_cid: int = component_id[idx]
			if cell_cid == -1 or cell_cid == largest_id:
				continue
			var c: TerrainCell = grid.at(x, y)
			c.kind = TerrainCell.Kind.EMPTY
			c.altitude = 0
			c.ground_shape = TerrainCell.GroundShape.FULL_CUBE
			c.water_flow = Vector2i.ZERO
			c.shore_mask = 0
			c.fall_rise_dir = Vector2i.ZERO
			c.drop_height = 2
			c.fall_rise_dir_b = Vector2i.ZERO
			c.drop_height_b = 0
			c.river_width = 0


# Step 5b: probabilistically replace some FULL_CUBE cells with SLOPE_NE or
# SLOPE_NW so the player can walk between adjacent altitude tiers. A swap
# fires when the cell sits next to two walkable FULL_CUBE neighbors one
# cube apart along the rise axis. Two altitude variants are considered per
# cell at altitude A (per orientation):
#
#   "low" variant  → slope altitude A     (cell stays at A; high end at A+2,
#                    so the high-side neighbor must be FULL_CUBE at A+2 and
#                    the low-side neighbor FULL_CUBE at A)
#   "high" variant → slope altitude A-2   (cell drops to A-2; high end at A,
#                    so the high-side neighbor must be FULL_CUBE at A and the
#                    low-side neighbor FULL_CUBE at A-2)
#
# A cell's eligible variants are collected, a single rng roll < chance gates
# the swap, then one variant is picked uniformly. This keeps the per-cell
# swap probability equal to slope_swap_chance regardless of how many
# variants are eligible.
#
# Downward ("high") variants (alt_offset > 0) are skipped when any face
# neighbor is WATER or WATERFALL: that bank was lifted by _support_water to
# match the water surface, so lowering the cell would leave water hanging
# over a sunken bank. Low variants stay legal in the same situation because
# they don't change cell.altitude.
#
# Iteration is row-major and deterministic at fixed seed; the rng is
# decorrelated from the master seed via _SEED_OFFSET_SLOPES so changing
# slope_swap_chance doesn't shift heightfield/lake/river patterns. Each
# placed slope CLAIMS its two endpoint neighbors (low + high) so a later
# swap can't repurpose them — which would silently invalidate the first
# slope's bridge by turning a FULL_CUBE endpoint into a SLOPE_*.
static func _swap_full_cubes_with_slopes(
	grid: TerrainGrid,
	params: TerrainGenerationParams,
) -> void:
	if params.slope_swap_chance <= 0.0:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = params.seed ^ _SEED_OFFSET_SLOPES
	var claimed: Dictionary = {}
	# Variant table: (shape, high_dir, low_dir, alt_offset). alt_offset is
	# subtracted from the cell's current altitude to produce the slope's
	# stored altitude (the low end). 0 = "low" variant, 2 = "high" variant.
	var variants: Array = [
		[TerrainCell.GroundShape.SLOPE_NE, DIR_NE, DIR_SW, 0],
		[TerrainCell.GroundShape.SLOPE_NE, DIR_NE, DIR_SW, 2],
		[TerrainCell.GroundShape.SLOPE_NW, DIR_NW, DIR_SE, 0],
		[TerrainCell.GroundShape.SLOPE_NW, DIR_NW, DIR_SE, 2],
	]
	for y in grid.height:
		for x in grid.width:
			var pos := Vector2i(x, y)
			if claimed.has(pos):
				continue
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.GROUND:
				continue
			if c.ground_shape != TerrainCell.GroundShape.FULL_CUBE:
				continue
			# A downward variant lowers the cell's altitude. If any face
			# neighbor is WATER or WATERFALL, that bank was lifted by
			# _support_water to match the water surface; lowering it would
			# leave the water hanging over a sunken cell. Cache once so we
			# don't rescan four neighbors per variant.
			var has_water_face: bool = _has_water_face_neighbor(grid, pos)
			var eligible: Array = []
			for v in variants:
				var alt_offset: int = int(v[3])
				if alt_offset > 0 and has_water_face:
					continue
				var slope_alt: int = c.altitude - alt_offset
				if slope_alt < 0:
					continue
				if _slope_swap_eligible(grid, pos, slope_alt, v[1], v[2], claimed):
					eligible.append(v)
			if eligible.is_empty():
				continue
			# Cluster boost: multiply the base chance when a face neighbor is
			# already a slope. Iteration is row-major and reads the live grid,
			# so each placed slope expands the boosted area for cells the
			# pass hasn't visited yet — slopes seed-and-grow into clusters.
			var effective_chance: float = params.slope_swap_chance
			if params.slope_swap_adjacent_multiplier > 1.0 \
					and _has_slope_face_neighbor(grid, pos):
				effective_chance = clampf(
					effective_chance * params.slope_swap_adjacent_multiplier,
					0.0,
					1.0,
				)
			if rng.randf() >= effective_chance:
				continue
			var pick: Array = eligible[rng.randi() % eligible.size()]
			c.ground_shape = pick[0]
			c.altitude -= int(pick[3])
			claimed[pos] = true
			claimed[pos + (pick[1] as Vector2i)] = true
			claimed[pos + (pick[2] as Vector2i)] = true
			# Lift any GROUND face neighbor sitting below the slope's stored
			# (low-end) altitude so the slope's four sides are fully backed by
			# terrain — without this, the perpendicular SE/SW (or SW/NE for
			# SLOPE_NW) faces can expose voids when those neighbors are on a
			# lower tier. WATER/WATERFALL/EMPTY are left alone (their altitude
			# is owned by other systems / they're off-disc).
			_lift_slope_skirt(grid, pos, c.altitude)


# Raises every GROUND face neighbor of `pos` to at least `min_alt` (the
# slope's stored low-end altitude). Prevents visible holes around a freshly
# placed slope: the painter only stacks fill cubes UNDER c.altitude, so a
# perpendicular neighbor sitting on a lower tier leaves a void on the
# slope's side face. The two bridging neighbors (low at min_alt, high at
# min_alt+2) are no-ops here by construction; only the perpendicular pair
# can need lifting. WATER/WATERFALL altitudes are owned by the river/lake
# systems so we don't touch them — a slope abutting water at a lower
# altitude is rare (the water-face guard already blocks downward swaps in
# that case) and falls through to the painter's existing geometry.
static func _lift_slope_skirt(grid: TerrainGrid, pos: Vector2i, min_alt: int) -> void:
	for d in _DIRS:
		var nc: TerrainCell = grid.at_or_null(pos.x + d.x, pos.y + d.y)
		if nc == null or nc.kind != TerrainCell.Kind.GROUND:
			continue
		if nc.altitude < min_alt:
			nc.altitude = min_alt


# True iff any of the cell's four face neighbors is already a SLOPE_NE or
# SLOPE_NW. Drives the slope-swap pass's cluster boost: cells next to an
# existing slope roll against a higher effective chance.
static func _has_slope_face_neighbor(grid: TerrainGrid, pos: Vector2i) -> bool:
	for d in _DIRS:
		var nc: TerrainCell = grid.at_or_null(pos.x + d.x, pos.y + d.y)
		if nc == null or nc.kind != TerrainCell.Kind.GROUND:
			continue
		if nc.ground_shape == TerrainCell.GroundShape.SLOPE_NE \
				or nc.ground_shape == TerrainCell.GroundShape.SLOPE_NW:
			return true
	return false


# True iff any of the cell's four face neighbors is WATER or WATERFALL.
# Used by the slope-swap pass to forbid downward swaps next to water — the
# bank was lifted to the water surface by _support_water, and lowering it
# would leave the water unsupported.
static func _has_water_face_neighbor(grid: TerrainGrid, pos: Vector2i) -> bool:
	for d in _DIRS:
		var nc: TerrainCell = grid.at_or_null(pos.x + d.x, pos.y + d.y)
		if nc == null:
			continue
		if nc.kind == TerrainCell.Kind.WATER or nc.kind == TerrainCell.Kind.WATERFALL:
			return true
	return false


# True iff the cell at `pos` could carry a slope of stored altitude `slope_alt`
# rising toward `high_dir` (descending toward `low_dir`). The high-side
# neighbor must be FULL_CUBE GROUND at slope_alt+2 and the low-side neighbor
# FULL_CUBE GROUND at slope_alt — so the slope's two ends meet existing
# walkable surfaces with no leftover cliff at either end. Either endpoint
# already claimed by another slope disqualifies the candidate.
#
# The two perpendicular face neighbors (NW/SE for SLOPE_NE; NE/SW for
# SLOPE_NW) get a softer check: they may sit below slope_alt and will be
# lifted by _lift_slope_skirt after the swap — but only if they're not
# already claimed as another slope's bridge endpoint, since lifting a
# claimed endpoint would silently invalidate that slope's altitude pair.
static func _slope_swap_eligible(
	grid: TerrainGrid,
	pos: Vector2i,
	slope_alt: int,
	high_dir: Vector2i,
	low_dir: Vector2i,
	claimed: Dictionary,
) -> bool:
	var hi_pos: Vector2i = pos + high_dir
	if claimed.has(hi_pos):
		return false
	var hi: TerrainCell = grid.at_or_null(hi_pos.x, hi_pos.y)
	if hi == null or hi.kind != TerrainCell.Kind.GROUND:
		return false
	if hi.ground_shape != TerrainCell.GroundShape.FULL_CUBE:
		return false
	if hi.altitude != slope_alt + 2:
		return false
	var lo_pos: Vector2i = pos + low_dir
	if claimed.has(lo_pos):
		return false
	var lo: TerrainCell = grid.at_or_null(lo_pos.x, lo_pos.y)
	if lo == null or lo.kind != TerrainCell.Kind.GROUND:
		return false
	if lo.ground_shape != TerrainCell.GroundShape.FULL_CUBE:
		return false
	if lo.altitude != slope_alt:
		return false
	# Perpendicular faces — must not require lifting a claimed cell.
	for d in _DIRS:
		if d == high_dir or d == low_dir:
			continue
		var pp: Vector2i = pos + d
		if not claimed.has(pp):
			continue
		var pn: TerrainCell = grid.at_or_null(pp.x, pp.y)
		if pn == null or pn.kind != TerrainCell.Kind.GROUND:
			continue
		if pn.altitude < slope_alt:
			return false
	return true


# Apex (= lake center) is the highest GROUND cell in a small corner window
# anchored at the N corner (grid 0,0), with random tie-breaking among
# equally-high cells so seed variation produces visibly different lake
# placement. Inset by `lake_radius + lake_back_margin + 1` from the NW/NE
# edges so the lake's shoreline always sits behind a strip of dry GROUND.
# The window size is `lake_apex_window_frac * min(W, H)` cells per axis —
# small enough that the lake stays near the N corner even when the noise
# field produces taller peaks deeper in the map.
#
# Returns Vector2i(-1, -1) if no GROUND exists in the corner window
# (extremely carved seed) — the caller skips the lake/river phases.
static func _pick_apex(grid: TerrainGrid, params: TerrainGenerationParams, rng: RandomNumberGenerator) -> Vector2i:
	var inset: int = int(ceil(params.lake_radius)) + params.lake_back_margin + 1
	var window: int = maxi(1, int(round(float(mini(grid.width, grid.height)) * params.lake_apex_window_frac)))
	var qx: int = mini(grid.width, inset + window)
	var qy: int = mini(grid.height, inset + window)
	# Guarantee the search window has at least one cell even on tiny grids.
	qx = maxi(qx, inset + 1)
	qy = maxi(qy, inset + 1)
	var best_alt: int = -1
	var best_cells: Array[Vector2i] = []
	for y in range(inset, qy):
		for x in range(inset, qx):
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.GROUND:
				continue
			if c.altitude > best_alt:
				best_alt = c.altitude
				best_cells = [Vector2i(x, y)]
			elif c.altitude == best_alt:
				best_cells.append(Vector2i(x, y))
	if best_cells.is_empty():
		return Vector2i(-1, -1)
	return best_cells[rng.randi() % best_cells.size()]


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

# Carves a randomly-shaped lake at the apex. Per-seed aspect ratio
# (lake_aspect_min..max along each axis) and large noise jitter produce
# visibly different silhouettes from one generation to the next — round,
# oblong, tilted, etc. Lake cells are set to apex_alt - lake_depth_hs (snapped
# even, clamped to [0, top_altitude]); with depth > 0 the lake sits in a
# bowl below the local peak, so surrounding GROUND can rise above the water.
#
# Returns the lake center cell, used downstream for river outlet.
static func _carve_lake(
	grid: TerrainGrid,
	params: TerrainGenerationParams,
	rng: RandomNumberGenerator,
	apex: Vector2i,
) -> Vector2i:
	var center: Vector2i = apex
	var apex_cell: TerrainCell = grid.at(apex.x, apex.y)
	var lake_alt: int = _snap_even(
		apex_cell.altitude - params.lake_depth_hs,
		0,
		params.top_altitude,
	)

	var r2: float = params.lake_radius * params.lake_radius
	var jitter_amp: float = params.lake_jitter_strength * r2
	var aspect_x: float = rng.randf_range(params.lake_aspect_min, params.lake_aspect_max)
	var aspect_y: float = rng.randf_range(params.lake_aspect_min, params.lake_aspect_max)
	var n := _make_noise(params.seed ^ _SEED_OFFSET_LAKE_JITTER, 0.4)
	var max_r: int = int(ceil(params.lake_radius * maxf(aspect_x, aspect_y))) + 1
	max_r = mini(max_r, maxi(grid.width, grid.height))
	for dy in range(-max_r, max_r + 1):
		for dx in range(-max_r, max_r + 1):
			var x: int = center.x + dx
			var y: int = center.y + dy
			if not grid.in_bounds(x, y):
				continue
			var sdx: float = float(dx) / aspect_x
			var sdy: float = float(dy) / aspect_y
			var d2: float = sdx * sdx + sdy * sdy
			var jitter: float = n.get_noise_2d(x, y) * jitter_amp
			if d2 <= r2 + jitter:
				var cell: TerrainCell = grid.at(x, y)
				if cell.kind == TerrainCell.Kind.EMPTY:
					continue # disc mask carved this cell out
				cell.kind = TerrainCell.Kind.WATER
				cell.altitude = lake_alt

	return center


# Multi-source BFS apron: for every GROUND cell within `lake_apron_radius`
# face-steps of any WATER cell, lift its altitude to at least
# `lake_alt - dist * lake_apron_falloff_hs`. Only lifts; never lowers.
#
# BFS preserves south-descent monotonicity: for any visited cell C at face-
# distance d, both NW and NE are face-neighbors of C, so they were visited
# at distance ≤ d (BFS invariant). Their lift target is therefore ≥ C's,
# so `_enforce_south_descent` won't undo apron lifts.
#
# Skips early if radius == 0 or falloff is 0 with no slack (degenerate).
static func _lift_lake_apron(grid: TerrainGrid, params: TerrainGenerationParams) -> void:
	var radius: int = params.lake_apron_radius
	if radius <= 0:
		return
	var falloff: int = params.lake_apron_falloff_hs

	# Seed BFS from every WATER cell. All water shares the same altitude
	# (set in _carve_lake), so we read it from the first water cell found.
	var visited: Dictionary = {}
	var frontier: Array = [] # entries: [Vector2i, dist]
	var lake_alt: int = -1
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.WATER:
				continue
			if lake_alt < 0:
				lake_alt = c.altitude
			var key: Vector2i = Vector2i(x, y)
			visited[key] = 0
			frontier.append([key, 0])

	if lake_alt < 0:
		return # no lake on this seed

	var head: int = 0
	while head < frontier.size():
		var entry: Array = frontier[head]
		head += 1
		var pos: Vector2i = entry[0]
		var d: int = entry[1]
		if d >= radius:
			continue
		var nd: int = d + 1
		var target: int = lake_alt - nd * falloff
		for dir in _DIRS:
			var np: Vector2i = pos + dir
			if visited.has(np):
				continue
			var nc: TerrainCell = grid.at_or_null(np.x, np.y)
			if nc == null:
				continue
			if nc.kind != TerrainCell.Kind.GROUND:
				continue
			visited[np] = nd
			if target > nc.altitude:
				nc.altitude = target
			frontier.append([np, nd])


# ----------------------------------------------------------------------------
# Step 3: smooth altitude jumps
# ----------------------------------------------------------------------------

# Caps any neighbor altitude difference at `max_drop_hs` half-steps. Iterates
# to a fixed point so cascading lifts resolve in one call. Cells violating
# the cap get raised; we never lower because doing so could cascade across
# the whole map. EMPTY cells contribute nothing.
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
					if nc.kind == TerrainCell.Kind.EMPTY:
						continue
					if nc.altitude > max_alt:
						max_alt = nc.altitude
				if max_alt > c.altitude + max_drop_hs:
					c.altitude = max_alt - max_drop_hs
					changed = true


# ----------------------------------------------------------------------------
# Step 3b: round corners
# ----------------------------------------------------------------------------

# Multi-scale corner rounding. Each iteration runs a silhouette majority
# filter at radius `silhouette_round_radius` and an altitude median filter
# at radius `altitude_round_radius`. Sampling a window (instead of just the
# 4 face neighbors) lets the pass detect structural corners — places where
# two multi-cell straight runs meet at a 90° angle — and round them.
#
# Why median for altitude:
#   - Median preserves clean cliff edges (step functions). At a long straight
#     altitude transition, half the window is high and half is low; median
#     lands on the boundary, so each side keeps its altitude.
#   - Median rounds noise and corners. At a corner of a tall plateau, the
#     window has fewer high cells (the plateau wraps around) than low; median
#     pulls toward the dominant tier, dropping the corner.
#   - Median ∈ [min, max] of the window, so this pass never invents new
#     altitudes; it can only push toward existing ones.
#
# Why majority + stickiness for silhouette:
#   - Pure majority (stickiness=0) flips eagerly near 0.5 fraction, which can
#     ping-pong cells between passes. Stickiness adds a hysteresis band so
#     only clear majorities flip.
#   - At a convex L-corner (cell at the tip of two straight runs meeting),
#     the window leans EMPTY → cell flips to EMPTY.
#   - At a concave L-corner (EMPTY tucked inside two perpendicular GROUND
#     runs), the window leans GROUND → cell flips to GROUND at median window
#     altitude.
#
# WATER and WATERFALL cells are never modified (owned by lake/river logic).
# Their altitudes participate in altitude windows so banks anchor properly.
# Their kind counts as "GROUND-equivalent" in the silhouette window — they
# are part of the disc body, not edges to be eaten by rounding.
static func _round_corners(grid: TerrainGrid, params: TerrainGenerationParams) -> void:
	if params.corner_round_passes <= 0:
		return
	var silhouette_offsets: Array[Vector2i] = _face_radius_offsets(params.silhouette_round_radius)
	var altitude_offsets: Array[Vector2i] = _face_radius_offsets(params.altitude_round_radius)
	for _i in params.corner_round_passes:
		if params.silhouette_round_radius > 0:
			_silhouette_round_pass(grid, params, silhouette_offsets)
		if params.altitude_round_radius > 0:
			_altitude_round_pass(grid, params, altitude_offsets)


# Returns all (dx, dy) offsets in the face-Manhattan ball of radius r —
# i.e., points reachable by ≤ r steps along DIR_NE/DIR_NW/DIR_SE/DIR_SW.
# Includes (0, 0). For r=0 returns just [(0,0)]; r=1 returns 5 offsets;
# r=2 returns 13; r=k returns 2k²+2k+1.
static func _face_radius_offsets(r: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if r <= 0:
		out.append(Vector2i.ZERO)
		return out
	for dy in range(-r, r + 1):
		var x_span: int = r - absi(dy)
		for dx in range(-x_span, x_span + 1):
			out.append(Vector2i(dx, dy))
	return out


# Silhouette pass: radius-R majority filter with stickiness band.
# Off-grid samples count as not-GROUND (so grid-corner cells lean toward
# being EMPTY, matching the disc carve behavior). WATER and WATERFALL count
# as GROUND-equivalent (part of the body).
#
# Decisions deferred until both pass scans complete so flips don't cascade
# within one pass — keeps the filter idempotent for a fixed input.
static func _silhouette_round_pass(
	grid: TerrainGrid,
	params: TerrainGenerationParams,
	offsets: Array[Vector2i],
) -> void:
	var stickiness: float = params.silhouette_round_stickiness
	var lo: float = 0.5 - stickiness
	var hi: float = 0.5 + stickiness

	var to_empty: Array[Vector2i] = []
	var to_fill: Array = [] # entries: [Vector2i, alt:int]
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			# Only flip cells along the silhouette boundary — interior GROUND
			# and far-from-disc EMPTY don't need analysis.
			if c.kind != TerrainCell.Kind.GROUND and c.kind != TerrainCell.Kind.EMPTY:
				continue
			var ground_count: int = 0
			var total: int = 0
			var alt_samples: Array[int] = [] # only collected when this is an EMPTY cell that might fill
			for o in offsets:
				var nx: int = x + o.x
				var ny: int = y + o.y
				total += 1
				var nc: TerrainCell = grid.at_or_null(nx, ny)
				if nc == null:
					continue # off-grid counts as not-GROUND
				if nc.kind == TerrainCell.Kind.EMPTY:
					continue
				ground_count += 1
				if c.kind == TerrainCell.Kind.EMPTY:
					alt_samples.append(nc.altitude)
			if total == 0:
				continue
			var frac: float = float(ground_count) / float(total)
			if c.kind == TerrainCell.Kind.GROUND:
				if frac < lo:
					to_empty.append(Vector2i(x, y))
			else: # EMPTY
				if frac > hi and alt_samples.size() > 0:
					alt_samples.sort()
					var median: int = alt_samples[alt_samples.size() / 2]
					to_fill.append([Vector2i(x, y), _snap_even(median, 0, params.top_altitude)])
	for p in to_empty:
		grid.at(p.x, p.y).kind = TerrainCell.Kind.EMPTY
	for entry in to_fill:
		var pos: Vector2i = entry[0]
		var alt: int = entry[1]
		var cell: TerrainCell = grid.at(pos.x, pos.y)
		cell.kind = TerrainCell.Kind.GROUND
		cell.altitude = alt
		cell.ground_shape = TerrainCell.GroundShape.FULL_CUBE


# Altitude pass: radius-R median filter at strength S. For each GROUND cell,
# the median altitude across all GROUND/WATER/WATERFALL cells in the window
# is computed; the cell's altitude is moved fractionally toward it.
#
# Strength=1 is a classic edge-preserving median filter. Strength<1 is a
# gentler pull (lerp toward median) that leaves more of the original
# heightfield intact. Final altitudes are snapped to even half-steps.
#
# WATER/WATERFALL altitudes participate in the median (so a bank cell next
# to high water won't drop below water level on rounding) but are themselves
# never modified.
static func _altitude_round_pass(
	grid: TerrainGrid,
	params: TerrainGenerationParams,
	offsets: Array[Vector2i],
) -> void:
	var strength: float = params.altitude_round_strength
	if strength <= 0.0:
		return
	# Collect new altitudes first, write at end, so a cell's update doesn't
	# bias its neighbor's window mid-pass.
	var updates: Array = [] # entries: [Vector2i, new_alt:int]
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.GROUND:
				continue
			var alts: Array[int] = []
			for o in offsets:
				var nx: int = x + o.x
				var ny: int = y + o.y
				var nc: TerrainCell = grid.at_or_null(nx, ny)
				if nc == null:
					continue
				if nc.kind == TerrainCell.Kind.EMPTY:
					continue
				alts.append(nc.altitude)
			if alts.size() < 2:
				continue
			alts.sort()
			var median: int = alts[alts.size() / 2]
			var lerped: float = lerp(float(c.altitude), float(median), strength)
			var new_alt: int = _snap_even(int(round(lerped)), 0, params.top_altitude)
			if new_alt != c.altitude:
				updates.append([Vector2i(x, y), new_alt])
	for entry in updates:
		var pos: Vector2i = entry[0]
		grid.at(pos.x, pos.y).altitude = entry[1]


# Enforces monotonic altitude descent in the SE/SW direction. After this
# pass every GROUND cell satisfies:
#   alt(x, y) <= alt(x - 1, y)   # NW neighbor
#   alt(x, y) <= alt(x, y - 1)   # NE neighbor
# (equivalently: SW and SE neighbors are at or below this cell).
#
# Implementation: a single raster sweep (y outer ascending, x inner ascending).
# When (x, y) is processed, NW=(x-1, y) and NE=(x, y-1) have already been
# finalized, so reading their values and clamping `me` to min(NW, NE)
# propagates correctly with no need to iterate.
#
# WATER cells (the lake) and EMPTY cells are skipped as constraint sources —
# water doesn't laterally support its south neighbors, and EMPTY has no
# altitude. Cells along the back edges (x=0 or y=0) are unconstrained on
# their missing back-neighbor side.
#
# This pass replaces basin-fill: any closed depression's "low" cells are
# lowered to the heightfield value of their lowest NW/NE neighbor, so the
# river walker always has a same-tier or downhill candidate.
static func _enforce_south_descent(grid: TerrainGrid) -> void:
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.GROUND:
				continue
			var max_allowed: int = 0x7FFFFFFF
			if x > 0:
				var nw: TerrainCell = grid.at(x - 1, y)
				if nw.kind == TerrainCell.Kind.GROUND or nw.kind == TerrainCell.Kind.WATER \
						or nw.kind == TerrainCell.Kind.WATERFALL:
					if nw.altitude < max_allowed:
						max_allowed = nw.altitude
			if y > 0:
				var ne: TerrainCell = grid.at(x, y - 1)
				if ne.kind == TerrainCell.Kind.GROUND or ne.kind == TerrainCell.Kind.WATER \
						or ne.kind == TerrainCell.Kind.WATERFALL:
					if ne.altitude < max_allowed:
						max_allowed = ne.altitude
			if max_allowed != 0x7FFFFFFF and c.altitude > max_allowed:
				c.altitude = max_allowed


# ----------------------------------------------------------------------------
# Step 4: simple river
# ----------------------------------------------------------------------------

# Gravity walker from the lake outlet to the open south boundary, optionally
# spawning tributary branches. The walker is single-cell-wide and descends
# strictly south (DIR_SE or DIR_SW).
#
# Pipeline:
#   1. Run the primary walker. At each step, roll `river_branch_chance` to
#      queue a branch seed at the unchosen SE/SW candidate.
#   2. Run each queued branch as a single-depth sub-walker (no further
#      branching). A branch that boxes in early simply stops.
static func _trace_simple_river(
	grid: TerrainGrid,
	params: TerrainGenerationParams,
	rng: RandomNumberGenerator,
	lake_center: Vector2i,
	max_drop_hs: int,
) -> void:
	var outlet: Vector2i = _find_lake_outlet(grid, params, lake_center)
	if outlet.x < 0:
		return

	# Walker starts ON the lake outlet (a WATER cell at lake altitude). Its
	# first step naturally drops to a GROUND cell south of the lake; if the
	# apron didn't fully equalize the bank, the drop is recorded as a
	# WATERFALL for the lake's spillway. Initial alt MUST be read from the
	# outlet cell, not `params.top_altitude`: with `lake_depth_hs > 0` the
	# lake sits below top_altitude, and using top_altitude here would emit
	# a phantom waterfall floating above the actual water surface.
	var branch_seeds: Array = [] # entries: [from_pos: Vector2i, from_alt: int, to_dir: Vector2i]
	_walk_river(
		grid, params, rng,
		outlet, grid.at(outlet.x, outlet.y).altitude,
		max_drop_hs,
		branch_seeds,
		true,
	)

	if not branch_seeds.is_empty():
		var dummy_branches: Array = []
		for seed in branch_seeds:
			var from_pos: Vector2i = seed[0]
			var from_alt: int = seed[1]
			var forced_dir: Vector2i = seed[2]
			dummy_branches.clear()
			_walk_river(
				grid, params, rng,
				from_pos, from_alt,
				max_drop_hs,
				dummy_branches,
				false, forced_dir,
			)


# Single-walker step engine. Mutates `grid` in place. When `allow_branching`
# is true, `branch_seeds_out` collects (from_pos, from_alt, to_dir) for the
# unchosen candidate at each step that rolls `river_branch_chance`.
# `first_step_dir` forces the very first step direction (used for branches
# so they go down the unchosen fork); pass Vector2i.ZERO for unforced.
static func _walk_river(
	grid: TerrainGrid,
	params: TerrainGenerationParams,
	rng: RandomNumberGenerator,
	start_pos: Vector2i,
	start_alt: int,
	max_drop_hs: int,
	branch_seeds_out: Array,
	allow_branching: bool,
	first_step_dir: Vector2i = Vector2i.ZERO,
) -> void:
	var pos: Vector2i = start_pos
	var alt: int = start_alt
	var steps: int = 0
	var force_first: bool = first_step_dir != Vector2i.ZERO

	while steps < _MAX_RIVER_STEPS:
		steps += 1
		var here: TerrainCell = grid.at_or_null(pos.x, pos.y)
		if here == null or here.kind == TerrainCell.Kind.EMPTY:
			return

		# Only convert GROUND to WATER — never overwrite WATER (lake) or
		# WATERFALL once placed. The lake outlet cell starts as WATER and
		# is therefore not re-converted.
		var just_converted: bool = false
		if here.kind == TerrainCell.Kind.GROUND:
			here.kind = TerrainCell.Kind.WATER
			here.altitude = alt
			just_converted = true
			# CORNER FALL UPGRADE (perpendicular wet face): this water cell may
			# sit on the perpendicular upper face of an existing single-face
			# waterfall — upgrade the waterfall to a corner so the painter
			# renders the now-wet face. Only SE/SW neighbors are checked: a
			# waterfall lip at our altitude with basin BELOW us must be in one
			# of those positions for our cell to be its upper-perpendicular
			# source. This catches cases where two parallel river forks land
			# on perpendicular sides of the same lip altitude (the merge-on-
			# lip and step-onto-fall paths only fire for falls placed in the
			# same cell).
			for d_check in [DIR_SE, DIR_SW]:
				var npos: Vector2i = pos + d_check
				var ncell: TerrainCell = grid.at_or_null(npos.x, npos.y)
				if ncell == null or ncell.kind != TerrainCell.Kind.WATERFALL:
					continue
				if ncell.fall_rise_dir_b != Vector2i.ZERO:
					continue
				if ncell.altitude != alt:
					continue
				var sec_rise: Vector2i = - d_check
				var perp: bool = (
					(ncell.fall_rise_dir == DIR_NE and sec_rise == DIR_NW)
					or (ncell.fall_rise_dir == DIR_NW and sec_rise == DIR_NE)
				)
				if not perp:
					continue
				ncell.fall_rise_dir_b = sec_rise
				ncell.drop_height_b = ncell.drop_height

		if _is_south_boundary(grid, pos.x, pos.y):
			return

		# Walker is strictly south-going: only DIR_SE and DIR_SW are considered.
		# The south-descent constraint guarantees both SE and SW neighbors are
		# at altitudes ≤ current, so the walker always descends or stays
		# same-tier. Restricting to SE/SW prevents zig-zag back into the
		# trail (which would otherwise close the walker off in a loop of its
		# own WATER cells).
		#
		# Drops larger than max_drop_hs are CAPPED rather than rejected: the
		# walker treats the neighbor as if it were at the max-drop basin and
		# emits a max_drop_hs waterfall there. The walker then resumes one
		# cell beyond at the capped basin altitude. If the underlying cliff
		# is taller than max_drop_hs, the next iteration's drop is still too
		# large and another waterfall is emitted — producing a stair-step
		# cascade that descends the cliff one max_drop_hs tier at a time
		# without ever boxing the walker in. Without this cap, a steep
		# heightfield (small grad_factor / large weight sum) would abort the
		# river walker whenever its tracked altitude exceeded a cliff edge.
		var cands: Array[Vector2i] = []
		var cand_alts: Array[int] = []
		for d in [DIR_SE, DIR_SW]:
			var nxy: Vector2i = pos + d
			var nc: TerrainCell = grid.at_or_null(nxy.x, nxy.y)
			if nc == null:
				continue
			if nc.kind == TerrainCell.Kind.GROUND:
				cands.append(nxy)
				cand_alts.append(maxi(nc.altitude, alt - max_drop_hs))
			elif nc.kind == TerrainCell.Kind.WATERFALL:
				# Concave-corner candidate: a previous walker placed a single-
				# face fall here. We can step onto it from a perpendicular
				# direction and upgrade it to a corner fall, IF the geometry
				# allows a clean shared basin. Conditions:
				#   - second face slot is still empty
				#   - our rise direction (-step) is perpendicular to the
				#     existing fall's rise direction (NE/NW pair)
				#   - drop into the basin is >= 2 half-steps
				#   - the cap wouldn't kick in (we can't change the existing
				#     basin altitude, so capped landings can't merge cleanly)
				if nc.fall_rise_dir_b != Vector2i.ZERO:
					continue
				var our_rise: Vector2i = -d
				var perpendicular: bool = (
					(nc.fall_rise_dir == DIR_NE and our_rise == DIR_NW)
					or (nc.fall_rise_dir == DIR_NW and our_rise == DIR_NE)
				)
				if not perpendicular:
					continue
				var basin_alt: int = nc.altitude - nc.drop_height
				if alt - basin_alt < 2:
					continue
				if alt - basin_alt > max_drop_hs:
					continue
				cands.append(nxy)
				cand_alts.append(basin_alt)

		if cands.is_empty():
			push_warning(
				"TerrainGenerator: river walker boxed in at %s (alt %d); aborting."
				% [pos, alt]
			)
			return

		var pick_idx: int = -1
		if force_first:
			# Forced direction must match a candidate; if it doesn't (e.g. the
			# branch's chosen neighbor is no longer GROUND), fall through to
			# the weighted pick so the branch still has a chance to step.
			for i in cands.size():
				if (cands[i] - pos) == first_step_dir:
					pick_idx = i
					break
			force_first = false

		if pick_idx < 0:
			# Weight each candidate by drop magnitude (lower neighbor = more
			# weight). south_bias breaks ties between SE and SW: positive
			# south_bias makes SW slightly preferred since it's "more south" in
			# iso (visually lower on screen than SE). +1 floor so same-tier
			# steps don't collapse to weight 0.
			var weights: Array[float] = []
			var total: float = 0.0
			for i in cands.size():
				var step_dir_w: Vector2i = cands[i] - pos
				var w: float = float(alt - cand_alts[i] + 1)
				if step_dir_w == DIR_SW:
					w += params.south_bias
				weights.append(w)
				total += w
			var roll: float = rng.randf() * total
			pick_idx = 0
			var acc: float = 0.0
			for i in weights.size():
				acc += weights[i]
				if roll <= acc:
					pick_idx = i
					break

		# Branch seed: with prob branch_chance, queue the OTHER candidate so a
		# tributary descends the unchosen fork after the primary walker
		# finishes. Only fires when both SE and SW are valid candidates and
		# branching is enabled.
		if allow_branching and params.river_branch_chance > 0.0 and cands.size() >= 2:
			if rng.randf() < params.river_branch_chance:
				var branch_idx: int = 1 - pick_idx
				var branch_dir: Vector2i = cands[branch_idx] - pos
				branch_seeds_out.append([pos, alt, branch_dir])

		var next_pos: Vector2i = cands[pick_idx]
		var next_alt: int = cand_alts[pick_idx]
		var step_dir: Vector2i = next_pos - pos

		# Only update water_flow on cells THIS walker created. Skip cells
		# that already belonged to another walker (lake outlet, primary path
		# a branch starts on, primary cell a branch lands on after a
		# waterfall jump) — overwriting their flow would repoint primary's
		# arrow toward the branch's continuation.
		if just_converted:
			here.water_flow = step_dir

		# Any altitude drop emits a waterfall at the LOWER cell. The
		# waterfall tile sits at the upper tier (alt) and records
		# drop_height in half-steps; the painter expands it into stacked
		# TOP/NONE*/BOTTOM tiles across multiple TileMapLayers.
		# - drop_height == 2 (1 cube) → FALL_*_BOTH single-tile waterfall
		# - drop_height >= 4         → multi-tier stacked column
		if alt - next_alt >= 2:
			var fall: TerrainCell = grid.at(next_pos.x, next_pos.y)
			# CORNER FALL UPGRADE: a previous walker placed a single-face
			# waterfall here. If our incoming rise direction is perpendicular
			# to its rise direction (one NE, one NW) AND the basins agree,
			# attach a second face to the existing fall and terminate — the
			# tributary has merged into the existing river at the lip. The
			# painter renders the shared tiers with FALL_NENW; tiers above
			# the shorter lip stay single-face.
			if fall.kind == TerrainCell.Kind.WATERFALL:
				var new_rise: Vector2i = - step_dir
				var perpendicular: bool = (
					(fall.fall_rise_dir == DIR_NE and new_rise == DIR_NW)
					or (fall.fall_rise_dir == DIR_NW and new_rise == DIR_NE)
				)
				var existing_basin: int = fall.altitude - fall.drop_height
				if (
					perpendicular
					and fall.fall_rise_dir_b == Vector2i.ZERO
					and next_alt == existing_basin
				):
					fall.fall_rise_dir_b = new_rise
					fall.drop_height_b = alt - existing_basin
					return
				# Else: basins disagree or the third walker arriving at an
				# already-corner fall. Fall through — preserves the legacy
				# silent-traverse behavior, which the harness has been green
				# under for the v1 generator.
			# Only place a waterfall if the neighbor is plain GROUND (don't
			# overwrite WATER with WATERFALL — would corrupt the lake).
			if fall.kind == TerrainCell.Kind.GROUND:
				# Peek at the cell BEYOND the waterfall (where the walker
				# would resume). If it's already part of another walker's
				# river, this is a merge — the basin must land at that
				# river's altitude, not the natural cap, otherwise the water
				# surface "jumps" between adjacent cells. See the
				# branch-merge artifacts at (15,32) / (26,34) in level1.
				var landing_pos: Vector2i = next_pos + step_dir
				var landing: TerrainCell = grid.at_or_null(landing_pos.x, landing_pos.y)
				var merge: bool = (
					landing != null
					and (landing.kind == TerrainCell.Kind.WATER
						or landing.kind == TerrainCell.Kind.WATERFALL)
				)
				if merge:
					var adjusted_drop: int = alt - landing.altitude
					if adjusted_drop >= 2:
						fall.kind = TerrainCell.Kind.WATERFALL
						fall.altitude = alt
						fall.fall_rise_dir = - step_dir
						fall.drop_height = adjusted_drop
						fall.water_flow = step_dir
						_try_corner_upgrade_perpendicular(grid, fall, next_pos)
						# CORNER FALL UPGRADE on the landing cell: when the
						# fall we just placed has its basin landing on
						# another waterfall's LIP (same altitude), the river
						# spills off two perpendicular cliff faces of the
						# landing cell — primary from its existing rise, plus
						# secondary from our step's rise. Both share the
						# landing cell's basin and have equal drops (lip_b ==
						# landing.altitude == primary lip).
						if (
							landing.kind == TerrainCell.Kind.WATERFALL
							and landing.fall_rise_dir_b == Vector2i.ZERO
						):
							var sec_rise: Vector2i = - step_dir
							var perpendicular: bool = (
								(landing.fall_rise_dir == DIR_NE and sec_rise == DIR_NW)
								or (landing.fall_rise_dir == DIR_NW and sec_rise == DIR_NE)
							)
							if perpendicular:
								landing.fall_rise_dir_b = sec_rise
								landing.drop_height_b = landing.drop_height
					# adjusted_drop < 2: landing river is at-or-above this
					# walker's tracked alt; no downward fall is geometrically
					# possible here. Leave next_pos as GROUND.
					return # branch terminates; merged into existing river
				fall.kind = TerrainCell.Kind.WATERFALL
				fall.altitude = alt
				fall.fall_rise_dir = - step_dir
				fall.drop_height = alt - next_alt
				fall.water_flow = step_dir
				_try_corner_upgrade_perpendicular(grid, fall, next_pos)
				# Walker resumes at the basin tier, one cell beyond the fall.
				# Off-disc landing terminates cleanly (next iteration reads
				# null/EMPTY at top of loop and returns).
				pos = landing_pos
				alt = next_alt
				continue

		pos = next_pos
		alt = next_alt


# CORNER FALL UPGRADE (reverse-order): a fall has just been placed fresh at
# `fall_pos`. If the perpendicular upper neighbor is already water (or a
# WATERFALL whose basin spills into our lip) at the lip altitude, the
# perpendicular face is already wet — upgrade `fall` to a concave-corner
# fall. Mirror of the GROUND→WATER conversion check; covers the case where
# the perpendicular water cell was placed by an earlier walker.
static func _try_corner_upgrade_perpendicular(
	grid: TerrainGrid,
	fall: TerrainCell,
	fall_pos: Vector2i,
) -> void:
	if fall.fall_rise_dir_b != Vector2i.ZERO:
		return
	var perp_dir: Vector2i = Vector2i.ZERO
	if fall.fall_rise_dir == DIR_NE:
		perp_dir = DIR_NW
	elif fall.fall_rise_dir == DIR_NW:
		perp_dir = DIR_NE
	if perp_dir == Vector2i.ZERO:
		return
	var ppos: Vector2i = fall_pos + perp_dir
	var pcell: TerrainCell = grid.at_or_null(ppos.x, ppos.y)
	if pcell == null:
		return
	# Symmetric corner: WATER at our lip altitude, or WATERFALL whose basin
	# matches our lip (chained falls upstream). Asymmetric perpendicular
	# drops are not handled here — the candidate-pick path covers those.
	var matches: bool = false
	if pcell.kind == TerrainCell.Kind.WATER and pcell.altitude == fall.altitude:
		matches = true
	elif (pcell.kind == TerrainCell.Kind.WATERFALL
			and (pcell.altitude - pcell.drop_height) == fall.altitude):
		matches = true
	if not matches:
		return
	fall.fall_rise_dir_b = perp_dir
	fall.drop_height_b = fall.drop_height


# Post-walker pass: detect WATER cells whose NE and/or NW face neighbor is
# WATER at a strictly higher altitude (drop >= 2). Such a cell sits at the
# base of an unmarked cliff — water on the upper face cascades down onto it
# but no walker emitted a fall, because (a) the basin water arrived via a
# different fork and (b) the walker that traced the upper water either chose
# the other south-step or saw this cell as already-WATER (rejected by the
# candidate filter). Convert these cells to WATERFALL so the painter renders
# the cascade. If both NE and NW upper are higher water, mark a NENW corner
# (asymmetric drops supported when lip altitudes differ).
static func _emit_perpendicular_falls(grid: TerrainGrid, max_drop_hs: int) -> void:
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.WATER:
				continue
			var ne: TerrainCell = grid.at_or_null(x + DIR_NE.x, y + DIR_NE.y)
			var nw: TerrainCell = grid.at_or_null(x + DIR_NW.x, y + DIR_NW.y)
			var ne_lip: int = -1
			var nw_lip: int = -1
			if ne != null and ne.kind == TerrainCell.Kind.WATER:
				var d: int = ne.altitude - c.altitude
				if d >= 2 and d <= max_drop_hs:
					ne_lip = ne.altitude
			if nw != null and nw.kind == TerrainCell.Kind.WATER:
				var d: int = nw.altitude - c.altitude
				if d >= 2 and d <= max_drop_hs:
					nw_lip = nw.altitude
			if ne_lip < 0 and nw_lip < 0:
				continue
			var basin_alt: int = c.altitude
			# Determine candidate primary direction (greater drop, NE wins ties)
			# upfront so we can validate the landing cell before mutating.
			var pre_primary_dir: Vector2i = DIR_NE if ne_lip >= nw_lip else DIR_NW
			# Landing cell (basin direction) must agree with our basin alt, or
			# be GROUND/EMPTY/off-grid. Otherwise emitting a fall here would
			# violate branch_merge_altitudes (the river graph would have a
			# fall whose basin tier doesn't match the next cell's alt).
			var lp: Vector2i = Vector2i(x, y) + (-pre_primary_dir)
			var land: TerrainCell = grid.at_or_null(lp.x, lp.y)
			if (
				land != null
				and land.kind != TerrainCell.Kind.EMPTY
				and land.kind != TerrainCell.Kind.GROUND
				and land.altitude != basin_alt
			):
				continue
			# Primary = greater drop (NE wins ties). Drop_a stored on
			# c.altitude (lip_a); drop_b derived from secondary lip.
			var primary_dir: Vector2i = Vector2i.ZERO
			var primary_lip: int = 0
			var secondary_dir: Vector2i = Vector2i.ZERO
			var secondary_lip: int = 0
			if ne_lip >= nw_lip:
				primary_dir = DIR_NE
				primary_lip = ne_lip
				if nw_lip >= 0:
					secondary_dir = DIR_NW
					secondary_lip = nw_lip
			else:
				primary_dir = DIR_NW
				primary_lip = nw_lip
				if ne_lip >= 0:
					secondary_dir = DIR_NE
					secondary_lip = ne_lip
			c.kind = TerrainCell.Kind.WATERFALL
			c.altitude = primary_lip
			c.fall_rise_dir = primary_dir
			c.drop_height = primary_lip - basin_alt
			c.water_flow = - primary_dir
			if secondary_dir != Vector2i.ZERO:
				c.fall_rise_dir_b = secondary_dir
				c.drop_height_b = secondary_lip - basin_alt


static func _find_lake_outlet(
	grid: TerrainGrid,
	params: TerrainGenerationParams,
	lake_center: Vector2i,
) -> Vector2i:
	# Outlet = the lake-edge cell whose lowest SE-or-SW GROUND neighbor is
	# the lowest in the lake. Only SE/SW are considered (the lake's southern
	# shore) so the walker enters terrain south of the lake — entering on
	# the north shore would put the walker against the lake on its SE/SW
	# face, where it has no south exit. Tie-break first by `x + y` (further
	# down the cone), then by distance to lake_center.
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
			for d in [DIR_SE, DIR_SW]:
				var n: Vector2i = Vector2i(x, y) + d
				var nc: TerrainCell = grid.at_or_null(n.x, n.y)
				if nc == null or nc.kind != TerrainCell.Kind.GROUND:
					continue
				if nc.altitude < min_neighbor_alt:
					min_neighbor_alt = nc.altitude
			if min_neighbor_alt == 0x7FFFFFFF:
				continue # no SE/SW GROUND neighbor
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


# True if the cell at (x, y) is on the open southern boundary — either the
# literal grid edge (y = height-1, or x = width-1, since DIR_SE = (1, 0)) or
# the SW/SE face neighbor is EMPTY (carved by the disc mask).
static func _is_south_boundary(grid: TerrainGrid, x: int, y: int) -> bool:
	if y >= grid.height - 1 or x >= grid.width - 1:
		return true
	var sw: TerrainCell = grid.at_or_null(x + DIR_SW.x, y + DIR_SW.y)
	if sw == null or sw.kind == TerrainCell.Kind.EMPTY:
		return true
	var se: TerrainCell = grid.at_or_null(x + DIR_SE.x, y + DIR_SE.y)
	if se == null or se.kind == TerrainCell.Kind.EMPTY:
		return true
	return false


static func _river_reaches_south(grid: TerrainGrid) -> bool:
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.WATER and c.kind != TerrainCell.Kind.WATERFALL:
				continue
			if _is_south_boundary(grid, x, y):
				return true
	return false


# ----------------------------------------------------------------------------
# Step 5: support water
# ----------------------------------------------------------------------------

# Ensures every WATER and WATERFALL cell has its 4 face GROUND neighbors
# at the appropriate altitude. Lower GROUND neighbors are raised; EMPTY
# neighbors (carved by the disc mask) are left alone so the river's exit
# at the disc edge stays open.
#
# A WATERFALL cell logically holds two water bodies stacked at the same
# (x, y) coord: the upper tile at `altitude` (where the water spills) and
# a basin at `altitude - drop_height` (where the water lands). The flanks
# of the upper tile are already supported by the heightfield + south-descent
# constraint, but the BASIN's face neighbors need banks at the basin
# altitude — that's the value we lift to. Lifting to the upper-tier value
# instead would bury the cliff face on the downstream side.
#
# Only the 4 face neighbors are lifted (the iso "sides" of the diamond);
# apex / corner neighbors are left alone so the bank stays one tile thick.
static func _support_water(grid: TerrainGrid) -> void:
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			var a: int
			match c.kind:
				TerrainCell.Kind.WATER:
					a = c.altitude
				TerrainCell.Kind.WATERFALL:
					a = c.altitude - c.drop_height
				_:
					continue
			for d in DiamondCompass.FACE_DIRS:
				_lift_neighbor(grid, x + d.x, y + d.y, a)


# Lifts the cell at (x, y) so its altitude >= min_alt. Only GROUND cells are
# touched — EMPTY (disc-carved) cells stay EMPTY so the river can exit, and
# WATER/WATERFALL cells are part of the river chain (their altitude is set
# by the walker).
static func _lift_neighbor(grid: TerrainGrid, x: int, y: int, min_alt: int) -> void:
	var c: TerrainCell = grid.at_or_null(x, y)
	if c == null:
		return
	if c.kind != TerrainCell.Kind.GROUND:
		return
	if c.altitude < min_alt:
		c.altitude = min_alt


# ----------------------------------------------------------------------------
# Step 6: biomes (banded)
# ----------------------------------------------------------------------------

# Picks each cell's biome by mapping its perturbed altitude into the band
# thresholds resolved from params.biome_bands. `biome_score` (= altitude +
# biome_noise * biome_noise_amplitude) drives both the band lookup and the
# painter's grass variant picker — same noise field for both, so a cell that
# noise-pushed into the dirt band visually carries the dirt biome AND a
# higher grass-density score (only relevant if it remains GRASS via design).
#
# Band thresholds are resolved once per generate() — cheap (~1 lookup per
# band per cell, typically 4 bands). Empty/zero-weight bands fall back to
# grass-only via params.resolve_biome_thresholds().
static func _assign_biomes(grid: TerrainGrid, params: TerrainGenerationParams, noise: FastNoiseLite) -> void:
	var thresholds: Array = params.resolve_biome_thresholds()
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.GROUND:
				continue
			var n: float = noise.get_noise_2d(x, y) * params.biome_noise_amplitude
			c.biome_score = float(c.altitude) + n
			c.biome = _biome_from_thresholds(c.biome_score, thresholds)


# Returns the biome of the first band whose top exceeds `score`. The last
# band's top is +INF so this always finds a match; thresholds is guaranteed
# non-empty by `resolve_biome_thresholds`.
static func _biome_from_thresholds(score: float, thresholds: Array) -> int:
	for entry in thresholds:
		if score < entry[0]:
			return entry[1]
	return thresholds.back()[1]


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
