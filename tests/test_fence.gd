extends GutTest

# Tests for Fence's pure helpers, its validator, and the neighbour-derived
# orientation rule. Tree-free; uses TileGrid directly (same pattern as
# test_bridge.gd / test_ladder.gd).
#
# Two things here are Fence-specific and worth stating up front, because both
# are places where copying Bridge's tests would give the wrong answer:
#
#   - A Bridge constrains only its two ENDPOINTS, because the deck carries the
#     span. A Fence rests on the ground for its whole length, so EVERY cell has
#     to be a solid, empty, level flat — hence the full lines below.
#   - A Fence's art is not a property of the fence but of its NEIGHBOURHOOD, and
#     a cell with fences on both axes breaks the tie by BUILD ORDER. Those are
#     the `kind_at` cases, which stand in fences with explicit build_index
#     values rather than building anything.


var grid: TileGrid
# Fences stood up by _put_fence, freed in after_each. They are Node2Ds outside
# the tree, so nothing else will collect them.
var _fences: Array[Fence] = []


func before_each() -> void:
	grid = TileGrid.new()
	_fences.clear()


func after_each() -> void:
	for f in _fences:
		if is_instance_valid(f):
			f.free()
	_fences.clear()


func _inject_flat(cell: Vector2i, alt: int) -> void:
	grid._test_put(cell, CellData.make_walkable(null, &"FLAT", Vector2i.ZERO, alt, alt))


func _inject_ramp(cell: Vector2i, alt_low: int, alt_high: int) -> void:
	grid._test_put(cell, CellData.make_walkable(
		null, &"HALF_STAIR_NE", Vector2i(0, -1), alt_low, alt_high
	))


# Lay `count` flats at `alt` starting at `origin` and stepping by `dir`.
func _inject_line(origin: Vector2i, dir: Vector2i, count: int, alt: int) -> void:
	for i in range(0, count):
		_inject_flat(origin + dir * i, alt)


# Stand a fence on `cell` as an occupant, with an explicit age. Nothing is built
# or painted — kind_at only ever reads the occupant registry and build_index, so
# this is the whole of what it can see.
#
# The flat underneath is NOT optional: TileGrid.set_occupant silently refuses a
# cell with no painted terrain, and it refuses by returning false rather than by
# warning. Without it every fence here would fail to register, and the NE-axis
# and default cases would still pass — because "no neighbours" and "a neighbour
# that never registered" produce the same answer. The assert is what stops this
# suite going green on a fence that isn't there.
func _put_fence(cell: Vector2i, build_index: int) -> Fence:
	if grid.get_tile(cell) == null:
		_inject_flat(cell, 0)
	var f := Fence.new()
	f.cell = cell
	f.build_index = build_index
	assert_true(grid.set_occupant(cell, f), "fence at %s must register" % cell)
	_fences.append(f)
	return f


# ===========================================================================
# _step_direction
# ===========================================================================

func test_step_direction_ne() -> void:
	assert_eq(Fence._step_direction(Vector2i(5, 5), Vector2i(5, 2)), Vector2i(0, -1))


func test_step_direction_se() -> void:
	assert_eq(Fence._step_direction(Vector2i(0, 0), Vector2i(3, 0)), Vector2i(1, 0))


func test_step_direction_rejects_true_diagonal() -> void:
	assert_eq(Fence._step_direction(Vector2i(0, 0), Vector2i(3, 2)), Vector2i.ZERO)


# ===========================================================================
# plan_cells
# ===========================================================================

func test_plan_of_a_single_cell_is_that_cell() -> void:
	# The second click landing back on the origin is how one fence goes down.
	var plan := Fence.plan_cells(Vector2i(4, 4), Vector2i(4, 4))
	assert_eq(plan.size(), 1)
	assert_eq(plan[0], Vector2i(4, 4))


func test_plan_covers_every_cell_including_both_ends() -> void:
	var plan := Fence.plan_cells(Vector2i(0, 0), Vector2i(0, 3))
	assert_eq(plan, [Vector2i(0, 0), Vector2i(0, 1), Vector2i(0, 2), Vector2i(0, 3)])


