@tool
extends SceneTree

# ============================================================================
# dump_cells_around — focused diagnostic for procedural terrain cells
# ============================================================================
#
# Regenerates a `level1`-scenario grid at the requested seed and prints three
# views of cell (cx, cy):
#
#   1. Window grid    — NxN spatial snapshot (kind letter + altitude rows),
#                       target cell bracketed. Quick visual check of the
#                       neighborhood.
#   2. Cell focus     — target + 4 face neighbors (NE/NW/SE/SW) with full
#                       per-kind state. Shows waterfall rise/drop/basin and
#                       the secondary face fields (rise_b/drop_b) used by
#                       concave-corner falls. Shows water flow and shore
#                       mask for WATER cells.
#   3. Waterfall list — every WATERFALL cell in the grid; entries with a
#                       second face are flagged [CORNER]. Use this to verify
#                       a corner-fall upgrade fired and to find other corner
#                       falls in the same grid.
#
# Use cases:
#   - "Cell (X, Y) renders wrong" → dump it and confirm what the generator
#     produced (kind, altitude, secondary face) before suspecting the painter
#   - Verifying a generator change preserved (or restored) corner falls at a
#     known fixture cell — eg level1 seed=19 (17,23)
#   - Locating all corner falls in a seed before opening the scene
#
# ----------------------------------------------------------------------------
# Args
# ----------------------------------------------------------------------------
#
#   <x> <y>     required — target cell grid coords
#   <seed>      optional, default 16 (matches scenes/maps/level1.tscn's
#               seed_override). Pass any int to inspect a different seed.
#   <window>    optional, default 4. The window view spans (2*window+1)
#               cells per side centered on the target.
#
# Examples:
#
#   # Default: cell (17,23) at seed 16, window 4×4 → 9×9 grid view
#   godot --headless --path . --script res://scripts/tools/dump_cells_around.gd -- 17 23
#
#   # Specific seed (eg the asymmetric corner fall fixture from seed 63)
#   godot --headless --path . --script res://scripts/tools/dump_cells_around.gd -- 22 21 63
#
#   # Larger window for spatial context
#   godot --headless --path . --script res://scripts/tools/dump_cells_around.gd -- 17 23 16 8
#
# ----------------------------------------------------------------------------
# Switching scenarios
# ----------------------------------------------------------------------------
#
# `LEVEL1_OVERRIDES` below mirrors the "level1" entry in
# `verify_terrain_invariants.gd`. To inspect a different scenario, copy that
# scenario's `overrides` dict from the harness and replace LEVEL1_OVERRIDES.
# Keep the harness as the source of truth — when level1 retunes, both files
# need updating in lockstep (same convention as the harness's level1 entry
# and scenes/maps/level1.tscn).
# ============================================================================


const LEVEL1_OVERRIDES := {
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
}


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() < 2:
		print("usage: dump_cells_around <x> <y> [seed=19] [window=4]")
		quit(1)
		return
	var cx: int = int(args[0])
	var cy: int = int(args[1])
	var seed: int = int(args[2]) if args.size() >= 3 else 19
	var win: int = int(args[3]) if args.size() >= 4 else 4

	var params := TerrainGenerationParams.new()
	for k in LEVEL1_OVERRIDES:
		params.set(k, LEVEL1_OVERRIDES[k])
	params.seed = seed

	var grid: TerrainGrid = TerrainGenerator.generate(params)

	print("=== dump_cells_around ===")
	print("scenario: level1   seed: %d   target: (%d, %d)   window: %d" % [
		seed, cx, cy, win,
	])
	print("kinds: G=GROUND  W=WATER  F=WATERFALL  E=EMPTY  -=off-grid")
	print("")

	_print_window(grid, cx, cy, win)
	_print_cell_focus(grid, cx, cy)
	_print_waterfall_list(grid)

	quit(0)


