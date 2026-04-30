@tool
extends SceneTree

# Dumps a window of cells around a target (cx, cy). Used to diagnose
# generation oddities reported by visual inspection.
#
# Usage (level1 params, seed 6, around 15,12):
#   godot --headless --path . --script res://scripts/tools/dump_cells_around.gd

func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var cx: int = 15
	var cy: int = 12
	var win: int = 4
	if args.size() >= 1:
		cx = int(args[0])
	if args.size() >= 2:
		cy = int(args[1])
	if args.size() >= 3:
		win = int(args[2])

	var params := TerrainGenerationParams.new()
	# Match level1.tscn overrides on top of defaults.
	params.seed = 6
	params.top_altitude = 24
	params.weight_ne = 2.0
	params.weight_nw = 2.0
	params.lake_radius = 3.0
	# Defaults (kept explicit for clarity).
	params.width = 48
	params.height = 48

	var grid: TerrainGrid = TerrainGenerator.generate(params)

	print("Dump around (%d, %d) win=%d  seed=%d  level1 overrides applied" % [cx, cy, win, params.seed])
	print("KIND letters: G=GROUND  E=EMPTY  W=WATER  F=WATERFALL")
	print("")

	# Header row of x indices.
	var header: String = "      "
	for x in range(cx - win, cx + win + 1):
		header += " %3d " % x
	print(header)

	for y in range(cy - win, cy + win + 1):
		var row_kind: String = "%3d:  " % y
		var row_alt: String = "      "
		var row_extra: String = "      "
		for x in range(cx - win, cx + win + 1):
			if not grid.in_bounds(x, y):
				row_kind += "  -  "
				row_alt += "  -  "
				row_extra += "     "
				continue
			var c: TerrainCell = grid.at(x, y)
			var k: String = "?"
			match c.kind:
				TerrainCell.Kind.EMPTY: k = "E"
				TerrainCell.Kind.GROUND: k = "G"
				TerrainCell.Kind.WATER: k = "W"
				TerrainCell.Kind.WATERFALL: k = "F"
			# Marker for the target cell.
			if x == cx and y == cy:
				k = "[%s]" % k
				row_kind += "%5s" % k
			else:
				row_kind += " %3s " % k
			row_alt += " %3d " % c.altitude
			if c.kind == TerrainCell.Kind.WATERFALL:
				row_extra += "F%d/%d" % [c.drop_height, c.altitude - c.drop_height]
				if (cx - win) <= x and x < (cx + win):
					row_extra += " "
			else:
				row_extra += "     "
		print("kind  " + row_kind)
		print("alt   " + row_alt)
		print("xtra  " + row_extra)
		print("")

	# Also list all WATERFALL cells globally so we can verify total count.
	print("--- All WATERFALL cells in this grid ---")
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.WATERFALL:
				continue
			print("  (%d,%d) alt=%d drop_height=%d basin_alt=%d flow=%s rise=%s" % [
				x, y, c.altitude, c.drop_height, c.altitude - c.drop_height,
				str(c.water_flow), str(c.fall_rise_dir),
			])

	# Dump river WATER cells too, in walker order (chase chain via water_flow
	# from any WATER neighbor of WATERFALLs is messy; just list all WATER non-
	# lake cells. Lake cells share the same altitude — we identify them as the
	# cluster at top_altitude.)
	print("--- WATER cells (incl. lake) ---")
	var water_count: int = 0
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.WATER:
				continue
			water_count += 1
			if water_count <= 200:
				print("  (%d,%d) alt=%d flow=%s" % [x, y, c.altitude, str(c.water_flow)])
	print("  total water cells: %d" % water_count)

	quit(0)