func test_plan_empty_on_true_diagonal() -> void:
	assert_eq(Fence.plan_cells(Vector2i(0, 0), Vector2i(2, 2)).size(), 0)


# ===========================================================================
# kind_at — orientation from the neighbourhood
# ===========================================================================

func test_isolated_fence_takes_the_default_axis() -> void:
	assert_eq(Fence.kind_at(Vector2i(0, 0), grid), TileSlots.FENCE_NE)


func test_neighbour_on_the_ne_axis_wins_that_axis() -> void:
	_put_fence(Vector2i(0, -1), 0)
	assert_eq(Fence.kind_at(Vector2i(0, 0), grid), TileSlots.FENCE_NE)


func test_neighbour_on_the_nw_axis_wins_that_axis() -> void:
	_put_fence(Vector2i(1, 0), 0)
	assert_eq(Fence.kind_at(Vector2i(0, 0), grid), TileSlots.FENCE_NW)


func test_either_sign_of_an_axis_gives_the_same_variant() -> void:
	# A fence has an orientation, not a facing.
	_put_fence(Vector2i(-1, 0), 0)
	assert_eq(Fence.kind_at(Vector2i(0, 0), grid), TileSlots.FENCE_NW)


func test_both_axes_go_to_the_older_neighbour() -> void:
	_put_fence(Vector2i(1, 0), 3)    # NW axis, built first
	_put_fence(Vector2i(0, -1), 7)   # NE axis, built later
	assert_eq(Fence.kind_at(Vector2i(0, 0), grid), TileSlots.FENCE_NW)


func test_both_axes_the_other_way_round() -> void:
	_put_fence(Vector2i(1, 0), 9)
	_put_fence(Vector2i(0, -1), 2)
	assert_eq(Fence.kind_at(Vector2i(0, 0), grid), TileSlots.FENCE_NE)


func test_a_later_crossing_run_does_not_steal_an_established_line() -> void:
	# The behaviour a "locked axis" flag would have bought, falling out of the
	# age comparison instead: the line through this cell was built first, so a
	# run crossing it later leaves it alone.
	_put_fence(Vector2i(0, -1), 0)
	_put_fence(Vector2i(0, 1), 1)
	_put_fence(Vector2i(-1, 0), 50)
	_put_fence(Vector2i(1, 0), 51)
	assert_eq(Fence.kind_at(Vector2i(0, 0), grid), TileSlots.FENCE_NE)


func test_removing_the_winning_neighbour_turns_the_fence_to_face_what_is_left() -> void:
	# And where a lock would leave the fence pointing at a gap, the age rule
	# self-corrects.
	var older := _put_fence(Vector2i(0, -1), 0)
	_put_fence(Vector2i(1, 0), 5)
	assert_eq(Fence.kind_at(Vector2i(0, 0), grid), TileSlots.FENCE_NE)
	grid.clear_occupant(Vector2i(0, -1), older)
	assert_eq(Fence.kind_at(Vector2i(0, 0), grid), TileSlots.FENCE_NW)


func test_only_the_oldest_on_each_axis_counts() -> void:
	# Two on the NE axis, the younger of which is younger than the NW one; the
	# axis is judged by its OLDEST member, so NE still wins.
	_put_fence(Vector2i(0, -1), 1)
	_put_fence(Vector2i(0, 1), 90)
	_put_fence(Vector2i(1, 0), 40)
	assert_eq(Fence.kind_at(Vector2i(0, 0), grid), TileSlots.FENCE_NE)


func test_a_non_fence_occupant_is_not_a_neighbour() -> void:
	_inject_flat(Vector2i(1, 0), 0)
	var rock := Node2D.new()
	assert_true(grid.set_occupant(Vector2i(1, 0), rock))
	assert_eq(Fence.kind_at(Vector2i(0, 0), grid), TileSlots.FENCE_NE,
			"only fences connect to fences")
	rock.free()


# --- pending (the placement ghost's view) ------------------------------------

func test_pending_cells_orient_a_previewed_run() -> void:
	# Nothing is standing yet; the ghost still has to show the line it will be.
	var pending := { Vector2i(1, 0): true, Vector2i(2, 0): true }
	assert_eq(Fence.kind_at(Vector2i(0, 0), grid, pending), TileSlots.FENCE_NW)


