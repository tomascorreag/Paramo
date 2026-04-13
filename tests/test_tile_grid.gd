extends GutTest

var grid: TileGrid


func before_each() -> void:
	grid = TileGrid.new()


# ---------------------------------------------------------------------------
# Helper: inject a cell directly into grid._cells
# ---------------------------------------------------------------------------

func _inject_walkable(
	cell: Vector2i,
	tile_kind: StringName,
	rise_dir: Vector2i,
	alt_low: int,
	alt_high: int
) -> void:
	grid._cells[cell] = {
		"walkable": true,
		"layer": null,
		"tile_kind": tile_kind,
		"rise_dir": rise_dir,
		"altitude_low": alt_low,
		"altitude_high": alt_high,
		"altitude_center": (alt_low + alt_high) / 2.0,
	}


func _inject_blocked(cell: Vector2i, altitude: int) -> void:
	grid._cells[cell] = {
		"walkable": false,
		"layer": null,
		"tile_kind": &"",
		"rise_dir": Vector2i.ZERO,
		"altitude_low": altitude,
		"altitude_high": altitude,
		"altitude_center": float(altitude),
	}


# ===========================================================================
# _SHAPES constant integrity
# ===========================================================================

func test_shapes_all_have_ramp_size() -> void:
	for kind: StringName in TileGrid._SHAPES:
		var shape: Dictionary = TileGrid._SHAPES[kind]
		assert_has(shape, "ramp_size", "Shape '%s' missing 'ramp_size'" % kind)
		assert_typeof(shape["ramp_size"], TYPE_INT, "Shape '%s' ramp_size not int" % kind)


func test_shapes_all_have_rise() -> void:
	for kind: StringName in TileGrid._SHAPES:
		var shape: Dictionary = TileGrid._SHAPES[kind]
		assert_has(shape, "rise", "Shape '%s' missing 'rise'" % kind)
		assert_true(shape["rise"] is Vector2i, "Shape '%s' rise not Vector2i" % kind)


func test_shapes_flat_kinds_zero_rise_and_size() -> void:
	var flats: Array[StringName] = [&"FLAT", &"FULL_CUBE", &"HALF_CUBE"]
	for kind in flats:
		assert_true(TileGrid._SHAPES.has(kind), "Missing flat shape: %s" % kind)
		var shape: Dictionary = TileGrid._SHAPES[kind]
		assert_eq(shape["ramp_size"], 0, "%s ramp_size should be 0" % kind)
		assert_eq(shape["rise"], Vector2i.ZERO, "%s rise should be ZERO" % kind)


func test_shapes_full_ramps_have_size_2() -> void:
	var full_ramps: Array[StringName] = [
		&"SLOPE_NE", &"SLOPE_NW", &"SLOPE_SE", &"SLOPE_SW",
		&"STAIR_NE", &"STAIR_NW", &"STAIR_SE", &"STAIR_SW",
	]
	for kind in full_ramps:
		assert_true(TileGrid._SHAPES.has(kind), "Missing full ramp: %s" % kind)
		assert_eq(TileGrid._SHAPES[kind]["ramp_size"], 2, "%s ramp_size should be 2" % kind)


func test_shapes_half_ramps_have_size_1() -> void:
	var half_ramps: Array[StringName] = [
		&"HALF_SLOPE_NE", &"HALF_SLOPE_NW", &"HALF_SLOPE_SE", &"HALF_SLOPE_SW",
		&"HALF_STAIR_NE", &"HALF_STAIR_NW", &"HALF_STAIR_SE", &"HALF_STAIR_SW",
	]
	for kind in half_ramps:
		assert_true(TileGrid._SHAPES.has(kind), "Missing half ramp: %s" % kind)
		assert_eq(TileGrid._SHAPES[kind]["ramp_size"], 1, "%s ramp_size should be 1" % kind)


func test_shapes_rise_directions_are_unit_vectors() -> void:
	for kind: StringName in TileGrid._SHAPES:
		var rise: Vector2i = TileGrid._SHAPES[kind]["rise"]
		if rise != Vector2i.ZERO:
			var manhattan: int = abs(rise.x) + abs(rise.y)
			assert_eq(manhattan, 1, "Shape '%s' rise %s is not a unit vector" % [kind, rise])


func test_shapes_count() -> void:
	# 3 flats + 8 full ramps + 8 half ramps = 19
	assert_eq(TileGrid._SHAPES.size(), 19)


