extends GutTest

# ===========================================================================
# SpawnFlash — the placement / discovery flash on plants and structures
# ===========================================================================
# What the flash LOOKS like is a rendering question (preview_spawn_flash.gd).
# What these tests pin is the material handshake, which is where the bugs
# would be: a plant that never gets its shared sway material back, a burn
# that a late flash tween un-chars, an overlay that outlives its tween.

const _ICON: Texture2D = preload("res://icon.svg")
const _WIND: Shader = preload("res://assets/shaders/wind.gdshader")
const _FLASH: Shader = preload("res://assets/shaders/flash.gdshader")
const _PLANT_SCENE: PackedScene = preload("res://scenes/tools/frailejon.tscn")

var _shared_wind: ShaderMaterial


func before_each() -> void:
	_shared_wind = ShaderMaterial.new()
	_shared_wind.shader = _WIND


# The plant scene, in the tree, on a stub species — the sprite child is what
# _ready and the flash both need. No Pathfinder in the tree, so the occupant
# registration is skipped and the plant is just a sprite on a Node2D.
func _spawn_plant(wind: ShaderMaterial) -> Frailejon:
	var data := PlantObjectData.new()
	data.variants = [_ICON, _ICON]
	data.wind_material = wind
	data.casts_shadow = false
	var plant: Frailejon = _PLANT_SCENE.instantiate()
	plant.data = data
	add_child_autofree(plant)
	return plant


func _sprite_of(plant: Frailejon) -> Sprite2D:
	return plant.get_node("Sprite2D") as Sprite2D


# ---------------------------------------------------------------------------
# Shaders carry the uniforms
# ---------------------------------------------------------------------------

func _uniform_names(shader: Shader) -> Array[String]:
	var out: Array[String] = []
	for u: Dictionary in shader.get_shader_uniform_list():
		out.append(String(u["name"]))
	return out


func test_wind_shader_has_flash_uniforms() -> void:
	var names := _uniform_names(_WIND)
	assert_has(names, "flash_amount")
	assert_has(names, "flash_color")
	assert_has(names, "reveal_amount")


func test_flash_shader_has_flash_uniforms_and_cutout() -> void:
	var names := _uniform_names(_FLASH)
	assert_has(names, "flash_amount")
	assert_has(names, "flash_color")
	assert_has(names, "reveal_amount")
	assert_has(names, "reveal_from")
	assert_has(names, "reveal_to")


# ---------------------------------------------------------------------------
# Plant: material handshake
# ---------------------------------------------------------------------------

func test_placed_flash_swaps_to_private_copy_then_restores_shared() -> void:
	var plant := _spawn_plant(_shared_wind)
	var sprite := _sprite_of(plant)
	assert_eq(sprite.material, _shared_wind, "precondition: shared sway material on the sprite")

	plant.play_placed_flash(Vector2(100.0, 100.0))
	assert_true(plant.is_flashing())
	assert_ne(sprite.material, _shared_wind, "flash must not write to the shared material")
	var mat := sprite.material as ShaderMaterial
	assert_eq(mat.shader, _WIND, "copy keeps the sway shader")
	assert_eq(plant.material, sprite.material, "the clump extras get the same copy")
	assert_eq(float(mat.get_shader_parameter(&"reveal_amount")), 0.0, "arrives from nothing")
	assert_eq(float(mat.get_shader_parameter(&"flash_amount")), 0.0, "at its real colours")
	var from: Vector2 = mat.get_shader_parameter(&"reveal_from")
	var to: Vector2 = mat.get_shader_parameter(&"reveal_to")
	assert_gt((to - from).dot(plant.global_position - Vector2(100.0, 100.0)), 0.0,
		"the sweep travels away from the player")
	await wait_seconds(SpawnFlash.reveal_time(1) + 0.05)
	assert_almost_eq(float(mat.get_shader_parameter(&"reveal_amount")), 1.0, 0.001, "whole")
	assert_gt(float(mat.get_shader_parameter(&"flash_amount")), 0.5,
		"and only then bright (wait_seconds overshoots a frame or two into the fade)")
	# A material with no override answers null here, which is as untouched as 0.
	var shared_amount: Variant = _shared_wind.get_shader_parameter(&"flash_amount")
	assert_true(shared_amount == null or float(shared_amount) == 0.0,
		"the shared material never flashes")

	await wait_seconds(SpawnFlash.SETTLE + 0.1)
	assert_false(plant.is_flashing())
	assert_eq(sprite.material, _shared_wind, "shared sway material handed back")
	assert_null(plant.material, "extras material cleared (no extras on this species)")