func test_an_existing_fence_outranks_a_pending_one() -> void:
	# The ghost must predict what the commit will actually do, and at commit the
	# standing fence is the older neighbour.
	_put_fence(Vector2i(0, -1), 0)
	var pending := { Vector2i(1, 0): true }
	assert_eq(Fence.kind_at(Vector2i(0, 0), grid, pending), TileSlots.FENCE_NE)


# ===========================================================================
# validate()
# ===========================================================================

func test_validate_accepts_a_single_cell() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	assert_eq(Fence.validate(Vector2i(0, 0), Vector2i(0, 0), grid), Fence.Result.OK)


func test_validate_ok_on_solid_level_line() -> void:
	_inject_line(Vector2i(0, 0), Vector2i(0, 1), 4, 0)
	assert_eq(Fence.validate(Vector2i(0, 0), Vector2i(0, 3), grid), Fence.Result.OK)


func test_validate_rejects_true_diagonal() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(3, 2), 0)
	assert_eq(Fence.validate(Vector2i(0, 0), Vector2i(3, 2), grid), Fence.Result.NOT_DIAGONAL)


func test_validate_rejects_run_longer_than_max_cells() -> void:
	var over: int = Fence.MAX_CELLS + 1
	_inject_line(Vector2i(0, 0), Vector2i(0, 1), over, 0)
	assert_eq(
		Fence.validate(Vector2i(0, 0), Vector2i(0, over - 1), grid),
		Fence.Result.TOO_LONG
	)


func test_validate_accepts_run_of_exactly_max_cells() -> void:
	_inject_line(Vector2i(0, 0), Vector2i(0, 1), Fence.MAX_CELLS, 0)
	assert_eq(
		Fence.validate(Vector2i(0, 0), Vector2i(0, Fence.MAX_CELLS - 1), grid),
		Fence.Result.OK
	)


func test_validate_rejects_gap_in_the_middle() -> void:
	# This is the whole point of the per-cell sweep — a Bridge would accept
	# these same two endpoints and span the hole.
	_inject_flat(Vector2i(0, 0), 0)
	_inject_flat(Vector2i(0, 1), 0)
	# (0, 2) deliberately left empty
	_inject_flat(Vector2i(0, 3), 0)
	assert_eq(Fence.validate(Vector2i(0, 0), Vector2i(0, 3), grid), Fence.Result.NOT_SOLID)


func test_validate_rejects_ramp_in_the_middle() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	_inject_ramp(Vector2i(0, 1), 0, 1)
	_inject_flat(Vector2i(0, 2), 0)
	assert_eq(Fence.validate(Vector2i(0, 0), Vector2i(0, 2), grid), Fence.Result.NOT_SOLID)


func test_validate_rejects_ramp_origin() -> void:
	_inject_ramp(Vector2i(0, 0), 0, 1)
	_inject_flat(Vector2i(0, 1), 0)
	assert_eq(
		Fence.validate(Vector2i(0, 0), Vector2i(0, 1), grid),
		Fence.Result.ALTITUDE_MISMATCH
	)


func test_validate_rejects_step_in_altitude_along_the_run() -> void:
	_inject_flat(Vector2i(0, 0), 2)
	_inject_flat(Vector2i(0, 1), 2)
	_inject_flat(Vector2i(0, 2), 4)
	assert_eq(
		Fence.validate(Vector2i(0, 0), Vector2i(0, 2), grid),
		Fence.Result.ALTITUDE_MISMATCH
	)


func test_validate_rejects_occupied_interior_cell() -> void:
	_inject_line(Vector2i(0, 0), Vector2i(0, 1), 4, 0)
	assert_eq(
		Fence.validate(Vector2i(0, 0), Vector2i(0, 3), grid, { Vector2i(0, 2): true }),
		Fence.Result.OCCUPIED
	)


func test_validate_rejects_occupied_endpoint() -> void:
	_inject_line(Vector2i(0, 0), Vector2i(0, 1), 4, 0)
	assert_eq(
		Fence.validate(Vector2i(0, 0), Vector2i(0, 3), grid, { Vector2i(0, 3): true }),
		Fence.Result.OCCUPIED
	)


