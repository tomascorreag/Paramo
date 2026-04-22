extends GutTest

# Tests for Ladder pure helpers and validator. Tree-free; uses TileGrid
# directly (same pattern as test_bridge.gd / test_tile_grid.gd).


var grid: TileGrid


func before_each() -> void:
	grid = TileGrid.new()


func _inject_flat(cell: Vector2i, alt: int) -> void:
	grid._test_put(cell, CellData.make_walkable(null, &"FLAT", Vector2i.ZERO, alt, alt))


func _inject_ramp(cell: Vector2i, alt_low: int, alt_high: int, rise: Vector2i) -> void:
	grid._test_put(cell, CellData.make_walkable(null, &"HALF_STAIR_NE", rise, alt_low, alt_high))


# ===========================================================================
# _step_direction / _ladder_kind
# ===========================================================================

func test_step_direction_ne_and_nw_accepted() -> void:
	assert_eq(Ladder._step_direction(Vector2i(5, 5), Vector2i(5, 4)), Vector2i(0, -1))
	assert_eq(Ladder._step_direction(Vector2i(5, 5), Vector2i(4, 5)), Vector2i(-1, 0))


func test_ladder_kind_ne() -> void:
	assert_eq(Ladder._ladder_kind(Vector2i(0, -1)), TileSlots.LADDER_NE)


func test_ladder_kind_nw() -> void:
	assert_eq(Ladder._ladder_kind(Vector2i(-1, 0)), TileSlots.LADDER_NW)


func test_ladder_kind_rejects_se_sw() -> void:
	assert_eq(Ladder._ladder_kind(Vector2i(1, 0)), &"")
	assert_eq(Ladder._ladder_kind(Vector2i(0, 1)), &"")


# ===========================================================================
# plan_tiles — stacked ladder tiles on the wall column cell
# ===========================================================================

func test_plan_tiles_single_full_cube_ne() -> void:
	var plan := Ladder.plan_tiles(Vector2i(0, 0), Vector2i(0, -1), 0, 2)
	assert_eq(plan.size(), 1)
	assert_eq(plan[0]["cell"], Vector2i(0, 0))  # paints on ORIGIN, not C+dir
	assert_eq(plan[0]["kind"], TileSlots.LADDER_NE)
	assert_eq(plan[0]["altitude"], 1)


func test_plan_tiles_two_full_cubes_nw() -> void:
	var plan := Ladder.plan_tiles(Vector2i(0, 0), Vector2i(-1, 0), 0, 4)
	assert_eq(plan.size(), 2)
	for e in plan:
		assert_eq(e["cell"], Vector2i(0, 0))
		assert_eq(e["kind"], TileSlots.LADDER_NW)
	assert_eq(plan[0]["altitude"], 1)
	assert_eq(plan[1]["altitude"], 3)


func test_plan_tiles_three_full_cubes_altitudes() -> void:
	var plan := Ladder.plan_tiles(Vector2i(5, 5), Vector2i(5, 4), 2, 8)
	assert_eq(plan.size(), 3)
	for e in plan:
		assert_eq(e["cell"], Vector2i(5, 5))  # origin
	assert_eq(plan[0]["altitude"], 3)
	assert_eq(plan[1]["altitude"], 5)
	assert_eq(plan[2]["altitude"], 7)


func test_plan_tiles_rejects_se_sw_direction() -> void:
	assert_eq(Ladder.plan_tiles(Vector2i(0, 0), Vector2i(1, 0), 0, 2).size(), 0)
	assert_eq(Ladder.plan_tiles(Vector2i(0, 0), Vector2i(0, 1), 0, 2).size(), 0)


# Reversed argument order: first arg is upper, second is lower. plan_tiles
# must orient internally and paint on the LOWER cell regardless.
func test_plan_tiles_paints_on_lower_when_args_reversed() -> void:
	# a=upper at alt 2, b=lower at alt 0, lower is SW of upper.
	var plan := Ladder.plan_tiles(Vector2i(0, 0), Vector2i(0, 1), 2, 0)
	assert_eq(plan.size(), 1)
	assert_eq(plan[0]["cell"], Vector2i(0, 1))  # lower cell
	assert_eq(plan[0]["kind"], TileSlots.LADDER_NE)  # lower→upper dir = NE
	assert_eq(plan[0]["altitude"], 1)


func test_plan_tiles_rejects_non_multiple_of_2_height() -> void:
	assert_eq(Ladder.plan_tiles(Vector2i(0, 0), Vector2i(0, -1), 0, 1).size(), 0)
	assert_eq(Ladder.plan_tiles(Vector2i(0, 0), Vector2i(0, -1), 0, 3).size(), 0)


