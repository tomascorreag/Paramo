extends GutTest

# ===========================================================================
# StructureLayerManager — pure math + lookup queries
# ===========================================================================
#
# We do NOT exercise _ready() here: it requires a full scene graph (Pathfinder,
# world Node2D, tile_set) and adds/frees real TileMapLayers. Instead we cover:
#   - static _alt_suffix() formatting
#   - layer/altitude lookup queries with _by_altitude populated directly
#
# Visual tint helpers are intentionally skipped (presentation, not logic).


var slm: StructureLayerManager


func before_each() -> void:
	slm = StructureLayerManager.new()


func after_each() -> void:
	# Free any layers we injected into the dicts — they're Nodes but not in
	# the scene tree, so .free() is safe.
	for layer in slm._by_altitude.values():
		if layer != null:
			layer.free()
	for layer in slm._preview_by_altitude.values():
		if layer != null:
			layer.free()
	slm.free()


# ===========================================================================
# _alt_suffix — static formatter, Godot node names can't contain "-"
# ===========================================================================

func test_alt_suffix_zero() -> void:
	assert_eq(StructureLayerManager._alt_suffix(0), "0")


func test_alt_suffix_positive() -> void:
	assert_eq(StructureLayerManager._alt_suffix(1), "1")
	assert_eq(StructureLayerManager._alt_suffix(5), "5")
	assert_eq(StructureLayerManager._alt_suffix(42), "42")


func test_alt_suffix_negative_uses_n_prefix() -> void:
	assert_eq(StructureLayerManager._alt_suffix(-1), "N1")
	assert_eq(StructureLayerManager._alt_suffix(-3), "N3")
	assert_eq(StructureLayerManager._alt_suffix(-99), "N99")


func test_alt_suffix_never_contains_hyphen() -> void:
	# Godot forbids "-" in node names; regression test.
	for alt in range(-10, 11):
		var s := StructureLayerManager._alt_suffix(alt)
		assert_false(s.contains("-"),
			"_alt_suffix(%d) = '%s' contains forbidden '-'" % [alt, s])


# ===========================================================================
# layer_for_altitude / has_layer / known_altitudes
# ===========================================================================

func test_layer_for_altitude_unknown_returns_null() -> void:
	assert_null(slm.layer_for_altitude(0))
	assert_null(slm.layer_for_altitude(-5))


func test_layer_for_altitude_returns_injected_layer() -> void:
	var layer := TileMapLayer.new()
	slm._by_altitude[3] = layer
	assert_eq(slm.layer_for_altitude(3), layer)


func test_preview_layer_for_altitude_returns_injected_layer() -> void:
	var preview := TileMapLayer.new()
	slm._preview_by_altitude[2] = preview
	assert_eq(slm.preview_layer_for_altitude(2), preview)


func test_preview_layer_for_altitude_unknown_returns_null() -> void:
	assert_null(slm.preview_layer_for_altitude(7))


func test_has_layer_true_for_injected() -> void:
	slm._by_altitude[0] = TileMapLayer.new()
	slm._by_altitude[2] = TileMapLayer.new()
	assert_true(slm.has_layer(0))
	assert_true(slm.has_layer(2))


func test_has_layer_false_for_missing() -> void:
	slm._by_altitude[0] = TileMapLayer.new()
	assert_false(slm.has_layer(1))
	assert_false(slm.has_layer(-1))


func test_known_altitudes_empty_when_no_layers() -> void:
	assert_eq(slm.known_altitudes().size(), 0)


func test_known_altitudes_returns_sorted_ascending() -> void:
	slm._by_altitude[4] = TileMapLayer.new()
	slm._by_altitude[-1] = TileMapLayer.new()
	slm._by_altitude[0] = TileMapLayer.new()
	slm._by_altitude[2] = TileMapLayer.new()
	assert_eq(slm.known_altitudes(), [-1, 0, 2, 4] as Array[int])