func test_validate_rejects_player_on_an_endpoint() -> void:
	# Divergence from Bridge on purpose: a bridge may attach to the cell you
	# stand on (it stays walkable), a fence may not (it does not).
	_inject_line(Vector2i(0, 0), Vector2i(0, 1), 4, 0)
	assert_eq(
		Fence.validate(Vector2i(0, 0), Vector2i(0, 3), grid, {},
			Fence.MAX_CELLS, Vector2i(0, 0)),
		Fence.Result.OCCUPIED
	)


func test_validate_rejects_a_single_fence_under_the_player() -> void:
	_inject_flat(Vector2i(0, 0), 0)
	assert_eq(
		Fence.validate(Vector2i(0, 0), Vector2i(0, 0), grid, {},
			Fence.MAX_CELLS, Vector2i(0, 0)),
		Fence.Result.OCCUPIED
	)


func test_validate_ignores_player_standing_beside_the_run() -> void:
	_inject_line(Vector2i(0, 0), Vector2i(0, 1), 4, 0)
	_inject_flat(Vector2i(1, 1), 0)
	assert_eq(
		Fence.validate(Vector2i(0, 0), Vector2i(0, 3), grid, {},
			Fence.MAX_CELLS, Vector2i(1, 1)),
		Fence.Result.OK
	)


# ===========================================================================
# find_candidates
# ===========================================================================

func test_find_candidates_returns_shortest_legal_run_per_direction() -> void:
	_inject_line(Vector2i(0, 0), Vector2i(0, 1), 4, 0)
	var out := Fence.find_candidates(Vector2i(0, 0), grid)
	assert_eq(out.size(), 1)
	assert_eq(out[0], Vector2i(0, 1))


func test_find_candidates_omits_the_origin() -> void:
	# The single-fence target is always legal, but the hint layer already marks
	# the origin — repeating it there would draw a candidate on top of it.
	_inject_flat(Vector2i(0, 0), 0)
	var out := Fence.find_candidates(Vector2i(0, 0), grid)
	assert_false(out.has(Vector2i(0, 0)))


func test_find_candidates_skips_a_direction_blocked_at_its_second_cell() -> void:
	_inject_line(Vector2i(0, 0), Vector2i(0, 1), 3, 0)
	_inject_line(Vector2i(0, 0), Vector2i(1, 0), 3, 0)
	# The blocked cell sits inside every run in that direction, so +x yields none.
	var out := Fence.find_candidates(
		Vector2i(0, 0), grid, Fence.MAX_CELLS, { Vector2i(1, 0): true })
	assert_eq(out.size(), 1)
	assert_eq(out[0], Vector2i(0, 1))


# ===========================================================================
# Occupant contract — the actual barrier
# ===========================================================================

func test_fence_blocks_movement() -> void:
	var f := Fence.new()
	assert_true(f.blocks_movement())
	assert_eq(f.occupant_kind(), &"fence")
	f.free()


func test_fence_claims_exactly_its_own_cell() -> void:
	# One fence, one cell — which is what makes the trash action take out only
	# the tile that was pointed at.
	var f := Fence.new()
	f.cell = Vector2i(3, 7)
	assert_eq(f.occupied_cells(), [Vector2i(3, 7)])
	assert_true(f.occupies_cell(Vector2i(3, 7)))
	assert_false(f.occupies_cell(Vector2i(3, 8)))
	f.free()


func test_grid_reports_fenced_cell_unwalkable_but_terrain_walkable() -> void:
	# is_walkable falls to false via the occupant; is_terrain_walkable stays
	# true, which is what keeps the cell right-clickable so the fence can be
	# removed again.
	_inject_flat(Vector2i(0, 0), 0)
	_put_fence(Vector2i(0, 0), 0)
	assert_false(grid.is_walkable(Vector2i(0, 0)))
	assert_true(grid.is_terrain_walkable(Vector2i(0, 0)))


func test_result_name_covers_every_result() -> void:
	for r: int in Fence.Result.values():
		assert_ne(Fence.result_name(r), "UNKNOWN")
