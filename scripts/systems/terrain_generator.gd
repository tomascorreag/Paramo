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
#   1. Heightfield  (Y-dominant ramp: north high, south low; mild east/west
#                   taper; Perlin noise; snapped to even half-steps)
#   2. Carve summit lake  (~5x5 disc flush against north edge)
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


# --- Public parameters (passed in via Params) -------------------------------

class Params extends RefCounted:
	var seed: int = 0
	var width: int = 32
	var height: int = 48
	var top_altitude: int = 16            # half-steps; must be even
	# Subtractive penalty applied to altitude near the east/west edges.
	# 0 = uniform-width ridge; ~3 = mild taper visible at the edges; large
	# values can clip cells to altitude 0 and create empty tiles at the edges.
	var x_falloff_strength: float = 3.0
	# Additive weight given to a south-going step (dy > 0) when the river has
	# multiple downhill candidates. Higher = more "always goes south".
	var south_bias: float = 0.5
	var height_noise_frequency: float = 0.04
	var height_noise_amplitude: float = 3.0   # half-steps of perturbation
	var biome_noise_frequency: float = 0.06
	var biome_noise_amplitude: float = 2.0    # altitude perturbation for bands
	var lake_radius: float = 2.6          # gives ~5x5 disc
	# Multiplier on r^2 for the additive noise jitter when carving the lake.
	# Larger values produce more irregular shorelines.
	var lake_jitter_strength: float = 0.5
	# Per-seed random aspect-ratio range for the lake disc. Each generation
	# picks aspect_x and aspect_y uniformly from [min, max], stretching the
	# lake along one axis.
	var lake_aspect_min: float = 0.7
	var lake_aspect_max: float = 1.4
	# Width (in cells) of the river segment leaving the lake. May shrink at
	# branch points down to 1.
	var initial_river_width: int = 2
	var branch_chance: float = 0.25       # split probability per waterfall
	var slope_chance: float = 0.35        # extra slopes per uphill-edge cell
	var max_river_steps: int = 4096       # safety cap on trace walks
	# Cap on consecutive non-downhill steps a stalled walker may take while
	# pushing south to reach the south edge. Aborts the walker if exceeded.
	var max_stall_steps: int = 8

	static func make_default() -> Params:
		return Params.new()


# Compass directions used throughout (4-axis diamond).
const DIR_NE: Vector2i = Vector2i( 0, -1)
const DIR_NW: Vector2i = Vector2i(-1,  0)
const DIR_SE: Vector2i = Vector2i( 1,  0)
const DIR_SW: Vector2i = Vector2i( 0,  1)
const _DIRS: Array[Vector2i] = [DIR_NE, DIR_NW, DIR_SE, DIR_SW]

# Apex (diamond-corner) directions — the cells visually straight up / right /
# down / left of a tile, used to detect concave-shore (inner-corner) cases.
const DIR_APEX_N: Vector2i = Vector2i(-1, -1)
const DIR_APEX_E: Vector2i = Vector2i( 1, -1)
const DIR_APEX_S: Vector2i = Vector2i( 1,  1)
const DIR_APEX_W: Vector2i = Vector2i(-1,  1)
const _APEX_DIRS: Array[Vector2i] = [DIR_APEX_N, DIR_APEX_E, DIR_APEX_S, DIR_APEX_W]

# Shore-mask bit positions (must align with TerrainCell.shore_mask docs).
# Low nibble = face neighbors; high nibble = apex (diagonal) neighbors.
const _BIT_NE: int = 1
const _BIT_NW: int = 2
const _BIT_SE: int = 4
const _BIT_SW: int = 8
const _BIT_APEX_N: int = 16
const _BIT_APEX_E: int = 32
const _BIT_APEX_S: int = 64
const _BIT_APEX_W: int = 128
const _FACE_MASK: int = _BIT_NE | _BIT_NW | _BIT_SE | _BIT_SW

# Bit for each direction, in the same order as _DIRS.
const _DIR_BITS: Array[int] = [_BIT_NE, _BIT_NW, _BIT_SE, _BIT_SW]
const _APEX_BITS: Array[int] = [_BIT_APEX_N, _BIT_APEX_E, _BIT_APEX_S, _BIT_APEX_W]


# ----------------------------------------------------------------------------
# Public entry
# ----------------------------------------------------------------------------

