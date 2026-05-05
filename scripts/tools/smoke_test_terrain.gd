@tool
extends SceneTree

# Smoke test: runs TerrainGenerator end-to-end and prints summary stats.
# No tile painting, no scene mutation. Pure abstract-model exercise.
#
# Usage:
#   godot --headless --path . --script res://scripts/tools/smoke_test_terrain.gd

func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var seed_arg: int = 12345
	if args.size() > 0:
		seed_arg = int(args[0])
	var params := TerrainGenerationParams.new()
	params.seed = seed_arg
	params.width = 48
	params.height = 48
	params.top_altitude = 16
	params.noise_frequency = 0.05
	params.noise_strength = 0.6
	params.weight_n = 1.0
	params.weight_ne = 0.6
	params.weight_nw = 0.6
	params.disc_center_x_frac = 0.35
	params.disc_center_y_frac = 0.35
	params.disc_radius_frac = 0.55
	params.disc_edge_jitter = 0.35
	params.lake_radius = 2.8
	params.lake_back_margin = 2
	params.south_bias = 1.0
	params.max_drop_cubes = 4

	var t0: int = Time.get_ticks_msec()
	var grid: TerrainGrid = TerrainGenerator.generate(params)
	var dt: int = Time.get_ticks_msec() - t0

	var alt_counts: Dictionary = {}
	var kind_counts: Dictionary = {0: 0, 1: 0, 2: 0, 3: 0}
	var drop_counts: Dictionary = {}
	var max_alt: int = 0
	var min_alt: int = 999
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			kind_counts[c.kind] = kind_counts.get(c.kind, 0) + 1
			if c.kind == TerrainCell.Kind.EMPTY:
				continue
			alt_counts[c.altitude] = alt_counts.get(c.altitude, 0) + 1
			max_alt = maxi(max_alt, c.altitude)
			min_alt = mini(min_alt, c.altitude)
			if c.kind == TerrainCell.Kind.WATERFALL:
				drop_counts[c.drop_height] = drop_counts.get(c.drop_height, 0) + 1

	print("--- TerrainGenerator smoke test ---")
	print("generation took %d ms" % dt)
	print("grid: %dx%d  altitude range: %d..%d" % [grid.width, grid.height, min_alt, max_alt])
	print("kind: EMPTY=%d  GROUND=%d  WATER=%d  WATERFALL=%d" % [
		kind_counts.get(TerrainCell.Kind.EMPTY, 0),
		kind_counts.get(TerrainCell.Kind.GROUND, 0),
		kind_counts.get(TerrainCell.Kind.WATER, 0),
		kind_counts.get(TerrainCell.Kind.WATERFALL, 0),
	])
	var alt_keys: Array = alt_counts.keys()
	alt_keys.sort()
	print("per-altitude cell count:")
	for a in alt_keys:
		print("  alt %2d: %d cells" % [a, alt_counts[a]])
	var drop_keys: Array = drop_counts.keys()
	drop_keys.sort()
	print("waterfall drop_height histogram (half-steps → count):")
	if drop_keys.is_empty():
		print("  (no waterfalls)")
	for d in drop_keys:
		print("  drop %d (%d cubes): %d falls" % [d, d / 2, drop_counts[d]])
	quit(0)
