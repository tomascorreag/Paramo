extends GutTest

# ===========================================================================
# TileKindIndex — atlas scan and slot lookup
# ===========================================================================
#
# We build a synthetic TileSet + TileSetAtlasSource at runtime (no scene,
# no on-disk resource) so the test is hermetic. The atlas source is
# registered under source id 0; each test paints the tiles it needs via
# _paint() before constructing the index.
#
# TileKindIndex also cross-validates against TileSlots on _init(); tests that
# deliberately mismatch will emit push_warning() lines in GUT output. Those
# are expected and do not fail the tests.

const _TILE_KIND_FIELD: String = "tile_kind"
const _SOURCE_ID: int = 0
const _TILE_SIZE: Vector2i = Vector2i(16, 16)

var tile_set: TileSet
var source: TileSetAtlasSource


func before_each() -> void:
	tile_set = TileSet.new()
	tile_set.tile_size = _TILE_SIZE

	tile_set.add_custom_data_layer()
	tile_set.set_custom_data_layer_name(0, _TILE_KIND_FIELD)
	tile_set.set_custom_data_layer_type(0, TYPE_STRING)

	source = TileSetAtlasSource.new()
	var image := Image.create(_TILE_SIZE.x * 4, _TILE_SIZE.y * 4, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	source.texture = ImageTexture.create_from_image(image)
	source.texture_region_size = _TILE_SIZE
	tile_set.add_source(source, _SOURCE_ID)


# ---------------------------------------------------------------------------
# Helper: paint a tile at `coord` with the given kind string.
# ---------------------------------------------------------------------------

func _paint(coord: Vector2i, kind: String) -> void:
	source.create_tile(coord)
	var data := source.get_tile_data(coord, 0)
	data.set_custom_data_by_layer_id(0, kind)


# ===========================================================================
# coord() / has() — happy path
# ===========================================================================

func test_coord_matches_painted_entry() -> void:
	_paint(Vector2i(0, 0), "FLAT")
	_paint(Vector2i(1, 0), "SLOPE_NE")
	var idx := TileKindIndex.new(tile_set, _SOURCE_ID)
	assert_eq(idx.coord(TileSlots.FLAT), Vector2i(0, 0))
	assert_eq(idx.coord(TileSlots.SLOPE_NE), Vector2i(1, 0))


func test_has_true_for_painted() -> void:
	_paint(Vector2i(2, 3), "FLAT")
	var idx := TileKindIndex.new(tile_set, _SOURCE_ID)
	assert_true(idx.has(TileSlots.FLAT))


func test_has_false_for_unpainted() -> void:
	_paint(Vector2i(0, 0), "FLAT")
	var idx := TileKindIndex.new(tile_set, _SOURCE_ID)
	assert_false(idx.has(TileSlots.SLOPE_NE))


func test_coord_unpainted_returns_unset() -> void:
	var idx := TileKindIndex.new(tile_set, _SOURCE_ID)
	var c := idx.coord(TileSlots.FLAT)
	assert_true(TileKindIndex.is_unset(c), "expected unset sentinel, got %s" % c)


# ===========================================================================
# all_painted_names / source_id / is_unset
# ===========================================================================

func test_all_painted_names_returns_painted_slots() -> void:
	_paint(Vector2i(0, 0), "FLAT")
	_paint(Vector2i(1, 0), "HALF_CUBE")
	_paint(Vector2i(2, 0), "STAIR_NE")
	var idx := TileKindIndex.new(tile_set, _SOURCE_ID)
	var names := idx.all_painted_names()
	assert_eq(names.size(), 3)
	assert_has(names, TileSlots.FLAT)
	assert_has(names, TileSlots.HALF_CUBE)
	assert_has(names, TileSlots.STAIR_NE)


func test_source_id_getter() -> void:
	var idx := TileKindIndex.new(tile_set, _SOURCE_ID)
	assert_eq(idx.source_id(), _SOURCE_ID)


func test_is_unset_sentinel() -> void:
	assert_true(TileKindIndex.is_unset(Vector2i(-1, -1)))
	assert_true(TileKindIndex.is_unset(Vector2i(-1, 0)))
	assert_true(TileKindIndex.is_unset(Vector2i(0, -1)))
	assert_false(TileKindIndex.is_unset(Vector2i(0, 0)))
	assert_false(TileKindIndex.is_unset(Vector2i(5, 3)))


# ===========================================================================
# Duplicate handling
# ===========================================================================

func test_duplicate_tile_kind_keeps_first() -> void:
	# Two atlas coords both tagged "FLAT". Scan order is create_tile order, so
	# (0, 0) wins and (1, 0) is ignored with a warning.
	_paint(Vector2i(0, 0), "FLAT")
	_paint(Vector2i(1, 0), "FLAT")
	var idx := TileKindIndex.new(tile_set, _SOURCE_ID)
	assert_eq(idx.coord(TileSlots.FLAT), Vector2i(0, 0))
	# Only one entry registered despite two paints.
	assert_eq(idx.all_painted_names().size(), 1)


# ===========================================================================
# Skipped inputs (no crash, no entry)
# ===========================================================================

func test_empty_tile_kind_string_is_skipped() -> void:
	_paint(Vector2i(0, 0), "")
	_paint(Vector2i(1, 0), "FLAT")
	var idx := TileKindIndex.new(tile_set, _SOURCE_ID)
	assert_eq(idx.all_painted_names().size(), 1)
	assert_eq(idx.coord(TileSlots.FLAT), Vector2i(1, 0))


func test_tile_without_custom_data_set_is_skipped() -> void:
	# create_tile without set_custom_data_by_layer_id: the custom data value
	# defaults to "" (TYPE_STRING), which the scan treats as "no entry".
	source.create_tile(Vector2i(0, 0))
	_paint(Vector2i(1, 0), "FLAT")
	var idx := TileKindIndex.new(tile_set, _SOURCE_ID)
	assert_eq(idx.all_painted_names().size(), 1)


# ===========================================================================
# Error paths — index stays empty, no crash
# ===========================================================================

func test_null_tile_set_leaves_index_empty() -> void:
	var idx := TileKindIndex.new(null, _SOURCE_ID)
	assert_eq(idx.all_painted_names().size(), 0)
	assert_false(idx.has(TileSlots.FLAT))


func test_missing_source_id_leaves_index_empty() -> void:
	# Source 99 was never registered on tile_set.
	var idx := TileKindIndex.new(tile_set, 99)
	assert_eq(idx.all_painted_names().size(), 0)


func test_missing_custom_data_layer_leaves_index_empty() -> void:
	# Rebuild tile_set WITHOUT the tile_kind custom data layer.
	var bare_set := TileSet.new()
	bare_set.tile_size = _TILE_SIZE
	var bare_source := TileSetAtlasSource.new()
	var image := Image.create(_TILE_SIZE.x * 2, _TILE_SIZE.y * 2, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	bare_source.texture = ImageTexture.create_from_image(image)
	bare_source.texture_region_size = _TILE_SIZE
	bare_set.add_source(bare_source, _SOURCE_ID)
	bare_source.create_tile(Vector2i(0, 0))

	var idx := TileKindIndex.new(bare_set, _SOURCE_ID)
	assert_eq(idx.all_painted_names().size(), 0)
	assert_false(idx.has(TileSlots.FLAT))