# ===========================================================================
# is_walkable
# ===========================================================================

func test_is_walkable_empty_grid() -> void:
	assert_false(grid.is_walkable(Vector2i(0, 0)))


func test_is_walkable_walkable_cell() -> void:
	_inject_walkable(Vector2i(0, 0), &"FLAT", Vector2i.ZERO, 0, 0)
	assert_true(grid.is_walkable(Vector2i(0, 0)))


func test_is_walkable_blocked_cell() -> void:
	_inject_blocked(Vector2i(0, 0), 0)
	assert_false(grid.is_walkable(Vector2i(0, 0)))


func test_is_walkable_nonexistent_cell() -> void:
	_inject_walkable(Vector2i(0, 0), &"FLAT", Vector2i.ZERO, 0, 0)
	assert_false(grid.is_walkable(Vector2i(99, 99)))


# ===========================================================================
# altitude_center
# ===========================================================================

func test_altitude_center_flat() -> void:
	_inject_walkable(Vector2i(0, 0), &"FLAT", Vector2i.ZERO, 4, 4)
	assert_eq(grid.altitude_center(Vector2i(0, 0)), 4.0)


func test_altitude_center_full_ramp() -> void:
	_inject_walkable(Vector2i(0, 0), &"SLOPE_NE", Vector2i(0, -1), 0, 2)
	assert_eq(grid.altitude_center(Vector2i(0, 0)), 1.0)


func test_altitude_center_half_ramp() -> void:
	_inject_walkable(Vector2i(0, 0), &"HALF_SLOPE_NE", Vector2i(0, -1), 2, 3)
	assert_eq(grid.altitude_center(Vector2i(0, 0)), 2.5)


func test_altitude_center_missing_cell() -> void:
	assert_eq(grid.altitude_center(Vector2i(0, 0)), 0.0)


# ===========================================================================
# exit_altitude
# ===========================================================================

func test_exit_altitude_flat_all_dirs() -> void:
	_inject_walkable(Vector2i(0, 0), &"FLAT", Vector2i.ZERO, 4, 4)
	var dirs: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	]
	for d in dirs:
		assert_eq(grid.exit_altitude(Vector2i(0, 0), d), 4,
			"Flat exit toward %s should be 4" % d)


func test_exit_altitude_ramp_rise_dir() -> void:
	# SLOPE_NE: rise = (0, -1), low=0, high=2
	_inject_walkable(Vector2i(0, 0), &"SLOPE_NE", Vector2i(0, -1), 0, 2)
	assert_eq(grid.exit_altitude(Vector2i(0, 0), Vector2i(0, -1)), 2)


func test_exit_altitude_ramp_anti_rise() -> void:
	_inject_walkable(Vector2i(0, 0), &"SLOPE_NE", Vector2i(0, -1), 0, 2)
	assert_eq(grid.exit_altitude(Vector2i(0, 0), Vector2i(0, 1)), 0)


func test_exit_altitude_ramp_perpendicular() -> void:
	_inject_walkable(Vector2i(0, 0), &"SLOPE_NE", Vector2i(0, -1), 0, 2)
	assert_eq(grid.exit_altitude(Vector2i(0, 0), Vector2i(1, 0)), -9999)
	assert_eq(grid.exit_altitude(Vector2i(0, 0), Vector2i(-1, 0)), -9999)


func test_exit_altitude_blocked_cell() -> void:
	_inject_blocked(Vector2i(0, 0), 4)
	assert_eq(grid.exit_altitude(Vector2i(0, 0), Vector2i(1, 0)), -9999)


func test_exit_altitude_missing_cell() -> void:
	assert_eq(grid.exit_altitude(Vector2i(99, 99), Vector2i(1, 0)), -9999)


# ===========================================================================
# enter_altitude
# ===========================================================================

func test_enter_altitude_flat_all_dirs() -> void:
	_inject_walkable(Vector2i(0, 0), &"FLAT", Vector2i.ZERO, 4, 4)
	var dirs: Array[Vector2i] = [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	]
	for d in dirs:
		assert_eq(grid.enter_altitude(Vector2i(0, 0), d), 4,
			"Flat enter from %s should be 4" % d)


func test_enter_altitude_ramp_from_rise_dir() -> void:
	# SLOPE_NE: rise = (0, -1). Entering from rise dir means approaching
	# from the low side -> enter at low end.
	_inject_walkable(Vector2i(0, 0), &"SLOPE_NE", Vector2i(0, -1), 0, 2)
	assert_eq(grid.enter_altitude(Vector2i(0, 0), Vector2i(0, -1)), 0)


