@tool
extends SceneTree

# ============================================================================
# generate_terrain_cli.gd — CLI bake tool
# ============================================================================
#
# Loads an inherited procedural map scene, runs the generator + painter, and
# saves the scene back with painted tiles baked in. Use for reproducible
# build outputs or to capture a "favorite seed" snapshot.
#
# Usage:
#   godot --headless --path . --script res://scripts/tools/generate_terrain_cli.gd \
#         -- <scene_path> [seed]
#
# Example:
#   godot --headless --path . --script res://scripts/tools/generate_terrain_cli.gd \
#         -- res://scenes/maps/procedural_test.tscn 12345
#
# Top altitude (and every other generation knob) lives on the
# `TerrainGenerationParams` Resource referenced by the scene's
# ProceduralWorld node. To change it without touching code, edit the
# referenced `.tres` directly under `res://resources/terrain/`.
#
# ============================================================================


func _init() -> void:
	var args := _parse_args()
	if args.is_empty():
		_print_usage()
		quit(1)
		return

	var scene_path: String = args[0]
	var packed: PackedScene = load(scene_path) as PackedScene
	if packed == null:
		push_error("generate_terrain_cli: failed to load scene '%s'." % scene_path)
		quit(1)
		return

	var root: Node = packed.instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
	if root == null:
		push_error("generate_terrain_cli: instantiate failed for '%s'." % scene_path)
		quit(1)
		return

	var pw: ProceduralWorld = _find_procedural_world(root)
	if pw == null:
		push_error("generate_terrain_cli: no ProceduralWorld node found in scene.")
		quit(1)
		return

	if args.size() > 1:
		pw.seed_override = int(args[1])

	# Force-call generation. ProceduralWorld.regenerate is editor-safe.
	pw.regenerate()

	var pack_result := PackedScene.new()
	var pack_err := pack_result.pack(root)
	if pack_err != OK:
		push_error("generate_terrain_cli: pack failed (%s)." % pack_err)
		quit(1)
		return

	var save_err := ResourceSaver.save(pack_result, scene_path)
	if save_err != OK:
		push_error("generate_terrain_cli: ResourceSaver.save failed (%s)." % save_err)
		quit(1)
		return

	var effective_seed: int = pw.seed_override
	if effective_seed < 0 and pw.generation_params != null:
		effective_seed = pw.generation_params.seed
	print("generate_terrain_cli: baked '%s' (seed=%d)." % [scene_path, effective_seed])
	quit(0)


func _find_procedural_world(node: Node) -> ProceduralWorld:
	if node is ProceduralWorld:
		return node
	for child in node.get_children():
		var found := _find_procedural_world(child)
		if found != null:
			return found
	return null


func _parse_args() -> Array:
	var raw: PackedStringArray = OS.get_cmdline_user_args()
	var out: Array = []
	for s in raw:
		out.append(s)
	return out


func _print_usage() -> void:
	print("Usage: --script res://scripts/tools/generate_terrain_cli.gd -- <scene_path> [seed]")
