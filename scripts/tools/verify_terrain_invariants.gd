@tool
extends SceneTree

# ============================================================================
# verify_terrain_invariants
# ============================================================================
#
# Generates many terrains across a matrix of (scenario × seed) and runs a
# battery of invariant checks on each grid. Reports per-scenario, per-check
# failure counts. Exit code 1 on any failure (CI-friendly).
#
# Adding a new check:
#   1. Write a static func `_check_<name>(grid, params) -> Array[String]`
#      returning a list of human-readable failure messages (empty = pass).
#   2. Add `{"name": "<name>", "fn": _check_<name>}` to CHECKS.
#
# Adding a new scenario:
#   1. Append `{"name": "<name>", "overrides": {<param>: <value>, ...}}`
#      to SCENARIOS. Keys must match TerrainGenerationParams field names.
#
# Usage:
#   godot --headless --path . --script res://scripts/tools/verify_terrain_invariants.gd
#   godot --headless --path . --script res://scripts/tools/verify_terrain_invariants.gd -- --seeds 50 --verbose
#   godot --headless --path . --script res://scripts/tools/verify_terrain_invariants.gd -- --scenario branch_heavy
# ============================================================================


# ----------------------------------------------------------------------------
# Scenarios — each runs SEEDS_PER_SCENARIO seeds with the listed overrides
# stacked on top of TerrainGenerationParams defaults. Empty overrides = bare
# defaults. Designer adds presets here as new map types or stress modes
# emerge.
# ----------------------------------------------------------------------------

const SCENARIOS: Array = [
	{"name": "defaults",          "overrides": {}},

	# Mirror of scenes/maps/level1.tscn — keep in sync when level1 retunes.
	{"name": "level1",            "overrides": {
		"top_altitude": 32, "noise_frequency": 0.25, "noise_strength": 2.5,
		"weight_n": 0.75, "weight_ne": 0.4, "weight_nw": 0.4,
		"disc_radius_frac": 0.5, "disc_edge_frequency": 0.04,
		"lake_radius": 4.5, "lake_jitter_strength": 1.0,
		"lake_aspect_min": 0.75, "lake_aspect_max": 1.5,
		"lake_apex_window_frac": 0.1, "lake_depth_hs": 6,
		"lake_apron_radius": 6, "lake_apron_falloff_hs": 4,
		"south_bias": 0.75, "max_drop_cubes": 6, "river_branch_chance": 0.25,
		"silhouette_round_radius": 1, "silhouette_round_stickiness": 0.1,
		"altitude_round_radius": 3, "corner_round_passes": 3,
	}},

	# River walker stress.
	{"name": "branch_zero",       "overrides": {"river_branch_chance": 0.0}},
	{"name": "branch_heavy",      "overrides": {"river_branch_chance": 0.4}},
	{"name": "max_drop_low",      "overrides": {"max_drop_cubes": 1}},
	{"name": "max_drop_high",     "overrides": {"max_drop_cubes": 8}},
	{"name": "south_bias_zero",   "overrides": {"south_bias": 0.0}},
	{"name": "south_bias_high",   "overrides": {"south_bias": 4.0}},

	# Heightfield stress.
	{"name": "noise_zero",        "overrides": {"noise_strength": 0.0}},
	{"name": "noise_extreme",     "overrides": {"noise_strength": 2.5,
		"noise_frequency": 0.2}},
	{"name": "tall",              "overrides": {"top_altitude": 32}},

	# Disc + lake stress.
	{"name": "disc_small",        "overrides": {"disc_radius_frac": 0.3}},
	{"name": "disc_large",        "overrides": {"disc_radius_frac": 0.9}},
	{"name": "lake_huge",         "overrides": {"lake_radius": 8.0}},
	{"name": "lake_tiny",         "overrides": {"lake_radius": 1.0,
		"lake_apron_radius": 1}},
	{"name": "lake_deep",         "overrides": {"lake_depth_hs": 12,
		"top_altitude": 24}},

	# Corner rounding stress.
	{"name": "round_off",         "overrides": {"corner_round_passes": 0}},
	{"name": "round_aggressive",  "overrides": {"corner_round_passes": 3,
		"silhouette_round_radius": 4, "altitude_round_radius": 4,
		"altitude_round_strength": 1.0}},

	# Combined worst-case.
	{"name": "kitchen_sink",      "overrides": {
		"top_altitude": 32, "noise_strength": 2.0, "noise_frequency": 0.2,
		"max_drop_cubes": 8, "river_branch_chance": 0.4, "south_bias": 2.0,
		"lake_radius": 6.0, "lake_depth_hs": 8,
		"corner_round_passes": 3, "silhouette_round_radius": 3,
	}},
]


