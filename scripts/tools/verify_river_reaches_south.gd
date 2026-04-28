@tool
extends SceneTree

# Sweeps a range of seeds and verifies every generated terrain has at least one
# river cell on the south row (y == height - 1). Prints any failing seed.
#
# Usage:
#   godot --headless --path . --script res://scripts/tools/verify_river_reaches_south.gd -- 200

func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var n: int = 100
	if args.size() > 0:
		n = int(args[0])
	var params := TerrainGenerationParams.new()
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

	var failures: Array[int] = []
	for s in n:
		params.seed = s
		var grid: TerrainGrid = TerrainGenerator.generate(params)
		var ok: bool = false
		for x in grid.width:
			var c: TerrainCell = grid.at(x, grid.height - 1)
			if c.kind == TerrainCell.Kind.WATER or c.kind == TerrainCell.Kind.WATERFALL:
				ok = true
				break
		if not ok:
			failures.append(s)

	print("--- river-reaches-south sweep ---")
	print("seeds tested: %d" % n)
	print("failures: %d" % failures.size())
	for s in failures:
		print("  seed %d FAILED" % s)
	quit(0 if failures.is_empty() else 1)
