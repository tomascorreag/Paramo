extends GutTest

# ===========================================================================
# TileSlots <-> TileGrid._SHAPES cross-validation
# ===========================================================================

# Collect all StringName constants from TileSlots.
func _get_slot_constants() -> Dictionary:
	var script: Script = load("res://scripts/data/tile_slots.gd")
	var constants: Dictionary = script.get_script_constant_map()
	var result: Dictionary = {}  # StringName -> const_name (String)
	for const_name: String in constants:
		var val: Variant = constants[const_name]
		if val is StringName:
			result[val as StringName] = const_name
	return result


func test_all_shapes_have_slot_constant() -> void:
	var slots := _get_slot_constants()
	for kind: StringName in TileGrid._SHAPES:
		assert_true(slots.has(kind),
			"TileGrid._SHAPES key '%s' has no matching TileSlots constant" % kind)


func test_no_duplicate_slot_values() -> void:
	var script: Script = load("res://scripts/data/tile_slots.gd")
	var constants: Dictionary = script.get_script_constant_map()
	var seen: Dictionary = {}
	for const_name: String in constants:
		var val: Variant = constants[const_name]
		if not (val is StringName):
			continue
		var sn: StringName = val as StringName
		assert_false(seen.has(sn),
			"Duplicate StringName value '%s' in TileSlots (const %s)" % [sn, const_name])
		seen[sn] = const_name


func test_non_walkable_slots_not_in_shapes() -> void:
	var non_walkable: Array[StringName] = [
		TileSlots.WALL_NW, TileSlots.WALL_NE, TileSlots.WALL_SE, TileSlots.WALL_SW,
		TileSlots.EDGE_NW, TileSlots.EDGE_NE, TileSlots.EDGE_SE, TileSlots.EDGE_SW,
	]
	for kind in non_walkable:
		assert_false(TileGrid._SHAPES.has(kind),
			"Non-walkable slot '%s' should NOT be in _SHAPES" % kind)


func test_rise_direction_consistency() -> void:
	# Expected: suffix -> rise vector
	var expected_rise: Dictionary = {
		"NE": Vector2i(0, -1),
		"NW": Vector2i(-1, 0),
		"SE": Vector2i(1, 0),
		"SW": Vector2i(0, 1),
	}
	for kind: StringName in TileGrid._SHAPES:
		var shape: Dictionary = TileGrid._SHAPES[kind]
		var rise: Vector2i = shape["rise"]
		if rise == Vector2i.ZERO:
			continue  # flats, skip
		var kind_str: String = String(kind)
		var suffix := kind_str.get_slice("_", kind_str.count("_"))
		assert_true(expected_rise.has(suffix),
			"Unknown directional suffix '%s' in shape '%s'" % [suffix, kind])
		assert_eq(rise, expected_rise[suffix],
			"Shape '%s' rise %s doesn't match expected for suffix %s" % [kind, rise, suffix])
