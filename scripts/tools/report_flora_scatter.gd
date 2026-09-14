@tool
extends SceneTree

# ============================================================================
# report_flora_scatter
# ============================================================================
#
# Where does each plant species actually land? Generates N seeds of a
# scenario, runs ObjectPainter.assign_object_kinds once per ecosystem profile,
# and prints, per ecosystem × species: count per seed, altitude mean ± sd
# (half-steps), mean distance to water (cells), and the same-kind neighbour
# fraction (how clumped it is). Then it checks the orderings the species
# research asks for and exits 1 if any fails, so the numbers behind
# resources/objects/*.tres can be re-verified after every retune.
#
# Headless; no scene. Uses the invariants harness's SCENARIOS and
# _make_params so the terrain is exactly what that sweep sees.
#
# Usage:
#   godot --headless --path . --script res://scripts/tools/report_flora_scatter.gd
#   ... -- --seeds 12 --scenario level1 --ecosystem chingaza
#   ... -- --verbose            # also print the per-seed plant totals
# ============================================================================

const _HARNESS = preload("res://scripts/tools/verify_terrain_invariants.gd")

const DEFAULT_SEEDS: int = 12
const DEFAULT_SCENARIO: String = "level1"

# Plant total the report considers healthy on a default 48×48 grid — the
# canvas-item budget from dev-notes/performance.md, well under
# ObjectPainter.PLANT_BUDGET (the warning threshold). The floor is set by
# `nevados`, which has no Oriental shrub layer and lands ~10% under the two
# Oriental profiles at the same grass density (measured 2026-08-28: 355 /
# 372 / 320). The real gate is the web profile's canvas-item row, not this.
const TARGET_PLANTS_MIN: int = 300
const TARGET_PLANTS_MAX: int = 450


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var seeds: int = DEFAULT_SEEDS
	var scenario: String = DEFAULT_SCENARIO
	var only: StringName = &""
	var verbose: bool = false
	var i: int = 0
	while i < args.size():
		match args[i]:
			"--seeds":
				i += 1
				seeds = int(args[i])
			"--scenario":
				i += 1
				scenario = args[i]
			"--ecosystem":
				i += 1
				only = StringName(args[i])
			"--verbose", "-v":
				verbose = true
		i += 1

	var overrides: Dictionary = {}
	var found: bool = false
	for scen in _HARNESS.SCENARIOS:
		if scen["name"] == scenario:
			overrides = scen["overrides"]
			found = true
			break
	if not found:
		push_error("report_flora_scatter: unknown scenario '%s'." % scenario)
		quit(2)
		return

	var profiles: Array[EcosystemProfile] = []
	for p in ObjectPainter.profiles():
		if only == &"" or p.id == only:
			profiles.append(p)
	if profiles.is_empty():
		push_error("report_flora_scatter: unknown ecosystem '%s'." % only)
		quit(2)
		return

	var any_fail: bool = false
	print("report_flora_scatter — scenario %s, %d seeds" % [scenario, seeds])
	for profile in profiles:
		var stats: Dictionary = _gather(profile, overrides, seeds, verbose)
		_print_table(profile, stats, seeds)
		if not _check(profile, stats):
			any_fail = true
	quit(1 if any_fail else 0)


