extends GutTest

# ===========================================================================
# StructurePlacer — paint/erase routing to the correct Structures layer
# ===========================================================================
#
# We build a real StructureLayerManager with its _by_altitude / _preview_by_altitude
# dicts injected directly (the _ready() setup requires a full scene graph we
# don't want to reconstruct here). The placer routes to those layers via the
# SLM's public queries.
#
# Each painted tile_set has a real TileKindIndex-compatible atlas so the
# placer's internal scan succeeds or fails as intended.


const _TILE_KIND_FIELD: String = "tile_kind"
const _TILE_SIZE: Vector2i = Vector2i(16, 16)
const _SOURCE_ID: int = 7
const _FLAT_COORD: Vector2i = Vector2i(0, 0)

var slm: StructureLayerManager
var tile_set: TileSet
var real_layer: TileMapLayer
var preview_layer: TileMapLayer


func before_each() -> void:
	tile_set = _build_tile_set([&"FLAT", &"HALF_CUBE"])

	slm = StructureLayerManager.new()
	slm.structures_source_id = _SOURCE_ID

	real_layer = TileMapLayer.new()
	real_layer.tile_set = tile_set
	add_child_autofree(real_layer)
	slm._by_altitude[0] = real_layer

	preview_layer = TileMapLayer.new()
	preview_layer.tile_set = tile_set
	add_child_autofree(preview_layer)
	slm._preview_by_altitude[0] = preview_layer


func after_each() -> void:
	# Clear references so after_each doesn't double-free Nodes that
	# add_child_autofree already owns.
	slm._by_altitude.clear()
	slm._preview_by_altitude.clear()
	slm.free()


# ---------------------------------------------------------------------------
# TileSet builder (custom data layer + one tile per kind)
# ---------------------------------------------------------------------------

