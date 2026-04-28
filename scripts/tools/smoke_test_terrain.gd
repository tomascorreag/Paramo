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
	params.width = 32
	params.height = 48
	params.top_altitude = 16
	params.apex_x_jitter_frac = 0.15
	params.cone_steepness = 1.0
	params.south_bias = 0.5
	params.branch_chance = 0.25
	params.slope_chance = 0.35
	params.lake_radius = 2.6
	params.max_drop_cubes = 4
	params.drop_height_bias = 0.0

	var t0: int = Time.get_ticks_msec()
	var grid: TerrainGrid = TerrainGenerator.generate(params)
	var dt: int = Time.get_ticks_msec() - t0

	var alt_counts: Dictionary = {}
	var kind_counts: Dictionary = {0: 0, 1: 0, 2: 0, 3: 0}
	var biome_counts: Dictionary = {0: 0, 1: 0, 2: 0, 3: 0}
	var shape_counts: Dictionary = {0: 0, 1: 0, 2: 0, 3: 0, 4: 0, 5: 0}
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
			if c.kind == TerrainCell.Kind.GROUND:
				biome_counts[c.biome] = biome_counts.get(c.biome, 0) + 1
				shape_counts[c.ground_shape] = shape_counts.get(c.ground_shape, 0) + 1
			elif c.kind == TerrainCell.Kind.WATERFALL:
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
	print("biome: GRASS=%d DIRT=%d ROCK=%d SNOW=%d" % [
		biome_counts.get(TerrainCell.Biome.GRASS, 0),
		biome_counts.get(TerrainCell.Biome.DIRT, 0),
		biome_counts.get(TerrainCell.Biome.ROCK, 0),
		biome_counts.get(TerrainCell.Biome.SNOW, 0),
	])
	print("shape: FULL_CUBE=%d FLAT=%d SLOPE_NE=%d SLOPE_NW=%d SLOPE_SE=%d SLOPE_SW=%d" % [
		shape_counts.get(TerrainCell.GroundShape.FULL_CUBE, 0),
		shape_counts.get(TerrainCell.GroundShape.FLAT, 0),
		shape_counts.get(TerrainCell.GroundShape.SLOPE_NE, 0),
		shape_counts.get(TerrainCell.GroundShape.SLOPE_NW, 0),
		shape_counts.get(TerrainCell.GroundShape.SLOPE_SE, 0),
		shape_counts.get(TerrainCell.GroundShape.SLOPE_SW, 0),
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