static func generate(params: Params) -> TerrainGrid:
	var grid := TerrainGrid.new(params.width, params.height)
	var rng := RandomNumberGenerator.new()
	rng.seed = params.seed

	var height_noise := _make_noise(params.seed, params.height_noise_frequency)
	var biome_noise := _make_noise(params.seed ^ 0x9E37, params.biome_noise_frequency)

	_fill_heightfield(grid, params, height_noise)
	var peak_center: Vector2i = _carve_lake(grid, params, rng)
	# Smooth jumps before tracing so the river walker sees a heightfield with
	# at-most-one-tier altitude transitions. Carving the lake at top_altitude
	# can leave a 4-step cliff straight off the lake (no alt 14 band where it
	# was absorbed); without smoothing, the trace can't place a waterfall
	# there because down_tier requires neighbor.altitude == alt - 2.
	_smooth_altitude_jumps(grid)
	if peak_center.x >= 0:
		_trace_rivers(grid, params, rng, peak_center)
	_widen_rivers(grid)
	_enforce_river_surroundings(grid)
	# Surroundings may have lifted lateral cells to a river's altitude, which
	# can re-introduce >2 jumps to cells one ring further out. Smooth again
	# so slope placement works on a clean heightfield.
	_smooth_altitude_jumps(grid)
	_place_slopes(grid, params, rng)
	_assign_biomes(grid, params, biome_noise)
	_assign_water_flow(grid)
	_assign_shore_masks(grid)

	return grid


# ----------------------------------------------------------------------------
# Step 1: heightfield
# ----------------------------------------------------------------------------

static func _fill_heightfield(grid: TerrainGrid, params: Params, noise: FastNoiseLite) -> void:
	# Y-dominant ramp: altitude falls linearly from `top_altitude` at the north
	# edge (y=0) to 0 at the south edge (y=height-1). A small subtractive
	# x-falloff bends the east/west edges down so the ridge reads as a ridge,
	# not a slab. Perlin noise modulates +/- a few half-steps for organic shape.
	#
	# Every cell becomes GROUND — no EMPTY clipping. The user's "solid ridge"
	# shape requires the entire footprint to be walkable so the river can run
	# from north lake to south edge without hitting empty barriers; the lowest
	# altitude tier is 0 (still GROUND, just flat at sea level).
	var cx: float = grid.width * 0.5
	var x_half_span: float = max(1.0, cx)
	var y_span: float = max(1.0, float(grid.height - 1))
	for y in grid.height:
		var y_norm: float = float(y) / y_span
		var ridge_alt: float = float(params.top_altitude) * (1.0 - y_norm)
		for x in grid.width:
			var x_norm: float = absf(float(x) - cx) / x_half_span
			var x_pen: float = params.x_falloff_strength * x_norm
			var n: float = noise.get_noise_2d(x, y) * params.height_noise_amplitude
			var raw: float = ridge_alt - x_pen + n
			var snapped: int = _snap_even(int(round(raw)), 0, params.top_altitude)
			var cell: TerrainCell = grid.at(x, y)
			cell.kind = TerrainCell.Kind.GROUND
			cell.altitude = snapped
			cell.ground_shape = TerrainCell.GroundShape.FULL_CUBE


static func _snap_even(v: int, lo: int, hi: int) -> int:
	v = clampi(v, lo, hi)
	if v % 2 != 0:
		v -= 1
	return clampi(v, lo, hi)


static func _make_noise(seed: int, frequency: float) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = seed
	n.frequency = frequency
	n.noise_type = FastNoiseLite.TYPE_PERLIN
	return n


# ----------------------------------------------------------------------------
# Step 2: carve summit lake
# ----------------------------------------------------------------------------

