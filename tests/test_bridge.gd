extends GutTest

# Tests for Bridge pure helpers and validator. Tree-free; uses TileGrid
# directly (same pattern as test_tile_grid.gd).


var grid: TileGrid


func before_each() -> void:
	grid = TileGrid.new()


func _inject_flat(cell: Vector2i, alt: int) -> void:
	grid._test_put(cell, CellData.make_walkable(null, &"FLAT", Vector2i.ZERO, alt, alt))


func _inject_ramp(cell: Vector2i, alt_low: int, alt_high: int, rise: Vector2i) -> void:
	grid._test_put(cell, CellData.make_walkable(null, &"HALF_STAIR_NE", rise, alt_low, alt_high))


# ===========================================================================
# _step_direction
# ===========================================================================

func test_step_direction_ne() -> void:
	assert_eq(Bridge._step_direction(Vector2i(5, 5), Vector2i(5, 2)), Vector2i(0, -1))


func test_step_direction_sw() -> void:
	assert_eq(Bridge._step_direction(Vector2i(0, 0), Vector2i(0, 4)), Vector2i(0, 1))


func test_step_direction_nw() -> void:
	assert_eq(Bridge._step_direction(Vector2i(3, 1), Vector2i(0, 1)), Vector2i(-1, 0))


func test_step_direction_se() -> void:
	assert_eq(Bridge._step_direction(Vector2i(0, 0), Vector2i(3, 0)), Vector2i(1, 0))


func test_step_direction_rejects_non_diagonal() -> void:
	assert_eq(Bridge._step_direction(Vector2i(0, 0), Vector2i(3, 2)), Vector2i.ZERO)


func test_step_direction_rejects_same_cell() -> void:
	assert_eq(Bridge._step_direction(Vector2i(7, 7), Vector2i(7, 7)), Vector2i.ZERO)


# ===========================================================================
# direction -> stair kind mapping
# ===========================================================================

func test_entry_stair_ne() -> void:
	assert_eq(Bridge._entry_stair_kind(Vector2i(0, -1)), TileSlots.HALF_STAIR_NE)


func test_entry_stair_nw() -> void:
	assert_eq(Bridge._entry_stair_kind(Vector2i(-1, 0)), TileSlots.HALF_STAIR_NW)


func test_entry_stair_se() -> void:
	assert_eq(Bridge._entry_stair_kind(Vector2i(1, 0)), TileSlots.HALF_STAIR_SE)


func test_entry_stair_sw() -> void:
	assert_eq(Bridge._entry_stair_kind(Vector2i(0, 1)), TileSlots.HALF_STAIR_SW)


func test_exit_stair_is_opposite_direction() -> void:
	assert_eq(Bridge._exit_stair_kind(Vector2i(0, -1)), TileSlots.HALF_STAIR_SW)
	assert_eq(Bridge._exit_stair_kind(Vector2i(-1, 0)), TileSlots.HALF_STAIR_SE)
	assert_eq(Bridge._exit_stair_kind(Vector2i(1, 0)), TileSlots.HALF_STAIR_NW)
	assert_eq(Bridge._exit_stair_kind(Vector2i(0, 1)), TileSlots.HALF_STAIR_NE)


# ===========================================================================
# validate()
# ===========================================================================

func test_validate_ok_on_same_altitude_diagonal() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(0, 4), 0)
	assert_eq(Bridge.validate(Vector2i(0, 0), Vector2i(0, 4), grid), Bridge.Result.OK)


func test_validate_rejects_non_diagonal() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(3, 2), 0)
	assert_eq(
		Bridge.validate(Vector2i(0, 0), Vector2i(3, 2), grid),
		Bridge.Result.NOT_DIAGONAL
	)


func test_validate_rejects_altitude_mismatch() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(0, 3), 2)
	assert_eq(
		Bridge.validate(Vector2i(0, 0), Vector2i(0, 3), grid),
		Bridge.Result.ALTITUDE_MISMATCH
	)


func test_validate_rejects_too_short() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(0, 1), 0)
	assert_eq(
		Bridge.validate(Vector2i(0, 0), Vector2i(0, 1), grid),
		Bridge.Result.TOO_SHORT
	)


func test_validate_rejects_same_cell() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	assert_eq(
		Bridge.validate(Vector2i(0, 0), Vector2i(0, 0), grid),
		Bridge.Result.SAME_CELL
	)


func test_validate_rejects_non_walkable_far() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	assert_eq(
		Bridge.validate(Vector2i(0, 0), Vector2i(0, 5), grid),
		Bridge.Result.NOT_WALKABLE_FAR
	)