# kind → {count, alt_sum, alt_sq, wd_sum, wd_n, nb_same, nb_total}; plus
# "_eligible", "_plants" (Array per seed).
func _gather(
	profile: EcosystemProfile, overrides: Dictionary, seeds: int, verbose: bool
) -> Dictionary:
	var stats: Dictionary = {"_eligible": 0, "_plants": []}
	for s in seeds:
		var params := _HARNESS._make_params(overrides)
		params.seed = s
		var grid: TerrainGrid = TerrainGenerator.generate(params)
		var rng := RandomNumberGenerator.new()
		rng.seed = s ^ ObjectPainter.OBJECT_SEED_XOR
		ObjectPainter.assign_object_kinds(grid, rng, profile)
		var wd: PackedInt32Array = ObjectPainter._compute_water_distance(grid)
		var plants: int = 0
		for y in grid.height:
			for x in grid.width:
				var c: TerrainCell = grid.at(x, y)
				if c.kind == TerrainCell.Kind.GROUND and (
						c.ground_shape == TerrainCell.GroundShape.FULL_CUBE
						or c.ground_shape == TerrainCell.GroundShape.FLAT):
					stats["_eligible"] += 1
					# Ground itself, so a band can be read against what exists.
					if not stats.has("_ground"):
						stats["_ground"] = {"alt": {}, "wd": {}}
					var g: Dictionary = stats["_ground"]
					g["alt"][c.altitude] = g["alt"].get(c.altitude, 0) + 1
					var gd: int = mini(wd[y * grid.width + x], 20)
					g["wd"][gd] = g["wd"].get(gd, 0) + 1
				if c.object_kind == &"":
					continue
				var data: WorldObjectData = ObjectPainter.data_for(c.object_kind)
				if not (data is PlantObjectData):
					continue
				plants += 1
				var k: StringName = c.object_kind
				if not stats.has(k):
					stats[k] = {"count": 0, "alt_sum": 0.0, "alt_sq": 0.0,
						"wd_sum": 0.0, "wd_n": 0, "nb_same": 0, "nb_total": 0}
				var st: Dictionary = stats[k]
				st["count"] += 1
				st["alt_sum"] += c.altitude
				st["alt_sq"] += c.altitude * c.altitude
				var d: int = wd[y * grid.width + x]
				if d < 1000000:
					st["wd_sum"] += d
					st["wd_n"] += 1
				for off in DiamondCompass.FACE_DIRS:
					var nc: TerrainCell = grid.at_or_null(x + off.x, y + off.y)
					if nc == null:
						continue
					st["nb_total"] += 1
					if nc.object_kind == k:
						st["nb_same"] += 1
		stats["_plants"].append(plants)
		if verbose:
			print("  seed %d: %d plants" % [s, plants])
	return stats


func _print_table(profile: EcosystemProfile, stats: Dictionary, seeds: int) -> void:
	var plants: Array = stats["_plants"]
	var total: int = 0
	var lo: int = 1 << 30
	var hi: int = 0
	for n in plants:
		total += n
		lo = mini(lo, n)
		hi = maxi(hi, n)
	print("\n== %s — eligible cells/seed %.0f, plants/seed %.0f (min %d, max %d) =="
		% [profile.id, float(stats["_eligible"]) / seeds, float(total) / seeds, lo, hi])
	if stats.has("_ground"):
		print("  eligible ground by altitude: %s" % _histogram(stats["_ground"]["alt"], seeds))
		print("  eligible ground by water dist (20 = 20+): %s" % _histogram(stats["_ground"]["wd"], seeds))
	# Cells and individuals are two different numbers now: a cell holds one
	# occupant but ground cover draws up to individuals_per_cell.y of them.
	# The budget above is CELLS (canvas items); this line is what the player
	# actually sees, and what a future biomass/fuel model would read.
	var indiv: float = 0.0
	for k in stats:
		if String(k).begins_with("_"):
			continue
		var kd: WorldObjectData = ObjectPainter.data_for(k)
		if kd == null:
			continue
		var per: float = 0.5 * float(kd.individuals_per_cell.x + kd.individuals_per_cell.y)
		indiv += float(stats[k]["count"]) * per
	print("  individuals/seed %.0f (%.1f per occupied cell)"
		% [indiv / seeds, indiv / maxf(float(total), 1.0)])
	print("  %-24s %7s %12s %8s %8s %6s" % ["kind", "n/seed", "alt mean±sd", "water", "clump", "per"])
	for k in _kinds_sorted(stats):
		var st: Dictionary = stats[k]
		var n: int = st["count"]
		var mean: float = st["alt_sum"] / n
		var sd: float = sqrt(maxf(st["alt_sq"] / n - mean * mean, 0.0))
		var wdm: float = st["wd_sum"] / st["wd_n"] if st["wd_n"] > 0 else -1.0
		var clump: float = float(st["nb_same"]) / st["nb_total"] if st["nb_total"] > 0 else 0.0
		print("  %-24s %7.1f %6.1f ± %4.1f %8.2f %8.3f"
			% [k, float(n) / seeds, mean, sd, wdm, clump] + _per_cell_col(k))


func _kinds_sorted(stats: Dictionary) -> Array:
	var out: Array = []
	for k in stats.keys():
		if not (k is String and (k as String).begins_with("_")):
			out.append(k)
	out.sort_custom(func(a, b): return stats[a]["count"] > stats[b]["count"])
	return out