func test_enter_altitude_ramp_from_anti_rise() -> void:
	_inject_walkable(Vector2i(0, 0), &"SLOPE_NE", Vector2i(0, -1), 0, 2)
	assert_eq(grid.enter_altitude(Vector2i(0, 0), Vector2i(0, 1)), 2)


func test_enter_altitude_ramp_perpendicular() -> void:
	_inject_walkable(Vector2i(0, 0), &"SLOPE_NE", Vector2i(0, -1), 0, 2)
	assert_eq(grid.enter_altitude(Vector2i(0, 0), Vector2i(1, 0)), -9999)


func test_enter_altitude_blocked_cell() -> void:
	_inject_blocked(Vector2i(0, 0), 4)
	assert_eq(grid.enter_altitude(Vector2i(0, 0), Vector2i(1, 0)), -9999)


# ===========================================================================
# can_transition
# ===========================================================================

func test_can_transition_flat_to_flat_same_alt() -> void:
	_inject_walkable(Vector2i(0, 0), &"FLAT", Vector2i.ZERO, 4, 4)
	_inject_walkable(Vector2i(1, 0), &"FLAT", Vector2i.ZERO, 4, 4)
	assert_true(grid.can_transition(Vector2i(0, 0), Vector2i(1, 0)))


func test_can_transition_flat_to_flat_different_alt() -> void:
	_inject_walkable(Vector2i(0, 0), &"FLAT", Vector2i.ZERO, 4, 4)
	_inject_walkable(Vector2i(1, 0), &"FLAT", Vector2i.ZERO, 6, 6)
	assert_false(grid.can_transition(Vector2i(0, 0), Vector2i(1, 0)))


func test_can_transition_flat_to_ramp_matching() -> void:
	# Flat at alt 0. Adjacent SLOPE_NE (rise=(0,-1), low=0, high=2).
	# Step from (0,0) to (0,-1): dir = (0,-1).
	# exit_altitude(flat, (0,-1)) = 0 (flat always returns low).
	# enter_altitude(ramp, (0,-1)) = 0 (from_dir == rise -> low).
	# 0 == 0 -> allowed.
	_inject_walkable(Vector2i(0, 0), &"FLAT", Vector2i.ZERO, 0, 0)
	_inject_walkable(Vector2i(0, -1), &"SLOPE_NE", Vector2i(0, -1), 0, 2)
	assert_true(grid.can_transition(Vector2i(0, 0), Vector2i(0, -1)))


func test_can_transition_flat_to_ramp_mismatch() -> void:
	# Flat at alt 0. Ramp with low=2 (altitude mismatch).
	_inject_walkable(Vector2i(0, 0), &"FLAT", Vector2i.ZERO, 0, 0)
	_inject_walkable(Vector2i(0, -1), &"SLOPE_NE", Vector2i(0, -1), 2, 4)
	assert_false(grid.can_transition(Vector2i(0, 0), Vector2i(0, -1)))


func test_can_transition_ramp_to_flat_matching() -> void:
	# SLOPE_NE at (0,0): rise=(0,-1), low=0, high=2.
	# Flat at (0,-1) at alt 2.
	# Step dir = (0,-1) = rise dir.
	# exit_altitude(ramp, rise) = high = 2.
	# enter_altitude(flat, (0,-1)) = 2.
	# 2 == 2 -> allowed.
	_inject_walkable(Vector2i(0, 0), &"SLOPE_NE", Vector2i(0, -1), 0, 2)
	_inject_walkable(Vector2i(0, -1), &"FLAT", Vector2i.ZERO, 2, 2)
	assert_true(grid.can_transition(Vector2i(0, 0), Vector2i(0, -1)))


func test_can_transition_chained_ramps() -> void:
	# Two SLOPE_NE ramps chained: first low=0,high=2; second low=2,high=4.
	# Step from (0,0) to (0,-1): dir = (0,-1) = rise.
	# exit first in rise dir = 2. enter second from rise dir = 2.
	_inject_walkable(Vector2i(0, 0), &"SLOPE_NE", Vector2i(0, -1), 0, 2)
	_inject_walkable(Vector2i(0, -1), &"SLOPE_NE", Vector2i(0, -1), 2, 4)
	assert_true(grid.can_transition(Vector2i(0, 0), Vector2i(0, -1)))