# Carves a randomly-shaped lake at the north edge of the map. Centered on
# the middle column with a small inset so the lake fits inside the grid.
# Per-seed aspect ratio (lake_aspect_min..max along each axis) and large noise
# jitter produce visibly different silhouettes from one generation to the
# next — round, oblong, tilted, etc. Lake cells are forced to `top_altitude`
# regardless of the heightfield underneath.
#
# Returns the lake center cell (always inside the grid for any sensible width).
static func _carve_lake(grid: TerrainGrid, params: Params, rng: RandomNumberGenerator) -> Vector2i:
	var inset: int = int(ceil(params.lake_radius)) + 1
	var center := Vector2i(grid.width / 2, mini(inset, grid.height - 1))

	var r2: float = params.lake_radius * params.lake_radius
	var jitter_amp: float = params.lake_jitter_strength * r2
	var aspect_x: float = rng.randf_range(params.lake_aspect_min, params.lake_aspect_max)
	var aspect_y: float = rng.randf_range(params.lake_aspect_min, params.lake_aspect_max)
	var n := _make_noise(params.seed ^ 0xBEEF, 0.4)
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
	params: Params,
	rng: RandomNumberGenerator,
	lake_center: Vector2i,
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

		# Choose downhill neighbors. NE (the only -Y diamond step) is forbidden:
		# the walker must never head back north, otherwise it can spiral. SE
		# and NW are 0-Y steps — fine for lateral wandering. SW is the only
		# +Y step and gets the south_bias weight.
		#
		# Down-tier candidates that would form an indented (concave) corner
		# are filtered out: a single lower cell with upper plateaus on BOTH
		# its NE and NW sides can't display two waterfall tiles at once. We
		# only have the painted NE-rise and NW-rise variants, no combined
		# corner tile, so the river must drop somewhere else.
		var same_tier: Array[Vector2i] = []
		var down_tier: Array[Vector2i] = []
		for d in _DIRS:
			if d == DIR_NE:
				continue
			# Don't immediately reverse direction (prevents tight U-turns on
			# lateral wandering).
			if last_dir != Vector2i.ZERO and d == -last_dir:
				continue
			var n: Vector2i = cell_xy + d
			var nc: TerrainCell = grid.at_or_null(n.x, n.y)
			if nc == null:
				continue
			if nc.kind == TerrainCell.Kind.WATER or nc.kind == TerrainCell.Kind.WATERFALL:
				continue
			if nc.kind != TerrainCell.Kind.GROUND:
				continue
			if nc.altitude == alt:
				same_tier.append(n)
			elif nc.altitude == alt - 2:
				# The waterfall atlas only paints NE-rise and NW-rise variants.
				# A drop in the NW direction would need an SE-rise waterfall
				# (rise = -dir = SE), which the painter falls back to flat
				# water for — so the cliff visual disappears. Skip those.
				var rise: Vector2i = -d
				if rise != DIR_NE and rise != DIR_NW:
					continue
				if _would_indent_corner(grid, n, rise, alt):
					continue
				down_tier.append(n)

		# Prefer dropping to a lower tier; otherwise meander on the same tier.
		if not down_tier.is_empty():
			var drop_dir_idx: int = _pick_south_biased(down_tier, cell_xy, params.south_bias, rng)
			var fall_to: Vector2i = down_tier[drop_dir_idx]
			var fall_dir: Vector2i = fall_to - cell_xy
			# Record this cell's flow toward the cliff edge.
			here.water_flow = fall_dir
			# WATERFALL cell sits at the LOWER neighbor's grid coord but is
			# stored on the UPPER tier (`alt`, not `alt - 2`). The painter
			# resolves layer-by-altitude, so this places the falling-water
			# graphic on the upper layer — visually it occupies the cliff face
			# of the upper cube rather than the floor of the lower tier.
			var fall_cell: TerrainCell = grid.at(fall_to.x, fall_to.y)
			fall_cell.kind = TerrainCell.Kind.WATERFALL
			fall_cell.altitude = alt
			fall_cell.fall_rise_dir = -fall_dir   # rise dir = back toward the higher cliff
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
			# Continue river one step beyond the waterfall, at the lower tier.
			var beyond: Vector2i = fall_to + fall_dir
			walkers.append([beyond, alt - 2, fall_dir, 0, main_width])
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
			# Same-tier wandering counts as "non-progressive" if it doesn't move
			# south; bump stall_count if so. (It's still less drastic than a
			# true stall step into uphill terrain.)
			var new_stall: int = stall_count + 1 if ndir.y <= 0 else 0
			if new_stall > params.max_stall_steps:
				push_warning(
					"TerrainGenerator: river walker stalled near %s (alt %d); aborting branch."
					% [cell_xy, alt]
				)
				continue
			walkers.append([nx, alt, ndir, new_stall, width])
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
			fall_cell.river_width = width
			var beyond: Vector2i = stalled.cell + stalled.dir
			walkers.append([beyond, stalled.alt, stalled.dir, stall_next, width])
			continue
		here.water_flow = stalled.dir
		walkers.append([stalled.cell, stalled.alt, stalled.dir, stall_next, width])


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
	var total: float = 0.0
	var weights: Array[float] = []
	weights.resize(cands.size())
	for i in cands.size():
		var dy: int = cands[i].y - from.y
		var w: float = 1.0 + (south_bias if dy > 0 else 0.0)
		weights[i] = w
		total += w
	var roll: float = rng.randf() * total
	var acc: float = 0.0
	for i in cands.size():
		acc += weights[i]
		if roll <= acc:
			return i
	return cands.size() - 1


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
		# Adopt the neighbor's altitude so the river sits flush with the cell.
		out.cell = n
		out.alt = nc.altitude
		out.dir = d
		return out
	return out