# Spatial NxN view. Two rows per y: kind letter (target bracketed) + altitude.
static func _print_window(grid: TerrainGrid, cx: int, cy: int, win: int) -> void:
	print("--- window (%d × %d) ---" % [2 * win + 1, 2 * win + 1])
	var header: String = "       "
	for x in range(cx - win, cx + win + 1):
		header += " %3d " % x
	print(header)
	for y in range(cy - win, cy + win + 1):
		var kinds: String = "%3d k: " % y
		var alts:  String = "    a: "
		for x in range(cx - win, cx + win + 1):
			var c: TerrainCell = grid.at_or_null(x, y)
			var k: String = "-"
			var a: String = "  -"
			if c != null:
				match c.kind:
					TerrainCell.Kind.EMPTY:     k = "E"
					TerrainCell.Kind.GROUND:    k = "G"
					TerrainCell.Kind.WATER:     k = "W"
					TerrainCell.Kind.WATERFALL: k = "F"
				a = "%3d" % c.altitude
			if x == cx and y == cy:
				kinds += "[%s]  " % k
			else:
				kinds += " %s   " % k
			alts += " %s " % a
		print(kinds)
		print(alts)
	print("")


# Per-cell detail for the target + 4 face neighbors.
static func _print_cell_focus(grid: TerrainGrid, cx: int, cy: int) -> void:
	print("--- target cell + face neighbors ---")
	_dump_cell(grid, cx, cy, "self")
	for spec in [
		[Vector2i(0, -1), "NE  "],
		[Vector2i(-1, 0), "NW  "],
		[Vector2i(1, 0),  "SE  "],
		[Vector2i(0, 1),  "SW  "],
	]:
		var d: Vector2i = spec[0]
		_dump_cell(grid, cx + d.x, cy + d.y, spec[1])
	print("")


# Every WATERFALL in the grid, flagged [CORNER] when fall_rise_dir_b is set.
# Useful for confirming a corner-fall upgrade fired somewhere and listing
# every concave corner in a generation result at a glance.
static func _print_waterfall_list(grid: TerrainGrid) -> void:
	print("--- all waterfalls ---")
	var corners: int = 0
	var total: int = 0
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.WATERFALL:
				continue
			total += 1
			var basin: int = c.altitude - c.drop_height
			var line: String = "  (%2d,%2d) lip=%2d drop=%d basin=%2d rise=%s" % [
				x, y, c.altitude, c.drop_height, basin, _dir_name(c.fall_rise_dir),
			]
			if c.fall_rise_dir_b != Vector2i.ZERO:
				corners += 1
				var lip_b: int = basin + c.drop_height_b
				line += "  +  rise_b=%s drop_b=%d lip_b=%d  [CORNER]" % [
					_dir_name(c.fall_rise_dir_b), c.drop_height_b, lip_b,
				]
			print(line)
	print("  total: %d waterfalls (%d corner falls)" % [total, corners])


static func _dump_cell(grid: TerrainGrid, x: int, y: int, label: String) -> void:
	var c: TerrainCell = grid.at_or_null(x, y)
	if c == null:
		print("  %s (%2d,%2d)  off-grid" % [label, x, y])
		return
	var kind: String = "?"
	var extra: String = ""
	match c.kind:
		TerrainCell.Kind.EMPTY:
			kind = "EMPTY"
		TerrainCell.Kind.GROUND:
			kind = "GROUND"
		TerrainCell.Kind.WATER:
			kind = "WATER"
			extra = "  flow=%s shore=0x%02x" % [_dir_name(c.water_flow), c.shore_mask]
		TerrainCell.Kind.WATERFALL:
			kind = "WATERFALL"
			var basin: int = c.altitude - c.drop_height
			extra = "  rise=%s drop=%d basin=%d" % [
				_dir_name(c.fall_rise_dir), c.drop_height, basin,
			]
			if c.fall_rise_dir_b != Vector2i.ZERO:
				extra += "  +  rise_b=%s drop_b=%d  [CORNER]" % [
					_dir_name(c.fall_rise_dir_b), c.drop_height_b,
				]
	print("  %s (%2d,%2d)  alt=%2d  %-9s%s" % [label, x, y, c.altitude, kind, extra])


static func _dir_name(d: Vector2i) -> String:
	if d == Vector2i.ZERO: return "  -"
	if d == DiamondCompass.DIR_NE: return " NE"
	if d == DiamondCompass.DIR_NW: return " NW"
	if d == DiamondCompass.DIR_SE: return " SE"
	if d == DiamondCompass.DIR_SW: return " SW"
	return str(d)