# ----------------------------------------------------------------------------
# Checks — each invariant is a static func returning Array[String] of failure
# messages. The harness aggregates per-scenario × per-check counts.
# ----------------------------------------------------------------------------

# Member array (Callables to static methods can't be const).
var CHECKS: Array = [
	{"name": "grid_dimensions", "fn": _check_grid_dimensions},
	{"name": "river_reaches_south", "fn": _check_river_reaches_south},
	{"name": "branch_merge_altitudes", "fn": _check_branch_merge_altitudes},
	{"name": "waterfall_fields", "fn": _check_waterfall_fields},
	{"name": "corner_fall_consistency", "fn": _check_corner_fall_consistency},
	{"name": "altitude_range_even", "fn": _check_altitude_range_even},
	{"name": "lake_altitude_consistent", "fn": _check_lake_altitude_consistent},
	{"name": "shore_mask_set_on_water", "fn": _check_shore_mask_on_water},
	{"name": "no_islands", "fn": _check_no_islands},
]


# Sanity: the generator returns a grid sized exactly as requested. A mismatch
# would indicate a regression in TerrainGrid construction.
static func _check_grid_dimensions(grid: TerrainGrid, params: TerrainGenerationParams) -> Array:
	if grid.width != params.width or grid.height != params.height:
		return ["grid is %dx%d but params asked for %dx%d" % [
			grid.width, grid.height, params.width, params.height,
		]]
	return []


# Every grid must have at least one WATER/WATERFALL cell on the south
# boundary (literal grid edge or adjacent to EMPTY).
static func _check_river_reaches_south(grid: TerrainGrid, _params: TerrainGenerationParams) -> Array:
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.WATER and c.kind != TerrainCell.Kind.WATERFALL:
				continue
			if y >= grid.height - 1 or x >= grid.width - 1:
				return []
			var sw: TerrainCell = grid.at(x, y + 1)
			var se: TerrainCell = grid.at(x + 1, y)
			if sw.kind == TerrainCell.Kind.EMPTY or se.kind == TerrainCell.Kind.EMPTY:
				return []
	return ["no river cell touches the south boundary"]


# For every WATERFALL, the cell the walker landed on (pos + (-fall_rise_dir))
# must be GROUND, EMPTY/off-disc, or a river cell whose surface contains our
# basin altitude. The river surface at landing is:
#   - WATER:     landing.altitude
#   - WATERFALL: landing.altitude (lip — chained fall: c.basin → landing.lip),
#                OR landing.altitude - landing.drop_height (basin — parallel
#                falls dropping into a shared basin pool)
# Mismatches were the root cause of the (18,24) artifacts in level1.
static func _check_branch_merge_altitudes(grid: TerrainGrid, _params: TerrainGenerationParams) -> Array:
	var fails: Array = []
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.WATERFALL:
				continue
			var step_dir: Vector2i = -c.fall_rise_dir
			var lp: Vector2i = Vector2i(x, y) + step_dir
			var l: TerrainCell = grid.at_or_null(lp.x, lp.y)
			if l == null or l.kind == TerrainCell.Kind.GROUND or l.kind == TerrainCell.Kind.EMPTY:
				continue
			var basin: int = c.altitude - c.drop_height
			var ok: bool = l.altitude == basin
			if not ok and l.kind == TerrainCell.Kind.WATERFALL:
				ok = (l.altitude - l.drop_height) == basin
			if not ok:
				fails.append(
					"WF (%d,%d) alt=%d basin=%d → landing (%d,%d) alt=%d Δ=%d"
					% [x, y, c.altitude, basin, lp.x, lp.y, l.altitude, l.altitude - basin]
				)
	return fails