func test_plan_tiles_rejects_zero_or_negative_height() -> void:
	assert_eq(Ladder.plan_tiles(Vector2i(0, 0), Vector2i(0, -1), 2, 2).size(), 0)
	assert_eq(Ladder.plan_tiles(Vector2i(0, 0), Vector2i(0, -1), 2, 0).size(), 0)


# ===========================================================================
# validate()
# ===========================================================================

func test_validate_ok_ne_one_cube() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(0, -1), 2)  # top-landing 1 cube higher
	assert_eq(Ladder.validate(Vector2i(0, 0), Vector2i(0, -1), grid), Ladder.Result.OK)


func test_validate_ok_nw_two_cubes() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(-1, 0), 4)
	assert_eq(Ladder.validate(Vector2i(0, 0), Vector2i(-1, 0), grid), Ladder.Result.OK)


func test_validate_rejects_se_direction() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(1, 0), 2)
	assert_eq(
		Ladder.validate(Vector2i(0, 0), Vector2i(1, 0), grid),
		Ladder.Result.BAD_DIRECTION
	)


func test_validate_rejects_sw_direction() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(0, 1), 2)
	assert_eq(
		Ladder.validate(Vector2i(0, 0), Vector2i(0, 1), grid),
		Ladder.Result.BAD_DIRECTION
	)


func test_validate_rejects_same_altitude() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(0, -1), 0)
	assert_eq(
		Ladder.validate(Vector2i(0, 0), Vector2i(0, -1), grid),
		Ladder.Result.BAD_HEIGHT
	)


func test_validate_rejects_odd_altitude_delta() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(0, -1), 1)  # only 1 half-step (half cube)
	assert_eq(
		Ladder.validate(Vector2i(0, 0), Vector2i(0, -1), grid),
		Ladder.Result.BAD_HEIGHT
	)


# First-click upper, second-click lower NE of upper: from the lower cell's
# perspective the upper sits SW, which isn't a camera-facing wall face. The
# orient-then-check logic reports BAD_DIRECTION rather than BAD_HEIGHT — the
# pair has a height delta, it just can't carry a ladder sprite.
func test_validate_rejects_top_click_with_ne_lower() -> void:
	_inject_flat(Vector2i(0, 0), 4)
	_inject_flat(Vector2i(0, -1), 0)
	assert_eq(
		Ladder.validate(Vector2i(0, 0), Vector2i(0, -1), grid),
		Ladder.Result.BAD_DIRECTION
	)


# Top-down: first-click the UPPER floor, second-click a lower floor SW of it.
# From the lower cell, dir to upper = NE → valid camera-facing wall.
func test_validate_ok_top_down_sw_lower() -> void:
	_inject_flat(Vector2i(0, 0), 4)   # upper (first click)
	_inject_flat(Vector2i(0, 1), 0)   # lower, SW of upper
	assert_eq(
		Ladder.validate(Vector2i(0, 0), Vector2i(0, 1), grid),
		Ladder.Result.OK
	)


# Top-down: first-click upper, second-click lower SE of it. From the lower
# cell, dir to upper = NW → valid.
func test_validate_ok_top_down_se_lower() -> void:
	_inject_flat(Vector2i(0, 0), 4)
	_inject_flat(Vector2i(1, 0), 0)
	assert_eq(
		Ladder.validate(Vector2i(0, 0), Vector2i(1, 0), grid),
		Ladder.Result.OK
	)


func test_validate_rejects_same_cell() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	assert_eq(
		Ladder.validate(Vector2i(0, 0), Vector2i(0, 0), grid),
		Ladder.Result.SAME_CELL
	)


func test_validate_rejects_non_walkable_origin() -> void:
	_inject_flat(Vector2i(0, -1), 2)
	assert_eq(
		Ladder.validate(Vector2i(0, 0), Vector2i(0, -1), grid),
		Ladder.Result.NOT_WALKABLE_ORIGIN
	)


func test_validate_rejects_non_walkable_top() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	assert_eq(
		Ladder.validate(Vector2i(0, 0), Vector2i(0, -1), grid),
		Ladder.Result.NOT_WALKABLE_TOP
	)


func test_validate_rejects_ramp_endpoint() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_ramp(Vector2i(0, -1), 2, 3, Vector2i(0, -1))
	assert_eq(
		Ladder.validate(Vector2i(0, 0), Vector2i(0, -1), grid),
		Ladder.Result.BAD_HEIGHT
	)


