@tool
extends SceneTree

# ============================================================================
# copy_atlas_setup.gd — CLI tool
# ============================================================================
#
# Copies tile definitions (size_in_atlas, texture_origin, y_sort_origin,
# custom_data, alternatives) from one TileSetAtlasSource to others within
# a TileSet resource. Assumes target atlases have the same sprite layout.
#
# Usage:
#   godot --headless --script res://scripts/tools/copy_atlas_setup.gd -- <tileset_path> [from_id] [to_ids]
#
# Examples:
#   # Copy source 0 to all other sources (default):
#   godot --headless --script res://scripts/tools/copy_atlas_setup.gd -- res://resources/tiles/base_tileset.tres
#
#   # Copy source 0 to sources 2 and 3:
#   godot --headless --script res://scripts/tools/copy_atlas_setup.gd -- res://resources/tiles/base_tileset.tres 0 2,3
#
#   # Copy source 1 to source 4:
#   godot --headless --script res://scripts/tools/copy_atlas_setup.gd -- res://resources/tiles/base_tileset.tres 1 4
#
# ============================================================================


func _init() -> void:
	var args := _parse_args()
	if args.is_empty():
		_print_usage()
		quit(1)
		return

	var tileset_path: String = args[0]
	var tile_set := load(tileset_path) as TileSet
	if tile_set == null:
		push_error("Failed to load TileSet at '%s'." % tileset_path)
		quit(1)
		return

	var from_id: int = int(args[1]) if args.size() > 1 else 0

	var source := tile_set.get_source(from_id) as TileSetAtlasSource
	if source == null:
		push_error("Source ID %d is not a TileSetAtlasSource." % from_id)
		quit(1)
		return

	# Determine target IDs.
	var to_ids: Array[int] = []
	if args.size() > 2:
		for s in args[2].split(","):
			to_ids.append(int(s.strip_edges()))
	else:
		# Default: all other sources in the tileset.
		for i in tile_set.get_source_count():
			var sid := tile_set.get_source_id(i)
			if sid != from_id:
				to_ids.append(sid)

	if to_ids.is_empty():
		print("No target sources found. Nothing to do.")
		quit(0)
		return

	print("Copying atlas setup from source %d to %s in '%s'..." % [from_id, to_ids, tileset_path])

	for tid in to_ids:
		var target := tile_set.get_source(tid) as TileSetAtlasSource
		if target == null:
			push_warning("  Source %d is not a TileSetAtlasSource; skipping." % tid)
			continue
		_copy_source(tile_set, source, target, tid)

	var err := ResourceSaver.save(tile_set, tileset_path)
	if err != OK:
		push_error("Failed to save TileSet: error %d." % err)
		quit(1)
		return

	print("Done. Saved '%s'." % tileset_path)
	quit(0)


func _copy_source(tile_set: TileSet, from: TileSetAtlasSource, to: TileSetAtlasSource, to_id: int) -> void:
	# Preserve the target's texture and region size — only copy tile defs.
	var custom_layer_count := tile_set.get_custom_data_layers_count()

	# Clear existing tiles from target to avoid overlap conflicts.
	while to.get_tiles_count() > 0:
		to.remove_tile(to.get_tile_id(0))

	var copied := 0

	for i in from.get_tiles_count():
		var coords := from.get_tile_id(i)
		var size := from.get_tile_size_in_atlas(coords)

		to.create_tile(coords, size)

		# Copy each alternative tile (0 = primary, 1+ = alternatives).
		var alt_count := from.get_alternative_tiles_count(coords)
		for alt_idx in alt_count:
			var alt_id := from.get_alternative_tile_id(coords, alt_idx)

			# Create alternative on target if needed (alt 0 exists by default).
			if alt_id != 0 and not to.has_alternative_tile(coords, alt_id):
				to.create_alternative_tile(coords, alt_id)

			var src_data := from.get_tile_data(coords, alt_id)
			var dst_data := to.get_tile_data(coords, alt_id)

			dst_data.texture_origin = src_data.texture_origin
			dst_data.y_sort_origin = src_data.y_sort_origin
			dst_data.z_index = src_data.z_index
			dst_data.modulate = src_data.modulate
			dst_data.material = src_data.material
			dst_data.probability = src_data.probability

			# Copy all custom data layers.
			for layer_id in custom_layer_count:
				dst_data.set_custom_data_by_layer_id(
					layer_id,
					src_data.get_custom_data_by_layer_id(layer_id)
				)

		copied += 1

	print("  Source %d: copied %d tiles." % [to_id, copied])


func _parse_args() -> Array[String]:
	# Godot passes everything after "--" as user args.
	var result: Array[String] = []
	var raw := OS.get_cmdline_user_args()
	for arg in raw:
		result.append(arg)
	return result


func _print_usage() -> void:
	print("Usage: godot --headless --script res://scripts/tools/copy_atlas_setup.gd -- <tileset.tres> [from_id] [to_ids]")
	print("  from_id   Source ID to copy from (default: 0)")
	print("  to_ids    Comma-separated target IDs (default: all other sources)")