# WATERFALL fields must be self-consistent and match what the painter expects.
# Painter only ships FALL_NE_* and FALL_NW_* atlas variants — SE/SW rises
# would render as flat water (`_fall_kind_for_rise_and_position` returns "").
static func _check_waterfall_fields(grid: TerrainGrid, _params: TerrainGenerationParams) -> Array:
	var fails: Array = []
	var allowed_rise: Array[Vector2i] = [DiamondCompass.DIR_NE, DiamondCompass.DIR_NW]
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.WATERFALL:
				continue
			if c.drop_height < 2 or c.drop_height % 2 != 0:
				fails.append("WF (%d,%d) invalid drop_height=%d" % [x, y, c.drop_height])
			if not allowed_rise.has(c.fall_rise_dir):
				fails.append("WF (%d,%d) unsupported fall_rise_dir=%s (painter only paints NE/NW)" % [
					x, y, str(c.fall_rise_dir),
				])
			if c.water_flow != -c.fall_rise_dir:
				fails.append("WF (%d,%d) flow %s != -rise %s" % [
					x, y, str(c.water_flow), str(-c.fall_rise_dir),
				])
			if c.altitude - c.drop_height < 0:
				fails.append("WF (%d,%d) basin alt=%d < 0" % [
					x, y, c.altitude - c.drop_height,
				])
	return fails


# Validates concave-corner waterfall metadata. A WATERFALL cell with
# fall_rise_dir_b set must:
#   - have a perpendicular rise pair (NE+NW only — matches FALL_NENW tile)
#   - have an even drop_height_b >= 2
#   - have both upper neighbors at their respective lip altitudes
#     (lip_a = altitude, lip_b = altitude - drop_height + drop_height_b)
static func _check_corner_fall_consistency(grid: TerrainGrid, _params: TerrainGenerationParams) -> Array:
	var fails: Array = []
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.WATERFALL:
				continue
			if c.fall_rise_dir_b == Vector2i.ZERO:
				continue
			var perpendicular: bool = (
				(c.fall_rise_dir == DiamondCompass.DIR_NE
					and c.fall_rise_dir_b == DiamondCompass.DIR_NW)
				or (c.fall_rise_dir == DiamondCompass.DIR_NW
					and c.fall_rise_dir_b == DiamondCompass.DIR_NE)
			)
			if not perpendicular:
				fails.append("WF (%d,%d) corner pair %s+%s not NE+NW" % [
					x, y, str(c.fall_rise_dir), str(c.fall_rise_dir_b),
				])
			if c.drop_height_b < 2 or c.drop_height_b % 2 != 0:
				fails.append("WF (%d,%d) invalid drop_height_b=%d" % [
					x, y, c.drop_height_b,
				])
			var basin: int = c.altitude - c.drop_height
			var ua: TerrainCell = grid.at_or_null(x + c.fall_rise_dir.x, y + c.fall_rise_dir.y)
			if not _upper_source_at(ua, c.altitude):
				var ua_alt: int = ua.altitude if ua != null else -1
				fails.append("WF (%d,%d) upper-A source alt=%d incompatible with lip_a=%d" % [
					x, y, ua_alt, c.altitude,
				])
			var lip_b: int = basin + c.drop_height_b
			var ub: TerrainCell = grid.at_or_null(x + c.fall_rise_dir_b.x, y + c.fall_rise_dir_b.y)
			if not _upper_source_at(ub, lip_b):
				var ub_alt: int = ub.altitude if ub != null else -1
				fails.append("WF (%d,%d) upper-B source alt=%d incompatible with lip_b=%d" % [
					x, y, ub_alt, lip_b,
				])
	return fails