func test_validate_occupied_on_origin() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(0, -1), 2)
	var blocked := {Vector2i(0, 0): true}
	assert_eq(
		Ladder.validate(Vector2i(0, 0), Vector2i(0, -1), grid, blocked),
		Ladder.Result.OCCUPIED
	)


# ===========================================================================
# find_candidates()
# ===========================================================================

func test_find_candidates_returns_both_ne_nw_when_available() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(0, -1), 2)  # NE
	_inject_flat(Vector2i(-1, 0), 2)  # NW
	var found := Ladder.find_candidates(Vector2i(0, 0), grid)
	assert_eq(found.size(), 2)
	assert_true(found.has(Vector2i(0, -1)))
	assert_true(found.has(Vector2i(-1, 0)))


# Top-down: origin is the upper floor; valid second-click cells are the
# SW/SE neighbors that sit lower (from those cells' perspective, origin is
# NE or NW — the valid wall-facing directions).
func test_find_candidates_top_down_returns_sw_se_lowers() -> void:
	_inject_flat(Vector2i(0, 0), 4)   # origin, upper
	_inject_flat(Vector2i(1, 0), 0)   # SE, lower
	_inject_flat(Vector2i(0, 1), 2)   # SW, lower
	var found := Ladder.find_candidates(Vector2i(0, 0), grid)
	assert_eq(found.size(), 2)
	assert_true(found.has(Vector2i(1, 0)))
	assert_true(found.has(Vector2i(0, 1)))


# Mixed: origin has a valid upper NE neighbor AND a valid lower SW neighbor.
# Both should appear in the candidate set.
func test_find_candidates_mixed_up_and_down() -> void:
	_inject_flat(Vector2i(0, 0), 2)    # origin (mid-height)
	_inject_flat(Vector2i(0, -1), 4)   # NE, higher (bottom-up build)
	_inject_flat(Vector2i(0, 1), 0)    # SW, lower (top-down build)
	var found := Ladder.find_candidates(Vector2i(0, 0), grid)
	assert_eq(found.size(), 2)
	assert_true(found.has(Vector2i(0, -1)))
	assert_true(found.has(Vector2i(0, 1)))


func test_find_candidates_returns_ne_only_when_nw_invalid() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(0, -1), 2)
	# NW neighbor at same altitude → not a valid ladder target.
	_inject_flat(Vector2i(-1, 0), 0)
	var found := Ladder.find_candidates(Vector2i(0, 0), grid)
	assert_eq(found.size(), 1)
	assert_true(found.has(Vector2i(0, -1)))


func test_find_candidates_respects_max_height() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(0, -1), 10)  # 5 cubes up — exceeds default MAX=4
	var found := Ladder.find_candidates(Vector2i(0, 0), grid, 4)
	assert_eq(found.size(), 0)


func test_find_candidates_returns_empty_on_ramp_origin() -> void:
	_inject_ramp(Vector2i(0, 0), 0, 1, Vector2i(0, -1))
	_inject_flat(Vector2i(0, -1), 2)
	var found := Ladder.find_candidates(Vector2i(0, 0), grid)
	assert_eq(found.size(), 0)


func test_find_candidates_skips_occupied() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(0, -1), 2)
	var blocked := {Vector2i(0, -1): true}
	var found := Ladder.find_candidates(Vector2i(0, 0), grid, 4, blocked)
	assert_eq(found.size(), 0)


# ===========================================================================
# TileGrid.can_transition — traversal edge override
# ===========================================================================

func test_traversal_edge_allows_transition_across_altitude_jump() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(0, -1), 4)
	# Without an edge the transition fails (altitude mismatch).
	assert_false(grid.can_transition(Vector2i(0, 0), Vector2i(0, -1)))
	grid.add_traversal_edge(Vector2i(0, 0), Vector2i(0, -1))
	assert_true(grid.can_transition(Vector2i(0, 0), Vector2i(0, -1)))
	assert_true(grid.can_transition(Vector2i(0, -1), Vector2i(0, 0)))


func test_traversal_edge_removal() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(0, -1), 4)
	grid.add_traversal_edge(Vector2i(0, 0), Vector2i(0, -1))
	grid.remove_traversal_edge(Vector2i(0, 0), Vector2i(0, -1))
	assert_false(grid.can_transition(Vector2i(0, 0), Vector2i(0, -1)))
	assert_false(grid.can_transition(Vector2i(0, -1), Vector2i(0, 0)))
