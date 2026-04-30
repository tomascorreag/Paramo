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
	_support_water(grid)
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
	var grad_factor: float = maxf(0.05, 1.0 - params.disc_radius_frac)
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
					continue  # disc mask carved this cell out
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
	var frontier: Array = []  # entries: [Vector2i, dist]
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
		return  # no lake on this seed

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
	var to_fill: Array = []  # entries: [Vector2i, alt:int]
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			# Only flip cells along the silhouette boundary — interior GROUND
			# and far-from-disc EMPTY don't need analysis.
			if c.kind != TerrainCell.Kind.GROUND and c.kind != TerrainCell.Kind.EMPTY:
				continue
			var ground_count: int = 0
			var total: int = 0
			var alt_samples: Array[int] = []  # only collected when this is an EMPTY cell that might fill
			for o in offsets:
				var nx: int = x + o.x
				var ny: int = y + o.y
				total += 1
				var nc: TerrainCell = grid.at_or_null(nx, ny)
				if nc == null:
					continue  # off-grid counts as not-GROUND
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
			else:  # EMPTY
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
	var updates: Array = []  # entries: [Vector2i, new_alt:int]
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

# Single-cell-wide gravity walker from the lake outlet to the open south
# boundary. At each step:
#   - filter face neighbors to GROUND or WATER (lake-merge OK)
#   - weight by altitude (lower = higher weight) and south_bias (DIR_SE/DIR_SW
#     get an additive bonus)
#   - if the chosen step drops more than 1 cube, mark this cell WATERFALL with
#     drop_height = altitude difference; otherwise mark it WATER
#   - record water_flow as the step direction
# Stops on EMPTY-adjacent or grid edge. No branching, no widening.
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
	var pos: Vector2i = outlet
	var alt: int = grid.at(outlet.x, outlet.y).altitude
	var steps: int = 0

	while steps < _MAX_RIVER_STEPS:
		steps += 1
		var here: TerrainCell = grid.at_or_null(pos.x, pos.y)
		if here == null or here.kind == TerrainCell.Kind.EMPTY:
			return

		# Only convert GROUND to WATER — never overwrite WATER (lake) or
		# WATERFALL once placed.
		if here.kind == TerrainCell.Kind.GROUND:
			here.kind = TerrainCell.Kind.WATER
			here.altitude = alt

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
			if nc.kind != TerrainCell.Kind.GROUND:
				continue
			cands.append(nxy)
			cand_alts.append(maxi(nc.altitude, alt - max_drop_hs))

		if cands.is_empty():
			push_warning(
				"TerrainGenerator: river walker boxed in at %s (alt %d); aborting."
				% [pos, alt]
			)
			return

		# Weight each candidate by drop magnitude (lower neighbor = more
		# weight). south_bias breaks ties between SE and SW: positive
		# south_bias makes SW slightly preferred since it's "more south" in
		# iso (visually lower on screen than SE). +1 floor so same-tier
		# steps don't collapse to weight 0.
		var weights: Array[float] = []
		var total: float = 0.0
		for i in cands.size():
			var step_dir: Vector2i = cands[i] - pos
			var w: float = float(alt - cand_alts[i] + 1)
			if step_dir == DIR_SW:
				w += params.south_bias
			weights.append(w)
			total += w

		var roll: float = rng.randf() * total
		var pick_idx: int = 0
		var acc: float = 0.0
		for i in weights.size():
			acc += weights[i]
			if roll <= acc:
				pick_idx = i
				break

		var next_pos: Vector2i = cands[pick_idx]
		var next_alt: int = cand_alts[pick_idx]
		var step_dir: Vector2i = next_pos - pos

		here.water_flow = step_dir

		# Any altitude drop emits a waterfall at the LOWER cell. The
		# waterfall tile sits at the upper tier (alt) and records
		# drop_height in half-steps; the painter expands it into stacked
		# TOP/NONE*/BOTTOM tiles across multiple TileMapLayers.
		# - drop_height == 2 (1 cube) → FALL_*_BOTH single-tile waterfall
		# - drop_height >= 4         → multi-tier stacked column
		if alt - next_alt >= 2:
			var fall: TerrainCell = grid.at(next_pos.x, next_pos.y)
			# Only place a waterfall if the neighbor is plain GROUND (don't
			# overwrite WATER with WATERFALL — would corrupt the lake).
			if fall.kind == TerrainCell.Kind.GROUND:
				fall.kind = TerrainCell.Kind.WATERFALL
				fall.altitude = alt
				fall.fall_rise_dir = -step_dir
				fall.drop_height = alt - next_alt
				fall.water_flow = step_dir
				# Walker resumes at the basin tier, one cell beyond the fall.
				pos = next_pos + step_dir
				alt = next_alt
				continue

		pos = next_pos
		alt = next_alt


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
				continue  # no SE/SW GROUND neighbor
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
# Step 6: biomes (grass-only)
# ----------------------------------------------------------------------------

# `_biome_for` returns GRASS unconditionally — DIRT/ROCK/SNOW bands are gone.
# `biome_score` is still computed (altitude + biome_noise) because the
# painter's grass variant picker reads it to drive its gaussian over
# preferred_density per variant. The spatial correlation of the biome noise
# is what produces the "clumping" effect on grass variant selection.
static func _assign_biomes(grid: TerrainGrid, params: TerrainGenerationParams, noise: FastNoiseLite) -> void:
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.GROUND:
				continue
			var n: float = noise.get_noise_2d(x, y) * params.biome_noise_amplitude
			c.biome_score = float(c.altitude) + n
			c.biome = TerrainCell.Biome.GRASS


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