func test_can_transition_non_adjacent() -> void:
	_inject_walkable(Vector2i(0, 0), &"FLAT", Vector2i.ZERO, 0, 0)
	_inject_walkable(Vector2i(2, 0), &"FLAT", Vector2i.ZERO, 0, 0)
	assert_false(grid.can_transition(Vector2i(0, 0), Vector2i(2, 0)))


func test_can_transition_diagonal() -> void:
	_inject_walkable(Vector2i(0, 0), &"FLAT", Vector2i.ZERO, 0, 0)
	_inject_walkable(Vector2i(1, 1), &"FLAT", Vector2i.ZERO, 0, 0)
	assert_false(grid.can_transition(Vector2i(0, 0), Vector2i(1, 1)))


func test_can_transition_source_blocked() -> void:
	_inject_blocked(Vector2i(0, 0), 0)
	_inject_walkable(Vector2i(1, 0), &"FLAT", Vector2i.ZERO, 0, 0)
	assert_false(grid.can_transition(Vector2i(0, 0), Vector2i(1, 0)))


func test_can_transition_dest_blocked() -> void:
	_inject_walkable(Vector2i(0, 0), &"FLAT", Vector2i.ZERO, 0, 0)
	_inject_blocked(Vector2i(1, 0), 0)
	assert_false(grid.can_transition(Vector2i(0, 0), Vector2i(1, 0)))


func test_can_transition_perpendicular_ramp_exit() -> void:
	# SLOPE_NE at (0,0): rise=(0,-1). Try to exit toward (1,0) — perpendicular.
	_inject_walkable(Vector2i(0, 0), &"SLOPE_NE", Vector2i(0, -1), 0, 2)
	_inject_walkable(Vector2i(1, 0), &"FLAT", Vector2i.ZERO, 1, 1)
	assert_false(grid.can_transition(Vector2i(0, 0), Vector2i(1, 0)))


func test_can_transition_bidirectional_flat() -> void:
	_inject_walkable(Vector2i(0, 0), &"FLAT", Vector2i.ZERO, 4, 4)
	_inject_walkable(Vector2i(1, 0), &"FLAT", Vector2i.ZERO, 4, 4)
	assert_true(grid.can_transition(Vector2i(0, 0), Vector2i(1, 0)))
	assert_true(grid.can_transition(Vector2i(1, 0), Vector2i(0, 0)))


func test_can_transition_ramp_is_bidirectional() -> void:
	# Walk up and down a ramp should both work.
	_inject_walkable(Vector2i(0, 0), &"FLAT", Vector2i.ZERO, 0, 0)
	_inject_walkable(Vector2i(0, -1), &"SLOPE_NE", Vector2i(0, -1), 0, 2)
	# Up: flat(0,0) -> ramp(0,-1)
	assert_true(grid.can_transition(Vector2i(0, 0), Vector2i(0, -1)))
	# Down: ramp(0,-1) -> flat(0,0). dir=(0,1)=-rise. exit=low=0. enter flat=0.
	assert_true(grid.can_transition(Vector2i(0, -1), Vector2i(0, 0)))


# ===========================================================================
# _merge_walkable
# ===========================================================================

func test_merge_walkable_first_entry() -> void:
	var entry := {
		"walkable": true, "layer": null, "tile_kind": &"FLAT",
		"rise_dir": Vector2i.ZERO, "altitude_low": 0, "altitude_high": 0,
		"altitude_center": 0.0,
	}
	grid._merge_walkable(Vector2i(0, 0), entry)
	assert_true(grid.is_walkable(Vector2i(0, 0)))


func test_merge_walkable_higher_wins() -> void:
	_inject_walkable(Vector2i(0, 0), &"FLAT", Vector2i.ZERO, 0, 2)
	var higher := {
		"walkable": true, "layer": null, "tile_kind": &"FLAT",
		"rise_dir": Vector2i.ZERO, "altitude_low": 4, "altitude_high": 4,
		"altitude_center": 4.0,
	}
	grid._merge_walkable(Vector2i(0, 0), higher)
	assert_eq(grid.altitude_center(Vector2i(0, 0)), 4.0)


