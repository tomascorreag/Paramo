extends SceneTree

# Instantiates the scene, builds the pathfinder graph, and reports reachability
# of key cells plus the connections around the Ground1→Ground2 ramp row.
#   godot --headless --path . --script res://scripts/tools/dump_pathfinder.gd -- res://scenes/tools/tileset_test.tscn

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var scene_path: String = args[0] if args.size() > 0 else "res://scenes/tools/tileset_test.tscn"
	var packed: PackedScene = load(scene_path)
	var root: Node = packed.instantiate()
	get_root().add_child(root)

	await process_frame
	await process_frame

	var pf: Pathfinder = root.get_node_or_null("Pathfinder") as Pathfinder
	if pf == null:
		print("No Pathfinder found.")
		quit(1); return

	var grid: TileGrid = pf.grid()
	if grid == null:
		print("Grid is null.")
		quit(1); return

	print("--- layer altitudes ---")
	for layer in grid.layers():
		print("  %s  alt=%d  pos=%s" % [layer.name, grid.layer_altitude(layer), str(layer.position)])

	print("--- key cells (walkable? layer/alt/kind) ---")
	var keys: Array[Vector2i] = [
		Vector2i(2, 0), Vector2i(3, 0), Vector2i(4, 0),           # Ground1 bases below the ramps
		Vector2i(2, -1), Vector2i(3, -1), Vector2i(4, -1),        # SLOPE_NE ramps
		Vector2i(2, -2), Vector2i(3, -2), Vector2i(4, -2), Vector2i(5, -2),  # Ground2 north strip
		Vector2i(5, -1), Vector2i(5, 0), Vector2i(5, 1), Vector2i(5, 2),      # Ground2 east strip
		Vector2i(6, 2), Vector2i(7, 2), Vector2i(5, 3), Vector2i(5, 4),       # Ground0 plateau + ramps
	]
	for c in keys:
		var info := grid.cell_info(c)
		var walk: bool = info.get("walkable", false)
		var layer: TileMapLayer = info.get("layer", null)
		var lname: String = layer.name if layer != null else "<none>"
		print("  %s  walk=%s  layer=%s  kind=%s  low=%s  high=%s" % [
			str(c), str(walk), lname,
			str(info.get("tile_kind", "")),
			str(info.get("altitude_low", "?")),
			str(info.get("altitude_high", "?")),
		])

	print("--- transitions of interest ---")
	_check(grid, Vector2i(2, 0), Vector2i(2, -1))
	_check(grid, Vector2i(2, -1), Vector2i(2, -2))
	_check(grid, Vector2i(3, -1), Vector2i(3, -2))
	_check(grid, Vector2i(4, -1), Vector2i(4, -2))
	_check(grid, Vector2i(4, -2), Vector2i(5, -2))
	_check(grid, Vector2i(5, -2), Vector2i(5, -1))
	_check(grid, Vector2i(5, -1), Vector2i(5, 0))

	print("--- path from player base (2,0) to Ground2 targets ---")
	for target in [Vector2i(2, -2), Vector2i(5, -2), Vector2i(5, 0), Vector2i(5, 2)]:
		var path := pf.find_path(Vector2i(2, 0), target)
		print("  (2,0) -> %s : len=%d path=%s" % [str(target), path.size(), str(path)])

	print("--- path from (2,0) to Ground0 plateau (6,2) for comparison ---")
	var g0path := pf.find_path(Vector2i(2, 0), Vector2i(6, 2))
	print("  (2,0) -> (6,2) : len=%d path=%s" % [g0path.size(), str(g0path)])

	quit(0)

static func _check(grid: TileGrid, a: Vector2i, b: Vector2i) -> void:
	var dir := b - a
	var ea := grid.exit_altitude(a, dir)
	var eb := grid.enter_altitude(b, dir)
	var ok := grid.can_transition(a, b)
	print("  %s -> %s  exit=%s  enter=%s  can_transition=%s" % [str(a), str(b), str(ea), str(eb), str(ok)])