# An upstream source cell is compatible with `expected_lip` if water at
# that altitude is reachable from it: a GROUND/WATER cell exactly at
# expected_lip, or a WATERFALL cell whose basin equals expected_lip
# (chained falls — upstream's basin spills into our lip).
static func _upper_source_at(c: TerrainCell, expected_lip: int) -> bool:
	if c == null:
		return false
	if c.kind == TerrainCell.Kind.GROUND or c.kind == TerrainCell.Kind.WATER:
		return c.altitude == expected_lip
	if c.kind == TerrainCell.Kind.WATERFALL:
		return (c.altitude - c.drop_height) == expected_lip
	return false


# Every non-EMPTY cell must have an even altitude in [0, top_altitude]. Half-
# step snapping is enforced throughout the pipeline; a violation means a pass
# bypassed _snap_even.
static func _check_altitude_range_even(grid: TerrainGrid, params: TerrainGenerationParams) -> Array:
	var fails: Array = []
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind == TerrainCell.Kind.EMPTY:
				continue
			if c.altitude % 2 != 0:
				fails.append("(%d,%d) odd altitude=%d" % [x, y, c.altitude])
			if c.altitude < 0 or c.altitude > params.top_altitude:
				fails.append("(%d,%d) altitude %d outside [0, %d]" % [
					x, y, c.altitude, params.top_altitude,
				])
	return fails


# Lake cells (the carved still-water cluster at apex_alt - lake_depth_hs) must
# all share one altitude. Identify the lake as the LARGEST face-connected
# component of WATER cells with water_flow == ZERO; verify every cell in that
# component is at the same altitude.
#
# Standalone still-water cells (size-1 components) are walker terminators
# (south boundary or boxed-in branches) and are explicitly tolerated — the
# walker leaves the final cell flowless by design.
static func _check_lake_altitude_consistent(grid: TerrainGrid, _params: TerrainGenerationParams) -> Array:
	var visited: Dictionary = {}
	var components: Array = []  # Array of Array[Vector2i]
	for y in grid.height:
		for x in grid.width:
			var key := Vector2i(x, y)
			if visited.has(key):
				continue
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.WATER or c.water_flow != Vector2i.ZERO:
				continue
			# BFS this still-water component.
			var comp: Array = []
			var queue: Array = [key]
			visited[key] = true
			while not queue.is_empty():
				var p: Vector2i = queue.pop_back()
				comp.append(p)
				for d in DiamondCompass.FACE_DIRS:
					var n: Vector2i = p + d
					if visited.has(n):
						continue
					var nc: TerrainCell = grid.at_or_null(n.x, n.y)
					if nc == null or nc.kind != TerrainCell.Kind.WATER or nc.water_flow != Vector2i.ZERO:
						continue
					visited[n] = true
					queue.append(n)
			components.append(comp)
	if components.is_empty():
		return []
	# Pick the largest component as the lake.
	var lake_idx: int = 0
	for i in components.size():
		if components[i].size() > components[lake_idx].size():
			lake_idx = i
	var lake: Array = components[lake_idx]
	var alts: Dictionary = {}
	for p in lake:
		alts[grid.at(p.x, p.y).altitude] = true
	if alts.size() <= 1:
		return []
	return ["lake (size %d) spans altitudes %s" % [lake.size(), str(alts.keys())]]


# Every WATER cell must have a shore_mask computed (could be 0 = open water on
# all sides, but the field should at least have been visited). A negative or
# >0xFF value indicates a corruption.
static func _check_shore_mask_on_water(grid: TerrainGrid, _params: TerrainGenerationParams) -> Array:
	var fails: Array = []
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.WATER:
				continue
			if c.shore_mask < 0 or c.shore_mask > 0xFF:
				fails.append("(%d,%d) shore_mask=%d outside [0,255]" % [
					x, y, c.shore_mask,
				])
	return fails