func test_merge_walkable_lower_loses() -> void:
	_inject_walkable(Vector2i(0, 0), &"FLAT", Vector2i.ZERO, 4, 4)
	var lower := {
		"walkable": true, "layer": null, "tile_kind": &"FLAT",
		"rise_dir": Vector2i.ZERO, "altitude_low": 0, "altitude_high": 2,
		"altitude_center": 1.0,
	}
	grid._merge_walkable(Vector2i(0, 0), lower)
	assert_eq(grid.altitude_center(Vector2i(0, 0)), 4.0)


func test_merge_walkable_equal_keeps_first() -> void:
	_inject_walkable(Vector2i(0, 0), &"FLAT", Vector2i.ZERO, 4, 4)
	var same := {
		"walkable": true, "layer": null, "tile_kind": &"FULL_CUBE",
		"rise_dir": Vector2i.ZERO, "altitude_low": 4, "altitude_high": 4,
		"altitude_center": 4.0,
	}
	grid._merge_walkable(Vector2i(0, 0), same)
	# First entry kept — tile_kind should still be FLAT, not FULL_CUBE.
	assert_eq(grid.cell_info(Vector2i(0, 0))["tile_kind"], &"FLAT")


func test_merge_walkable_over_lower_block() -> void:
	_inject_blocked(Vector2i(0, 0), 1)
	var walkable := {
		"walkable": true, "layer": null, "tile_kind": &"FLAT",
		"rise_dir": Vector2i.ZERO, "altitude_low": 4, "altitude_high": 4,
		"altitude_center": 4.0,
	}
	grid._merge_walkable(Vector2i(0, 0), walkable)
	assert_true(grid.is_walkable(Vector2i(0, 0)))


func test_merge_walkable_blocked_at_or_above() -> void:
	_inject_blocked(Vector2i(0, 0), 6)
	var walkable := {
		"walkable": true, "layer": null, "tile_kind": &"FLAT",
		"rise_dir": Vector2i.ZERO, "altitude_low": 4, "altitude_high": 4,
		"altitude_center": 4.0,
	}
	grid._merge_walkable(Vector2i(0, 0), walkable)
	# Block at altitude 6 >= walkable alt_high 4, so block remains.
	assert_false(grid.is_walkable(Vector2i(0, 0)))


# ===========================================================================
# _merge_blocked
# ===========================================================================

func test_merge_blocked_first_entry() -> void:
	grid._merge_blocked(Vector2i(0, 0), null, 4)
	assert_false(grid.is_walkable(Vector2i(0, 0)))


func test_merge_blocked_higher_replaces() -> void:
	_inject_blocked(Vector2i(0, 0), 2)
	grid._merge_blocked(Vector2i(0, 0), null, 4)
	assert_eq(grid.cell_info(Vector2i(0, 0))["altitude_low"], 4)


func test_merge_blocked_lower_keeps_existing() -> void:
	_inject_blocked(Vector2i(0, 0), 4)
	grid._merge_blocked(Vector2i(0, 0), null, 2)
	assert_eq(grid.cell_info(Vector2i(0, 0))["altitude_low"], 4)


func test_merge_blocked_overrides_walkable_at_or_above() -> void:
	_inject_walkable(Vector2i(0, 0), &"FLAT", Vector2i.ZERO, 4, 4)
	grid._merge_blocked(Vector2i(0, 0), null, 4)
	assert_false(grid.is_walkable(Vector2i(0, 0)))


func test_merge_blocked_does_not_override_taller_walkable() -> void:
	_inject_walkable(Vector2i(0, 0), &"FLAT", Vector2i.ZERO, 4, 6)
	grid._merge_blocked(Vector2i(0, 0), null, 4)
	assert_true(grid.is_walkable(Vector2i(0, 0)))


# ===========================================================================
# walkable_cells
# ===========================================================================

func test_walkable_cells_empty() -> void:
	assert_eq(grid.walkable_cells().size(), 0)


func test_walkable_cells_mixed() -> void:
	_inject_walkable(Vector2i(0, 0), &"FLAT", Vector2i.ZERO, 0, 0)
	_inject_walkable(Vector2i(1, 0), &"FLAT", Vector2i.ZERO, 0, 0)
	_inject_walkable(Vector2i(2, 0), &"FLAT", Vector2i.ZERO, 0, 0)
	_inject_blocked(Vector2i(3, 0), 0)
	_inject_blocked(Vector2i(4, 0), 0)
	var cells := grid.walkable_cells()
	assert_eq(cells.size(), 3)
	assert_has(cells, Vector2i(0, 0))
	assert_has(cells, Vector2i(1, 0))
	assert_has(cells, Vector2i(2, 0))