func test_species_without_sway_gets_plain_flash_shader() -> void:
	var plant := _spawn_plant(null)
	var sprite := _sprite_of(plant)
	assert_null(sprite.material, "precondition: no material on a non-swaying species")

	plant.play_discovery_flash()
	assert_eq((sprite.material as ShaderMaterial).shader, _FLASH)
	assert_eq(
		(sprite.material as ShaderMaterial).get_shader_parameter(&"flash_color"),
		SpawnFlash.DISCOVER_COLOR)

	await wait_seconds(SpawnFlash.RISE + SpawnFlash.HOLD + SpawnFlash.DISCOVER_SETTLE + 0.1)
	assert_null(sprite.material, "back to no material")
	assert_null(plant.material)


func test_burn_during_flash_wins_and_is_not_restored_over() -> void:
	var plant := _spawn_plant(_shared_wind)
	var sprite := _sprite_of(plant)
	plant.play_placed_flash(Vector2.ZERO)
	plant.apply_burn_material()
	assert_false(plant.is_flashing(), "burn kills the flash tween")
	var burn := sprite.material
	assert_ne(burn, _shared_wind)
	assert_eq((burn as ShaderMaterial).shader.resource_path, "res://assets/shaders/burn_char.gdshader")

	await wait_seconds(SpawnFlash.reveal_time(1) + SpawnFlash.SETTLE + 0.1)
	assert_eq(sprite.material, burn, "no late tween end hands the sway material back")


func test_flash_refused_while_burning() -> void:
	var plant := _spawn_plant(_shared_wind)
	plant.apply_burn_material()
	var burn := _sprite_of(plant).material
	plant.play_discovery_flash()
	assert_false(plant.is_flashing())
	assert_eq(_sprite_of(plant).material, burn)


func test_second_flash_replaces_first_cleanly() -> void:
	var plant := _spawn_plant(_shared_wind)
	var sprite := _sprite_of(plant)
	plant.play_placed_flash(Vector2.ZERO)
	var first := sprite.material
	plant.play_discovery_flash()
	assert_ne(sprite.material, first, "a fresh copy per flash")
	assert_eq(float((sprite.material as ShaderMaterial).get_shader_parameter(&"reveal_amount")),
		1.0, "discovery does not inherit the arrival")
	await wait_seconds(SpawnFlash.RISE + SpawnFlash.HOLD + SpawnFlash.DISCOVER_SETTLE + 0.1)
	assert_eq(sprite.material, _shared_wind)


# ---------------------------------------------------------------------------
# Structures: the overlay
# ---------------------------------------------------------------------------

func _layer_with_one_tile() -> TileMapLayer:
	var atlas := TileSetAtlasSource.new()
	atlas.texture = _ICON
	atlas.texture_region_size = Vector2i(32, 32)
	atlas.create_tile(Vector2i.ZERO)
	var ts := TileSet.new()
	ts.tile_shape = TileSet.TILE_SHAPE_ISOMETRIC
	ts.tile_size = Vector2i(32, 16)
	var src_id: int = ts.add_source(atlas)
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	layer.y_sort_enabled = true
	layer.y_sort_origin = 96
	add_child_autofree(layer)
	layer.set_cell(Vector2i(3, 4), src_id, Vector2i.ZERO)
	return layer


func _one(layer: TileMapLayer, cell: Vector2i) -> Array[Dictionary]:
	return [{"layer": layer, "cell": cell}]