func _build_tile_set(kinds: Array[StringName]) -> TileSet:
	var ts := TileSet.new()
	ts.tile_size = _TILE_SIZE
	ts.add_custom_data_layer()
	ts.set_custom_data_layer_name(0, _TILE_KIND_FIELD)
	ts.set_custom_data_layer_type(0, TYPE_STRING)

	var src := TileSetAtlasSource.new()
	var image := Image.create(_TILE_SIZE.x * 8, _TILE_SIZE.y * 8, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	src.texture = ImageTexture.create_from_image(image)
	src.texture_region_size = _TILE_SIZE
	ts.add_source(src, _SOURCE_ID)

	var i := 0
	for k in kinds:
		var coord := Vector2i(i, 0)
		src.create_tile(coord)
		src.get_tile_data(coord, 0).set_custom_data_by_layer_id(0, String(k))
		i += 1
	return ts


# ===========================================================================
# paint() — happy path
# ===========================================================================

func test_paint_writes_cell_to_layer() -> void:
	var placer := StructurePlacer.new(slm)
	var cell := Vector2i(3, 2)
	assert_true(placer.paint(cell, TileSlots.FLAT, 0))
	assert_eq(real_layer.get_cell_source_id(cell), _SOURCE_ID)
	assert_eq(real_layer.get_cell_atlas_coords(cell), _FLAT_COORD)


func test_paint_preview_routes_to_preview_layer() -> void:
	var placer := StructurePlacer.new(slm, true)
	var cell := Vector2i(1, 1)
	assert_true(placer.paint(cell, TileSlots.FLAT, 0))

	# Preview layer received the tile; the real layer did not.
	assert_eq(preview_layer.get_cell_source_id(cell), _SOURCE_ID)
	assert_eq(real_layer.get_cell_source_id(cell), -1,
		"non-preview layer should be untouched")


func test_paint_multiple_cells_same_tileset() -> void:
	# Second paint should hit the cached TileKindIndex (no rescan). We can't
	# directly observe the cache, but functional correctness is the contract.
	var placer := StructurePlacer.new(slm)
	assert_true(placer.paint(Vector2i(0, 0), TileSlots.FLAT, 0))
	assert_true(placer.paint(Vector2i(1, 0), TileSlots.HALF_CUBE, 0))
	assert_eq(real_layer.get_cell_atlas_coords(Vector2i(0, 0)), Vector2i(0, 0))
	assert_eq(real_layer.get_cell_atlas_coords(Vector2i(1, 0)), Vector2i(1, 0))


# ===========================================================================
# paint() — failure paths
# ===========================================================================

func test_paint_no_slm_returns_false() -> void:
	var placer := StructurePlacer.new(null)
	assert_false(placer.paint(Vector2i(0, 0), TileSlots.FLAT, 0))


func test_paint_missing_altitude_returns_false() -> void:
	var placer := StructurePlacer.new(slm)
	# Altitude 5 has no layer in _by_altitude.
	assert_false(placer.paint(Vector2i(0, 0), TileSlots.FLAT, 5))
	# Nothing painted on our altitude-0 layer either.
	assert_eq(real_layer.get_cell_source_id(Vector2i(0, 0)), -1)


func test_paint_unknown_kind_returns_false() -> void:
	var placer := StructurePlacer.new(slm)
	# STAIR_NE wasn't painted into the tileset, so TileKindIndex has no entry.
	assert_false(placer.paint(Vector2i(0, 0), TileSlots.STAIR_NE, 0))
	assert_eq(real_layer.get_cell_source_id(Vector2i(0, 0)), -1)


func test_paint_preview_missing_altitude_returns_false() -> void:
	var placer := StructurePlacer.new(slm, true)
	assert_false(placer.paint(Vector2i(0, 0), TileSlots.FLAT, 9))


# ===========================================================================
# erase()
# ===========================================================================

func test_erase_removes_painted_cell() -> void:
	var placer := StructurePlacer.new(slm)
	var cell := Vector2i(4, 4)
	placer.paint(cell, TileSlots.FLAT, 0)
	assert_eq(real_layer.get_cell_source_id(cell), _SOURCE_ID)

	placer.erase(cell, 0)
	assert_eq(real_layer.get_cell_source_id(cell), -1)


func test_erase_missing_altitude_is_noop() -> void:
	var placer := StructurePlacer.new(slm)
	# No layer at altitude 5; must not crash.
	placer.erase(Vector2i(0, 0), 5)
	# Sanity: nothing painted elsewhere.
	assert_eq(real_layer.get_cell_source_id(Vector2i(0, 0)), -1)


func test_erase_no_slm_is_noop() -> void:
	var placer := StructurePlacer.new(null)
	placer.erase(Vector2i(0, 0), 0)
	# No observable state to check — just assert we got here without crashing.
	pass_test("erase with null SLM did not crash")


func test_erase_preview_mode_erases_from_preview_layer() -> void:
	var placer := StructurePlacer.new(slm, true)
	var cell := Vector2i(2, 2)
	placer.paint(cell, TileSlots.FLAT, 0)
	assert_eq(preview_layer.get_cell_source_id(cell), _SOURCE_ID)

	placer.erase(cell, 0)
	assert_eq(preview_layer.get_cell_source_id(cell), -1)


# ===========================================================================
# layer_for()
# ===========================================================================

func test_layer_for_returns_real_layer() -> void:
	var placer := StructurePlacer.new(slm)
	assert_eq(placer.layer_for(0), real_layer)


func test_layer_for_returns_preview_in_preview_mode() -> void:
	var placer := StructurePlacer.new(slm, true)
	assert_eq(placer.layer_for(0), preview_layer)


func test_layer_for_missing_altitude_returns_null() -> void:
	var placer := StructurePlacer.new(slm)
	assert_null(placer.layer_for(42))


func test_layer_for_no_slm_returns_null() -> void:
	var placer := StructurePlacer.new(null)
	assert_null(placer.layer_for(0))