# "alt: n/seed" pairs in key order, e.g. "0:12 2:40 4:88 …".
func _histogram(h: Dictionary, seeds: int) -> String:
	var keys: Array = h.keys()
	keys.sort()
	var parts: PackedStringArray = PackedStringArray()
	for k in keys:
		parts.append("%d:%.0f" % [k, float(h[k]) / seeds])
	return " ".join(parts)


func _mean_alt(stats: Dictionary, k: StringName) -> float:
	if not stats.has(k):
		return NAN
	return stats[k]["alt_sum"] / stats[k]["count"]


func _mean_wd(stats: Dictionary, k: StringName) -> float:
	if not stats.has(k) or stats[k]["wd_n"] == 0:
		return NAN
	return stats[k]["wd_sum"] / stats[k]["wd_n"]


# The orderings the species research asks for (design/flora.md and the plan
# behind resources/objects/*.tres). Each is printed PASS/FAIL; returns false
# on any FAIL. Absent species (multiplier 0) are skipped where a check
# would need them.
func _check(profile: EcosystemProfile, stats: Dictionary) -> bool:
	var ok: bool = true
	var plants: Array = stats["_plants"]
	var mean_plants: float = 0.0
	for n in plants:
		mean_plants += n
	mean_plants /= maxi(plants.size(), 1)

	ok = _report("plants/seed in [%d, %d]" % [TARGET_PLANTS_MIN, TARGET_PLANTS_MAX],
		mean_plants >= TARGET_PLANTS_MIN and mean_plants <= TARGET_PLANTS_MAX) and ok

	# Only one Espeletia per mountain — the whole point of the profiles.
	var esp: int = 0
	for k in [&"frailejon", &"espeletia_barclayana", &"espeletia_hartwegiana"]:
		if stats.has(k):
			esp += 1
	ok = _report("exactly one Espeletia present", esp == 1) and ok

	# Calamagrostis is the dominant cover everywhere it exists.
	var top: Array = _kinds_sorted(stats)
	ok = _report("calamagrostis is the most numerous kind",
		not top.is_empty() and top[0] == &"calamagrostis") and ok

	# Chusquea sits in the wet valley floors: lowest and nearest water of
	# the community formers; Cortaderia hugs the shoreline tighter still.
	if stats.has(&"chusquea") and stats.has(&"calamagrostis"):
		ok = _report("chusquea lower than calamagrostis",
			_mean_alt(stats, &"chusquea") < _mean_alt(stats, &"calamagrostis")) and ok
		ok = _report("chusquea nearer water than calamagrostis",
			_mean_wd(stats, &"chusquea") < _mean_wd(stats, &"calamagrostis")) and ok
	if stats.has(&"cortaderia"):
		var wd_c: float = _mean_wd(stats, &"cortaderia")
		var nearest: bool = true
		for k in _kinds_sorted(stats):
			# A kind with under one plant per seed is a sample of one, not a
			# distribution; it cannot outrank anything.
			if stats[k]["count"] < plants.size():
				continue
			if k != &"cortaderia" and _mean_wd(stats, k) <= wd_c:
				nearest = false
		ok = _report("cortaderia is the kind nearest water", nearest) and ok

	# Dry-site shrub below the rosettes. `guerrero` is the tight pair — its
	# Espeletia (barclayana, band 4-20) overlaps hypericum (0-16) almost
	# entirely, so the margin there is under one half-step and a retune of
	# either band can invert it. Widen the separation on evidence, don't
	# relax the check.
	if stats.has(&"hypericum"):
		for k in [&"frailejon", &"espeletia_barclayana", &"espeletia_hartwegiana"]:
			if stats.has(k):
				ok = _report("hypericum lower than %s" % k,
					_mean_alt(stats, &"hypericum") < _mean_alt(stats, k)) and ok
	return ok


func _report(label: String, passed: bool) -> bool:
	print("  [%s] %s" % ["PASS" if passed else "FAIL", label])
	return passed


# Trailing "per" column: the individuals_per_cell range, blank for the one
# plant / one cell kinds so the table stays readable.
func _per_cell_col(kind: StringName) -> String:
	var d: WorldObjectData = ObjectPainter.data_for(kind)
	if d == null or d.individuals_per_cell == Vector2i(1, 1):
		return ""
	return "  %d-%d" % [d.individuals_per_cell.x, d.individuals_per_cell.y]