func test_overlay_owns_the_cell_then_gives_it_back() -> void:
	var layer := _layer_with_one_tile()
	var nodes := SpawnFlash.flash_layer_cells(_one(layer, Vector2i(3, 4)), Vector2i(3, 5))
	assert_eq(nodes.size(), 1)
	var node := nodes[0]
	assert_eq(node.get_parent(), layer, "overlay lives under the layer so it y-sorts with the tile")
	# Sort key = cell y + layer origin + tile origin + a hair in front; the art
	# is drawn back by the same amount (preview_spawn_flash.gd checks the pixels).
	var expected := layer.map_to_local(Vector2i(3, 4))
	expected.y += float(layer.y_sort_origin) + SpawnFlash.SORT_EPS
	assert_eq(node.position, expected)
	assert_eq(layer.get_cell_source_id(Vector2i(3, 4)), -1,
		"the overlay owns the picture: the cell is bare while it plays")
	var mat := node.material as ShaderMaterial
	assert_eq(float(mat.get_shader_parameter(&"reveal_amount")), 0.0, "starts with nothing shown")
	assert_eq(float(mat.get_shader_parameter(&"flash_amount")), 0.0, "at its real colours")

	await wait_seconds(SpawnFlash.reveal_time(1) + SpawnFlash.SETTLE + 0.1)
	assert_false(is_instance_valid(node), "overlay frees itself when the fade ends")
	assert_eq(layer.get_cell_source_id(Vector2i(3, 4)), 0, "the tile is back")
	assert_eq(layer.get_cell_atlas_coords(Vector2i(3, 4)), Vector2i.ZERO)


func test_overlay_freed_early_repaints_the_tile() -> void:
	var layer := _layer_with_one_tile()
	var node := SpawnFlash.flash_layer_cells(_one(layer, Vector2i(3, 4)), Vector2i.ZERO)[0]
	assert_eq(layer.get_cell_source_id(Vector2i(3, 4)), -1)
	node.free()
	assert_eq(layer.get_cell_source_id(Vector2i(3, 4)), 0, "leaving the tree repaints the cell")


func test_overlay_does_not_repaint_over_a_newer_tile() -> void:
	var layer := _layer_with_one_tile()
	var node := SpawnFlash.flash_layer_cells(_one(layer, Vector2i(3, 4)), Vector2i.ZERO)[0]
	# Something else painted the cell meanwhile (a fence turning): keep theirs.
	layer.set_cell(Vector2i(3, 4), 0, Vector2i.ZERO)
	node.free()
	assert_eq(layer.get_cell_source_id(Vector2i(3, 4)), 0)


func test_group_shares_one_material_and_sweeps_from_the_near_cell() -> void:
	var layer := _layer_with_one_tile()
	layer.set_cell(Vector2i(3, 6), 0, Vector2i.ZERO)
	layer.set_cell(Vector2i(3, 8), 0, Vector2i.ZERO)
	var entries: Array[Dictionary] = [
		{"layer": layer, "cell": Vector2i(3, 8)},
		{"layer": layer, "cell": Vector2i(3, 4)},
		{"layer": layer, "cell": Vector2i(3, 6)},
	]
	var nodes := SpawnFlash.flash_layer_cells(entries, Vector2i(3, 3))
	assert_eq(nodes.size(), 3)
	assert_eq(nodes[0].material, nodes[1].material)
	assert_eq(nodes[1].material, nodes[2].material, "one material, one sweep")
	var mat := nodes[0].material as ShaderMaterial
	assert_eq(mat.get_shader_parameter(&"reveal_from"), layer.to_global(layer.map_to_local(Vector2i(3, 4))),
		"sweep starts at the cell nearest the player")
	assert_eq(mat.get_shader_parameter(&"reveal_to"), layer.to_global(layer.map_to_local(Vector2i(3, 8))),
		"and ends at the furthest")
	for n: SpawnFlash in nodes:
		n.free()
	for c: Vector2i in [Vector2i(3, 4), Vector2i(3, 6), Vector2i(3, 8)]:
		assert_eq(layer.get_cell_source_id(c), 0, "every cell repainted")


func test_flash_on_empty_cells_spawns_nothing() -> void:
	var layer := _layer_with_one_tile()
	assert_eq(SpawnFlash.flash_layer_cells(_one(layer, Vector2i(9, 9)), Vector2i.ZERO).size(), 0)
	assert_eq(SpawnFlash.flash_layer_cells(_one(null, Vector2i.ZERO), Vector2i.ZERO).size(), 0)