func test_validate_rejects_non_walkable_origin() -> void:
	_inject_flat(Vector2i(0, 5), 0)
	assert_eq(
		Bridge.validate(Vector2i(0, 0), Vector2i(0, 5), grid),
		Bridge.Result.NOT_WALKABLE_ORIGIN
	)


func test_validate_rejects_ramp_endpoint() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_ramp(Vector2i(0, 3), 0, 1, Vector2i(0, -1))
	assert_eq(
		Bridge.validate(Vector2i(0, 0), Vector2i(0, 3), grid),
		Bridge.Result.ALTITUDE_MISMATCH
	)


# ===========================================================================
# find_candidates() — closest valid endpoint per cardinal direction
# ===========================================================================

func test_find_candidates_returns_one_per_cardinal_direction() -> void:
	# Origin at (0,0); a valid endpoint sits at distance 3 in each cardinal.
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(0, -3), 0)  # N
	_inject_flat(Vector2i(3, 0), 0)   # E
	_inject_flat(Vector2i(0, 3), 0)   # S
	_inject_flat(Vector2i(-3, 0), 0)  # W
	var found := Bridge.find_candidates(Vector2i(0, 0), grid)
	assert_eq(found.size(), 4, "expected one candidate per cardinal direction")
	for cell in found:
		assert_eq(
			Bridge.validate(Vector2i(0, 0), cell, grid),
			Bridge.Result.OK,
			"candidate %s must validate OK" % cell
		)


func test_find_candidates_picks_nearest_per_direction() -> void:
	# Two valid endpoints north (at -3 and -5); should pick -3.
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(0, -3), 0)
	_inject_flat(Vector2i(0, -5), 0)
	var found := Bridge.find_candidates(Vector2i(0, 0), grid)
	assert_true(found.has(Vector2i(0, -3)))
	assert_false(found.has(Vector2i(0, -5)))


func test_find_candidates_returns_empty_when_no_valid_endpoints() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	# No other walkable cells; nothing to find.
	var found := Bridge.find_candidates(Vector2i(0, 0), grid)
	assert_eq(found.size(), 0)


func test_find_candidates_skips_altitude_mismatch_and_keeps_searching() -> void:
	# At step 2 the only flat is at altitude 1 (mismatch); at step 3 there's
	# a flat at altitude 0 (valid). Should return the step-3 cell.
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(0, -2), 1)
	_inject_flat(Vector2i(0, -3), 0)
	var found := Bridge.find_candidates(Vector2i(0, 0), grid)
	assert_true(found.has(Vector2i(0, -3)))
	assert_false(found.has(Vector2i(0, -2)))


func test_find_candidates_respects_max_scan() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(0, -10), 0)
	var found := Bridge.find_candidates(Vector2i(0, 0), grid, 5)
	assert_eq(found.size(), 0, "endpoint beyond max_scan must be ignored")


# ===========================================================================
# blocked_cells — occupancy by player / planted objects
# ===========================================================================

func test_validate_occupied_on_far_cell() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(0, 3), 0)
	var blocked := {Vector2i(0, 3): true}
	assert_eq(
		Bridge.validate(Vector2i(0, 0), Vector2i(0, 3), grid, blocked),
		Bridge.Result.OCCUPIED
	)


func test_validate_occupied_on_deck_cell() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(0, 1), 0)
	_inject_flat(Vector2i(0, 2), 0)
	_inject_flat(Vector2i(0, 3), 0)
	# Player or plant in the middle of the span.
	var blocked := {Vector2i(0, 2): true}
	assert_eq(
		Bridge.validate(Vector2i(0, 0), Vector2i(0, 3), grid, blocked),
		Bridge.Result.OCCUPIED
	)


func test_validate_ok_when_blocked_cells_off_path() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(0, 3), 0)
	var blocked := {Vector2i(5, 5): true}
	assert_eq(
		Bridge.validate(Vector2i(0, 0), Vector2i(0, 3), grid, blocked),
		Bridge.Result.OK
	)


func test_find_candidates_skips_directions_with_occupied_endpoint() -> void:
	# North endpoint is blocked at distance 3; should fall back to distance 5
	# if walkable, otherwise skip the direction. Here only -3 exists, so north
	# yields no candidate.
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(0, -3), 0)
	_inject_flat(Vector2i(3, 0), 0)
	var blocked := {Vector2i(0, -3): true}
	var found := Bridge.find_candidates(Vector2i(0, 0), grid, 20, blocked)
	assert_false(found.has(Vector2i(0, -3)))
	assert_true(found.has(Vector2i(3, 0)))
