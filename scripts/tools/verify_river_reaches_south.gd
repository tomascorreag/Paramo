@tool
extends SceneTree

# Sweeps a range of seeds and verifies every generated terrain has at least one
# river cell on the south boundary (literal y == height-1 / x == width-1, or
# adjacent to an EMPTY cell carved by the disc mask).
#
# Usage:
#   godot --headless --path . --script res://scripts/tools/verify_river_reaches_south.gd -- 200

func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var n: int = 100
	if args.size() > 0:
		n = int(args[0])
	var params := TerrainGenerationParams.new()
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

	var failures: Array[int] = []
	for s in n:
		params.seed = s
		var grid: TerrainGrid = TerrainGenerator.generate(params)
		var ok: bool = false
		for y in grid.height:
			if ok:
				break
			for x in grid.width:
				var c: TerrainCell = grid.at(x, y)
				if c.kind != TerrainCell.Kind.WATER and c.kind != TerrainCell.Kind.WATERFALL:
					continue
				if y >= grid.height - 1 or x >= grid.width - 1:
					ok = true
					break
				var sw: TerrainCell = grid.at(x, y + 1)
				var se: TerrainCell = grid.at(x + 1, y)
				if sw.kind == TerrainCell.Kind.EMPTY or se.kind == TerrainCell.Kind.EMPTY:
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