static func _find_lake_outlet(
	grid: TerrainGrid,
	params: Params,
	lake_center: Vector2i,
) -> Vector2i:
	# The lake sits at the north edge and the heightfield falls away to the
	# south, so the natural outflow is the southmost lake cell that has a
	# non-lake GROUND neighbor. Tiebreak by closeness to the lake's center
	# column for visual stability.
	# Falls back to the legacy "lowest-neighbor" scoring if no GROUND neighbor
	# exists south of the lake (only happens on degenerate / very small maps).
	var best_y: int = -1
	var best: Vector2i = Vector2i(-1, -1)
	var best_dx: int = 0x7FFFFFFF
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.WATER:
				continue
			var has_land_neighbor := false
			for d in _DIRS:
				var n: Vector2i = Vector2i(x, y) + d
				var nc: TerrainCell = grid.at_or_null(n.x, n.y)
				if nc != null and nc.kind == TerrainCell.Kind.GROUND \
						and nc.altitude < params.top_altitude:
					has_land_neighbor = true
					break
			if not has_land_neighbor:
				continue
			var dx: int = absi(x - lake_center.x)
			if y > best_y or (y == best_y and dx < best_dx):
				best_y = y
				best_dx = dx
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
	params: Params,
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
		if uphill_dirs.is_empty():
			continue
		if rng.randf() >= params.slope_chance:
			continue
		var d: Vector2i = uphill_dirs[rng.randi_range(0, uphill_dirs.size() - 1)]
		here.ground_shape = _slope_shape_for(d)

	# Second pass: per upper-plateau, ensure at least one tier-T slope leads
	# to it. A "plateau" here is a connected component of cells with the same
	# altitude > 0; we don't need exact components — guaranteeing per-cell
	# coverage that at least one neighbor is a valid slope is sufficient and
	# much simpler. So: for every cell with altitude > 0, if no tier-(alt-2)
	# neighbor is already a slope rising into us, force one.
	for y in grid.height:
		for x in grid.width:
			var top: TerrainCell = grid.at(x, y)
			if top.kind != TerrainCell.Kind.GROUND or top.altitude == 0:
				continue
			if _has_incoming_slope(grid, Vector2i(x, y), top.altitude):
				continue
			# Find a tier-(alt-2) neighbor in any direction we can convert.
			# Candidate dirs: directions FROM the lower neighbor TO us (i.e.
			# the slope rises in -d direction relative to the lower cell).
			for d in _DIRS:
				var lower: Vector2i = Vector2i(x, y) + d
				var lc: TerrainCell = grid.at_or_null(lower.x, lower.y)
				if lc == null or lc.kind != TerrainCell.Kind.GROUND:
					continue
				if lc.altitude != top.altitude - 2:
					continue
				if lc.ground_shape != TerrainCell.GroundShape.FULL_CUBE:
					continue
				lc.ground_shape = _slope_shape_for(-d)
				break


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

# Ensures no GROUND cell has a neighbor more than 2 half-steps higher. Any
# violation raises the offending cell to (max_neighbor_altitude - 2). Only
# raises (never lowers); only mutates GROUND cells, leaving river/lake
# altitudes invariant. Iterates to a fixed point so cascading raises
# propagate outward — e.g. a lake at alt 16 next to ground at alt 12 first
# raises that ground to 14, and a subsequent pass leaves cells at 12 alone
# because their highest neighbor is now 14 (jump = 2, allowed).
#
# Runs after `_carve_lake` (so the trace sees a smooth field and can place
# waterfalls at lake exits) and again after `_enforce_river_surroundings`
# (which lifts banks and can re-introduce jumps a tier further out).
static func _smooth_altitude_jumps(grid: TerrainGrid) -> void:
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
				if max_alt > c.altitude + 2:
					c.altitude = max_alt - 2
					changed = true


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
	# Snapshot centerline (kind, altitude, flow, rise, width) before mutating
	# so the widened cells we add this pass don't get re-widened in turn.
	var centerlines: Array = []
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.river_width <= 1:
				continue
			if c.kind != TerrainCell.Kind.WATER and c.kind != TerrainCell.Kind.WATERFALL:
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
			nc.fall_rise_dir = c.fall_rise_dir
			nc.river_width = c.river_width


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
static func _assign_biomes(grid: TerrainGrid, params: Params, noise: FastNoiseLite) -> void:
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.GROUND:
				continue
			var n: float = noise.get_noise_2d(x, y) * params.biome_noise_amplitude
			var perturbed: float = float(c.altitude) + n
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
# recorded as the river is laid down. This pass is a safety net for any
# water cell that ended up with ZERO flow but actually borders a waterfall
# (e.g. cells the trace visited but couldn't progress from). Lake-interior
# cells deliberately stay at ZERO (still water).
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