# All non-EMPTY cells (GROUND, WATER, WATERFALL) must form a single 4-connected
# component, where EMPTY cells are voids that break connectivity. A continent
# split by a lake/river still reads as one component because the water bridges
# the GROUND chunks. `_remove_islands` enforces this at the end of generation;
# a failure here means a later pass re-created an isolated pocket.
static func _check_no_islands(grid: TerrainGrid, _params: TerrainGenerationParams) -> Array:
	var visited: Dictionary = {}
	var component_sizes: Array[int] = []
	for y in grid.height:
		for x in grid.width:
			var key := Vector2i(x, y)
			if visited.has(key):
				continue
			var c: TerrainCell = grid.at(x, y)
			if c.kind == TerrainCell.Kind.EMPTY:
				continue
			var size: int = 0
			var queue: Array = [key]
			visited[key] = true
			while not queue.is_empty():
				var p: Vector2i = queue.pop_back()
				size += 1
				for d in DiamondCompass.FACE_DIRS:
					var n: Vector2i = p + d
					if visited.has(n):
						continue
					var nc: TerrainCell = grid.at_or_null(n.x, n.y)
					if nc == null or nc.kind == TerrainCell.Kind.EMPTY:
						continue
					visited[n] = true
					queue.append(n)
			component_sizes.append(size)
	if component_sizes.size() <= 1:
		return []
	component_sizes.sort()
	component_sizes.reverse()
	return ["non-EMPTY terrain has %d disconnected components (sizes: %s)" % [
		component_sizes.size(), str(component_sizes),
	]]


# ----------------------------------------------------------------------------
# Harness
# ----------------------------------------------------------------------------

const DEFAULT_SEEDS_PER_SCENARIO: int = 20

func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var seeds: int = DEFAULT_SEEDS_PER_SCENARIO
	var verbose: bool = false
	var scenario_filter: String = ""
	var i: int = 0
	while i < args.size():
		match args[i]:
			"--seeds":
				i += 1
				seeds = int(args[i])
			"--verbose", "-v":
				verbose = true
			"--scenario":
				i += 1
				scenario_filter = args[i]
		i += 1

	var grand_total_grids: int = 0
	var grand_total_failures: int = 0
	# scenario_name → check_name → count
	var per_scenario_counts: Dictionary = {}
	# scenario_name → Array of {seed, check, msg}
	var per_scenario_examples: Dictionary = {}

	for scen in SCENARIOS:
		var name: String = scen["name"]
		if scenario_filter != "" and name != scenario_filter:
			continue
		var overrides: Dictionary = scen["overrides"]
		var counts: Dictionary = {}
		var examples: Array = []
		for c in CHECKS:
			counts[c["name"]] = 0
		for s in seeds:
			var params := _make_params(overrides)
			params.seed = s
			var grid: TerrainGrid = TerrainGenerator.generate(params)
			grand_total_grids += 1
			for c in CHECKS:
				var fails: Array = (c["fn"] as Callable).call(grid, params)
				if fails.is_empty():
					continue
				counts[c["name"]] += fails.size()
				grand_total_failures += fails.size()
				if verbose or examples.size() < 3:
					for m in fails:
						examples.append({"seed": s, "check": c["name"], "msg": m})
						if not verbose and examples.size() >= 3:
							break
		per_scenario_counts[name] = counts
		per_scenario_examples[name] = examples

	# Report.
	print("--- terrain invariant sweep ---")
	print("scenarios: %d  seeds/scenario: %d  total grids: %d" % [
		per_scenario_counts.size(), seeds, grand_total_grids,
	])
	print("")
	for name in per_scenario_counts:
		var counts: Dictionary = per_scenario_counts[name]
		var failed: int = 0
		for k in counts:
			failed += counts[k]
		var marker: String = "PASS" if failed == 0 else "FAIL"
		print("[%s] %s — %d failure(s)" % [marker, name, failed])
		if failed > 0:
			for k in counts:
				if counts[k] > 0:
					print("    %s: %d" % [k, counts[k]])
			for ex in per_scenario_examples[name]:
				print("    seed=%d  %s  %s" % [ex["seed"], ex["check"], ex["msg"]])
	print("")
	print("--- summary ---")
	print("total grids: %d" % grand_total_grids)
	print("total failures: %d" % grand_total_failures)
	quit(0 if grand_total_failures == 0 else 1)


static func _make_params(overrides: Dictionary) -> TerrainGenerationParams:
	var p := TerrainGenerationParams.new()
	for k in overrides:
		p.set(k, overrides[k])
	return p
