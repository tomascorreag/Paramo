extends SceneTree

# Headless dumper: lists every painted tile on every TileMapLayer in a scene,
# with its tile_kind custom data, grouped by layer. Usage:
#   godot --headless --path . --script res://scripts/tools/dump_scene_tiles.gd -- res://scenes/tools/tileset_test.tscn

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("Usage: dump_scene_tiles.gd -- <scene_path>")
		quit(1)
		return
	var scene_path: String = args[0]
	var packed: PackedScene = load(scene_path)
	if packed == null:
		push_error("Could not load scene: %s" % scene_path)
		quit(1)
		return
	var root: Node = packed.instantiate()
	_dump(root)
	quit(0)

func _dump(root: Node) -> void:
	var layers: Array[TileMapLayer] = []
	_collect_layers(root, layers)
	for layer in layers:
		var alt: Variant = layer.get_meta("altitude", "<missing>")
		print("=== %s  (altitude=%s, position=%s) ===" % [layer.get_path(), str(alt), str(layer.position)])
		if layer.tile_set == null:
			print("  (no tile_set)")
			continue
		var kind_id := _kind_layer(layer.tile_set)
		var cells := layer.get_used_cells()
		cells.sort_custom(func(a, b):
			if a.y != b.y: return a.y < b.y
			return a.x < b.x)
		for cell in cells:
			var data := layer.get_cell_tile_data(cell)
			var atlas := layer.get_cell_atlas_coords(cell)
			var src := layer.get_cell_source_id(cell)
			var kind := ""
			if data != null and kind_id >= 0:
				var k: Variant = data.get_custom_data_by_layer_id(kind_id)
				if k is String: kind = k
			print("  cell=%s  src=%d  atlas=%s  kind=%s" % [str(cell), src, str(atlas), kind])

func _collect_layers(node: Node, out: Array[TileMapLayer]) -> void:
	if node is TileMapLayer:
		out.append(node)
	for child in node.get_children():
		_collect_layers(child, out)

static func _kind_layer(ts: TileSet) -> int:
	for i in ts.get_custom_data_layers_count():
		if ts.get_custom_data_layer_name(i) == "tile_kind":
			return i
	return -1
