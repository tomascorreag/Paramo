extends GutTest

# ===========================================================================
# Pathfinder — A* search and static math helpers
# ===========================================================================
#
# find_path() is exercised by constructing a Pathfinder with its _grid
# populated directly via injection (same technique as test_tile_grid.gd). We
# bypass rebuild() / TileMapLayer wiring because the pathfinder only consumes
# TileGrid.is_walkable / can_transition.

var pf: Pathfinder


func before_each() -> void:
	pf = Pathfinder.new()
	pf._grid = TileGrid.new()


func after_each() -> void:
	pf.free()


# ---------------------------------------------------------------------------
# Injection helpers
# ---------------------------------------------------------------------------

func _inject_walkable(cell: Vector2i) -> void:
	pf._grid._test_put(cell, CellData.make_walkable(null, &"FLAT", Vector2i.ZERO, 0, 0))


func _inject_rect(origin: Vector2i, size: Vector2i) -> void:
	for x in range(origin.x, origin.x + size.x):
		for y in range(origin.y, origin.y + size.y):
			_inject_walkable(Vector2i(x, y))


# Injects a ramp-shaped cell. altitude_low/high collapsed so can_transition
# doesn't reject steps onto/off this cell — we only want to exercise the
# ramp-penalty path here; altitude gating has its own tests. Pass a non-zero
# ramp_size to register the elevation-penalty contribution.
func _inject_ramp(cell: Vector2i, kind: StringName, ramp_size: int) -> void:
	pf._grid._test_put(cell, CellData.make_walkable(null, kind, Vector2i.ZERO, 0, ramp_size))


func _count_turns(path: Array[Vector2i]) -> int:
	var turns := 0
	for i in range(2, path.size()):
		var prev_step: Vector2i = path[i - 1] - path[i - 2]
		var cur_step: Vector2i = path[i] - path[i - 1]
		if prev_step != cur_step:
			turns += 1
	return turns


# ===========================================================================
# _heuristic — Manhattan distance on the 4-neighbor grid
# ===========================================================================

func test_heuristic_same_cell_is_zero() -> void:
	assert_eq(Pathfinder._heuristic(Vector2i(0, 0), Vector2i(0, 0)), 0.0)


func test_heuristic_adjacent_is_one() -> void:
	assert_eq(Pathfinder._heuristic(Vector2i(0, 0), Vector2i(1, 0)), 1.0)
	assert_eq(Pathfinder._heuristic(Vector2i(0, 0), Vector2i(0, -1)), 1.0)


func test_heuristic_manhattan_sum() -> void:
	assert_eq(Pathfinder._heuristic(Vector2i(0, 0), Vector2i(3, 4)), 7.0)


func test_heuristic_symmetric() -> void:
	var a := Vector2i(-2, 5)
	var b := Vector2i(7, -3)
	assert_eq(Pathfinder._heuristic(a, b), Pathfinder._heuristic(b, a))


func test_heuristic_negative_deltas() -> void:
	assert_eq(Pathfinder._heuristic(Vector2i(5, 5), Vector2i(2, 1)), 7.0)


# ===========================================================================
# _state_key — format + discrimination
# ===========================================================================

func test_state_key_format() -> void:
	assert_eq(Pathfinder._state_key(Vector2i(3, -2), 1), "3,-2,1")


func test_state_key_start_sentinel() -> void:
	assert_eq(Pathfinder._state_key(Vector2i(0, 0), -1), "0,0,-1")


func test_state_key_distinguishes_direction() -> void:
	var k0 := Pathfinder._state_key(Vector2i(0, 0), 0)
	var k1 := Pathfinder._state_key(Vector2i(0, 0), 1)
	assert_ne(k0, k1)


func test_state_key_distinguishes_cell() -> void:
	var k_a := Pathfinder._state_key(Vector2i(0, 0), 0)
	var k_b := Pathfinder._state_key(Vector2i(1, 0), 0)
	assert_ne(k_a, k_b)


# ===========================================================================
# find_path — degenerate inputs
# ===========================================================================

func test_find_path_nil_grid_returns_empty() -> void:
	pf._grid = null
	assert_eq(pf.find_path(Vector2i(0, 0), Vector2i(1, 0)).size(), 0)


func test_find_path_unwalkable_start_returns_empty() -> void:
	_inject_walkable(Vector2i(1, 0))
	# (0, 0) is not in the grid, so it's treated as non-walkable.
	assert_eq(pf.find_path(Vector2i(0, 0), Vector2i(1, 0)).size(), 0)


func test_find_path_unwalkable_end_returns_empty() -> void:
	_inject_walkable(Vector2i(0, 0))
	assert_eq(pf.find_path(Vector2i(0, 0), Vector2i(1, 0)).size(), 0)


func test_find_path_same_start_and_end() -> void:
	_inject_walkable(Vector2i(2, 3))
	var path := pf.find_path(Vector2i(2, 3), Vector2i(2, 3))
	assert_eq(path.size(), 1)
	assert_eq(path[0], Vector2i(2, 3))


func test_find_path_same_cell_unwalkable_returns_empty() -> void:
	# Guard against a "same start/end" shortcut that skips the walkability
	# check on the cell itself.
	assert_eq(pf.find_path(Vector2i(0, 0), Vector2i(0, 0)).size(), 0)


# ===========================================================================
# find_path — path shape and length
# ===========================================================================

func test_find_path_adjacent_pair() -> void:
	_inject_walkable(Vector2i(0, 0))
	_inject_walkable(Vector2i(1, 0))
	var path := pf.find_path(Vector2i(0, 0), Vector2i(1, 0))
	assert_eq(path.size(), 2)
	assert_eq(path[0], Vector2i(0, 0))
	assert_eq(path[1], Vector2i(1, 0))


func test_find_path_straight_line_includes_both_endpoints() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(5, 1))
	var path := pf.find_path(Vector2i(0, 0), Vector2i(4, 0))
	assert_eq(path.size(), 5)
	for i in 5:
		assert_eq(path[i], Vector2i(i, 0))


func test_find_path_is_step_connected() -> void:
	# Every consecutive pair along the returned path must be a single
	# 4-neighbor step — no gaps or diagonals.
	_inject_rect(Vector2i(0, 0), Vector2i(4, 4))
	var path := pf.find_path(Vector2i(0, 0), Vector2i(3, 3))
	assert_gt(path.size(), 1)
	for i in range(1, path.size()):
		var step: Vector2i = path[i] - path[i - 1]
		var manhattan: int = absi(step.x) + absi(step.y)
		assert_eq(manhattan, 1, "non-unit step at index %d: %s" % [i, step])


func test_find_path_disconnected_components_return_empty() -> void:
	_inject_walkable(Vector2i(0, 0))
	_inject_walkable(Vector2i(5, 5))  # island
	assert_eq(pf.find_path(Vector2i(0, 0), Vector2i(5, 5)).size(), 0)


func test_find_path_detours_around_missing_cell() -> void:
	# 3x3 with (1, 0) removed. Direct straight path (3 cells) impossible;
	# detour via row y=1 needs 5 cells.
	for x in range(3):
		for y in range(3):
			if x == 1 and y == 0:
				continue
			_inject_walkable(Vector2i(x, y))
	var path := pf.find_path(Vector2i(0, 0), Vector2i(2, 0))
	assert_eq(path.size(), 5)
	assert_eq(path[0], Vector2i(0, 0))
	assert_eq(path[path.size() - 1], Vector2i(2, 0))
	for c in path:
		assert_ne(c, Vector2i(1, 0), "path crossed the blocked cell")


func test_find_path_symmetric_on_flat_grid() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(4, 4))
	var forward := pf.find_path(Vector2i(0, 0), Vector2i(3, 3))
	var backward := pf.find_path(Vector2i(3, 3), Vector2i(0, 0))
	assert_eq(forward.size(), backward.size())


# ===========================================================================
# find_path — turn-penalty tiebreak
# ===========================================================================
#
# Among all shortest paths, find_path() prefers the one with the fewest
# direction changes (_TURN_EPSILON cost per turn). On an open 3x3 grid
# (0,0) -> (2,2) has three 5-cell paths: RRDD, DDRR (1 turn each) and zig-zag
# variants (3 turns). The result must be a 1-turn path.

func test_find_path_prefers_straight_over_zigzag() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(3, 3))
	var path := pf.find_path(Vector2i(0, 0), Vector2i(2, 2))
	assert_eq(path.size(), 5, "expected shortest 5-cell path")
	assert_eq(_count_turns(path), 1,
		"expected 1 turn, got %d (path=%s)" % [_count_turns(path), path])


func test_find_path_straight_line_has_zero_turns() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(6, 1))
	var path := pf.find_path(Vector2i(0, 0), Vector2i(5, 0))
	assert_eq(_count_turns(path), 0)


func test_find_path_forced_corner_has_one_turn() -> void:
	# Long L-shape: only one 90-degree corner is reachable. Any shortest path
	# must turn exactly once.
	_inject_rect(Vector2i(0, 0), Vector2i(5, 1))  # horizontal arm
	_inject_rect(Vector2i(4, 0), Vector2i(1, 5))  # vertical arm
	var path := pf.find_path(Vector2i(0, 0), Vector2i(4, 4))
	assert_eq(path.size(), 9)
	assert_eq(_count_turns(path), 1)


# ===========================================================================
# find_path — altitude-gated transitions
# ===========================================================================
#
# Regression: even when cells are walkable, find_path must respect
# can_transition (altitude mismatches block the step).

func test_find_path_blocked_by_altitude_mismatch() -> void:
	# Two flats side by side at different altitudes; can_transition returns
	# false between them, so no route exists.
	pf._grid._test_put(Vector2i(0, 0), CellData.make_walkable(null, &"FLAT", Vector2i.ZERO, 0, 0))
	pf._grid._test_put(Vector2i(1, 0), CellData.make_walkable(null, &"FLAT", Vector2i.ZERO, 4, 4))
	assert_eq(pf.find_path(Vector2i(0, 0), Vector2i(1, 0)).size(), 0)


# ===========================================================================
# find_path — ramp penalty (elevation cost)
# ===========================================================================
#
# Stepping onto a ramp cell charges _RAMP_PENALTY_PER_STEP * ramp_size extra,
# so flat routes win ties against equivalent ramp routes but ramp routes still
# beat any strictly longer flat detour.

func test_find_path_prefers_flat_over_ramp_when_tied() -> void:
	# 3x3 rect, all flats except (1,0) which is a full STAIR (ramp_size=2).
	# Two 1-turn 5-cell routes exist from (0,0) to (2,2): one across the top
	# row through (1,0), one down the left column through (1,2). Ramp penalty
	# should break the tie against the top route.
	_inject_rect(Vector2i(0, 0), Vector2i(3, 3))
	_inject_ramp(Vector2i(1, 0), &"STAIR_NE", 2)
	var path := pf.find_path(Vector2i(0, 0), Vector2i(2, 2))
	assert_eq(path.size(), 5)
	for c in path:
		assert_ne(c, Vector2i(1, 0), "path crossed the ramp tile")


func test_find_path_takes_ramp_when_only_option() -> void:
	# Straight corridor with the middle cell painted as a ramp. Penalty
	# (<1.0) can't force a detour because no alternative exists.
	_inject_walkable(Vector2i(0, 0))
	_inject_ramp(Vector2i(1, 0), &"STAIR_NE", 2)
	_inject_walkable(Vector2i(2, 0))
	var path := pf.find_path(Vector2i(0, 0), Vector2i(2, 0))
	assert_eq(path.size(), 3)
	assert_eq(path[1], Vector2i(1, 0))


func test_find_path_half_ramp_cheaper_than_full_ramp() -> void:
	# 3x3 with the center hollowed out so only two 1-turn 5-cell routes exist
	# from (0,0) to (2,2). The top route crosses a full STAIR (penalty 0.30),
	# the left-down route crosses a HALF_STAIR (penalty 0.15). Expect the
	# half-ramp route.
	for x in range(3):
		for y in range(3):
			if x == 1 and y == 1:
				continue
			_inject_walkable(Vector2i(x, y))
	_inject_ramp(Vector2i(1, 0), &"STAIR_NE", 2)
	_inject_ramp(Vector2i(1, 2), &"HALF_STAIR_NE", 1)
	var path := pf.find_path(Vector2i(0, 0), Vector2i(2, 2))
	assert_eq(path.size(), 5)
	var hit_half := false
	for c in path:
		assert_ne(c, Vector2i(1, 0), "path chose the more expensive full ramp")
		if c == Vector2i(1, 2):
			hit_half = true
	assert_true(hit_half, "path did not use the cheaper half ramp")


# ===========================================================================
# find_path — per-cell object penalty
# ===========================================================================

func test_find_path_avoids_high_penalty_cell() -> void:
	# 3x2 rect: direct 3-cell route at y=0 vs. 5-cell detour via y=1. A large
	# penalty (5.0) on the middle cell of the direct route must force the
	# detour (4 + turn costs < 2 + 5).
	_inject_rect(Vector2i(0, 0), Vector2i(3, 2))
	pf.set_cell_penalty(Vector2i(1, 0), 5.0)
	var path := pf.find_path(Vector2i(0, 0), Vector2i(2, 0))
	assert_eq(path.size(), 5)
	for c in path:
		assert_ne(c, Vector2i(1, 0), "path crossed the high-penalty cell")


func test_find_path_low_penalty_still_on_shortest_route() -> void:
	# Same 3x2 rect but the penalty (0.1) is too small to outweigh the 2-tile
	# detour cost, so the direct route wins despite the penalty.
	_inject_rect(Vector2i(0, 0), Vector2i(3, 2))
	pf.set_cell_penalty(Vector2i(1, 0), 0.1)
	var path := pf.find_path(Vector2i(0, 0), Vector2i(2, 0))
	assert_eq(path.size(), 3)
	assert_eq(path[1], Vector2i(1, 0))


func test_find_path_penalty_tiebreaks_against_clean_route() -> void:
	# Two tied 5-cell 1-turn routes on a 3x3 rect. A tiny penalty (0.1) on
	# one route's midpoint should be enough to prefer the other route.
	_inject_rect(Vector2i(0, 0), Vector2i(3, 3))
	pf.set_cell_penalty(Vector2i(1, 0), 0.1)
	var path := pf.find_path(Vector2i(0, 0), Vector2i(2, 2))
	assert_eq(path.size(), 5)
	for c in path:
		assert_ne(c, Vector2i(1, 0), "path crossed the penalised cell")


# ===========================================================================
# find_path — ladder traversal-edge cost
# ===========================================================================
#
# Per design: a ladder step costs one unit per half-step of altitude climbed,
# so one full cube (altitude delta 2) costs the same as 2 flat tile steps.
# Normal 4-neighbor flat steps stay at cost 1.0.


func test_find_path_uses_ladder_when_only_route() -> void:
	# Two flats separated by altitude 4 (2 cubes). Only a traversal edge
	# connects them — no flats in between. Path must route through the edge.
	pf._grid._test_put(
		Vector2i(0, 0), CellData.make_walkable(null, &"FLAT", Vector2i.ZERO, 0, 0)
	)
	pf._grid._test_put(
		Vector2i(0, -1), CellData.make_walkable(null, &"FLAT", Vector2i.ZERO, 4, 4)
	)
	pf.add_traversal_edge(Vector2i(0, 0), Vector2i(0, -1))
	var path := pf.find_path(Vector2i(0, 0), Vector2i(0, -1))
	assert_eq(path.size(), 2)
	assert_eq(path[0], Vector2i(0, 0))
	assert_eq(path[1], Vector2i(0, -1))


func test_find_path_prefers_two_short_ladders_over_one_tall_ladder() -> void:
	# Shape:
	#                (1,-1)=2 --lad2-- (2,-1)=4      <-- upper row
	#                  |                 |
	#                 lad1              lad3 (Δ=4)
	#                  |                 |
	#   (0,0)=0 --- (1,0)=0 --- (2,0)=0                 <-- lower row
	#
	# Route A (tall ladder): (0,0)→(1,0)→(2,0)→(2,-1)[Δ=4, cost 4].
	#   Total step cost = 1 + 1 + 4 = 6.
	# Route B (two short ladders):
	#   (0,0)→(1,0)→(1,-1)[Δ=2, cost 2]→(2,-1)[Δ=2, cost 2].
	#   Total step cost = 1 + 2 + 2 = 5.
	# Without height-proportional ladder cost, both routes would tie at ~4
	# (each ladder just 1 unit), and turn-penalty would decide. With the fix,
	# route B is strictly cheaper.
	for x in range(3):
		pf._grid._test_put(
			Vector2i(x, 0), CellData.make_walkable(null, &"FLAT", Vector2i.ZERO, 0, 0)
		)
	pf._grid._test_put(
		Vector2i(1, -1), CellData.make_walkable(null, &"FLAT", Vector2i.ZERO, 2, 2)
	)
	pf._grid._test_put(
		Vector2i(2, -1), CellData.make_walkable(null, &"FLAT", Vector2i.ZERO, 4, 4)
	)
	pf.add_traversal_edge(Vector2i(1, 0), Vector2i(1, -1))  # Δ=2
	pf.add_traversal_edge(Vector2i(1, -1), Vector2i(2, -1))  # Δ=2
	pf.add_traversal_edge(Vector2i(2, 0), Vector2i(2, -1))  # Δ=4
	var path := pf.find_path(Vector2i(0, 0), Vector2i(2, -1))
	assert_true(path.has(Vector2i(1, -1)), "expected route via the two shorter ladders")
	assert_false(path.has(Vector2i(2, 0)), "tall ladder route should lose on cost")


func test_cell_penalty_api_roundtrip() -> void:
	var cell := Vector2i(2, 3)
	assert_eq(pf.get_cell_penalty(cell), 0.0)

	pf.set_cell_penalty(cell, 0.5)
	assert_eq(pf.get_cell_penalty(cell), 0.5)

	pf.clear_cell_penalty(cell)
	assert_eq(pf.get_cell_penalty(cell), 0.0)

	# Setting 0.0 should erase rather than store a zero entry.
	pf.set_cell_penalty(cell, 1.0)
	pf.set_cell_penalty(cell, 0.0)
	assert_eq(pf.get_cell_penalty(cell), 0.0)
	assert_false(pf._cell_penalties.has(cell))


# ===========================================================================
# Coordinate conversion — cell_to_world / world_to_cell / resolve_click
# ===========================================================================
#
# These exercise the iso-projection math with a real TileMapLayer. We build a
# synthetic TileSet with a single FLAT slot, spawn a layer at a configurable
# altitude offset, paint a cell, and call pf.rebuild() so the pathfinder sees
# the world state.
#
# Altitude contract (per Pathfinder docs):
#   - cell_to_world returns the altitude-0 world position of the cell origin,
#     independent of the layer's visual altitude lift (layer.position.y).
#   - world_to_cell is the inverse.
#   - resolve_click takes a screen/global position INCLUDING the visual lift.

const _COORD_TILE_KIND_FIELD: String = "tile_kind"
const _COORD_TILE_SIZE: Vector2i = Vector2i(16, 16)
const _COORD_SOURCE_ID: int = 0


func _build_coord_tile_set() -> Array:
	var ts := TileSet.new()
	ts.tile_size = _COORD_TILE_SIZE
	ts.add_custom_data_layer()
	ts.set_custom_data_layer_name(0, _COORD_TILE_KIND_FIELD)
	ts.set_custom_data_layer_type(0, TYPE_STRING)
	var src := TileSetAtlasSource.new()
	var image := Image.create(_COORD_TILE_SIZE.x * 2, _COORD_TILE_SIZE.y * 2, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	src.texture = ImageTexture.create_from_image(image)
	src.texture_region_size = _COORD_TILE_SIZE
	ts.add_source(src, _COORD_SOURCE_ID)
	src.create_tile(Vector2i(0, 0))
	src.get_tile_data(Vector2i(0, 0), 0).set_custom_data_by_layer_id(0, "FLAT")
	return [ts, Vector2i(0, 0)]


# Spawns a TileMapLayer at the altitude-consistent position offset, paints
# the given cell with FLAT, adds to the test scene, and returns the layer.
func _spawn_coord_layer(altitude: int, painted_cell: Vector2i) -> TileMapLayer:
	var setup := _build_coord_tile_set()
	var layer := TileMapLayer.new()
	layer.tile_set = setup[0]
	layer.set_meta("altitude", altitude)
	layer.position = Vector2(0.0, -altitude * Pathfinder.HALF_STEP_PX)
	layer.set_cell(painted_cell, _COORD_SOURCE_ID, setup[1])
	add_child_autofree(layer)
	return layer


# ---------------------------------------------------------------------------
# cell_to_world / world_to_cell
# ---------------------------------------------------------------------------

func test_cell_to_world_no_layer_returns_zero() -> void:
	# No layers wired; fallback is Vector2.ZERO.
	pf.tile_map_layers = []
	assert_eq(pf.cell_to_world(Vector2i(3, 5)), Vector2.ZERO)


func test_world_to_cell_no_layer_returns_no_cell() -> void:
	pf.tile_map_layers = []
	assert_eq(pf.world_to_cell(Vector2(10.0, 10.0)), Pathfinder.NO_CELL)


func test_cell_to_world_matches_map_to_local_at_altitude_zero() -> void:
	var layer := _spawn_coord_layer(0, Vector2i(0, 0))
	pf.tile_map_layers = [layer]
	pf.rebuild()

	var cell := Vector2i(3, 4)
	assert_eq(pf.cell_to_world(cell), layer.map_to_local(cell))


func test_cell_to_world_strips_altitude_lift() -> void:
	# Layer visually lifted by altitude 2 (-16 px). cell_to_world still returns
	# the altitude-0 frame, so the y shift cancels out — same result as alt 0.
	var layer := _spawn_coord_layer(2, Vector2i(0, 0))
	pf.tile_map_layers = [layer]
	pf.rebuild()

	var cell := Vector2i(3, 4)
	assert_eq(pf.cell_to_world(cell), layer.map_to_local(cell))


func test_world_to_cell_roundtrip_at_altitude_zero() -> void:
	var layer := _spawn_coord_layer(0, Vector2i(0, 0))
	pf.tile_map_layers = [layer]
	pf.rebuild()

	for cell in [Vector2i(0, 0), Vector2i(5, 3), Vector2i(-2, 7)]:
		assert_eq(pf.world_to_cell(pf.cell_to_world(cell)), cell,
			"roundtrip failed for %s" % cell)


func test_world_to_cell_roundtrip_at_lifted_layer() -> void:
	# Roundtrip holds regardless of the reference layer's altitude lift.
	var layer := _spawn_coord_layer(4, Vector2i(0, 0))
	pf.tile_map_layers = [layer]
	pf.rebuild()

	for cell in [Vector2i(0, 0), Vector2i(6, -2), Vector2i(-3, -3)]:
		assert_eq(pf.world_to_cell(pf.cell_to_world(cell)), cell,
			"roundtrip failed for %s" % cell)


# ---------------------------------------------------------------------------
# resolve_click
# ---------------------------------------------------------------------------

func test_resolve_click_nil_grid_returns_no_cell() -> void:
	pf._grid = null
	assert_eq(pf.resolve_click(Vector2(0.0, 0.0)), Pathfinder.NO_CELL)


func test_resolve_click_hits_painted_cell_at_altitude_zero() -> void:
	var painted := Vector2i(4, 2)
	var layer := _spawn_coord_layer(0, painted)
	pf.tile_map_layers = [layer]
	pf.rebuild()

	# Visual on-screen center of the painted tile == map_to_local + layer.position.
	var screen_pos := layer.map_to_local(painted) + layer.position
	assert_eq(pf.resolve_click(screen_pos), painted)


func test_resolve_click_hits_painted_cell_at_lifted_altitude() -> void:
	var painted := Vector2i(2, 3)
	var layer := _spawn_coord_layer(2, painted)
	pf.tile_map_layers = [layer]
	pf.rebuild()

	var screen_pos := layer.map_to_local(painted) + layer.position
	assert_eq(pf.resolve_click(screen_pos), painted)


func test_resolve_click_empty_area_returns_no_cell() -> void:
	# One painted cell; click far from it resolves to NO_CELL.
	var layer := _spawn_coord_layer(0, Vector2i(0, 0))
	pf.tile_map_layers = [layer]
	pf.rebuild()

	# Enough offset to fall outside any walkable cell (layers have only the
	# painted origin cell). Note: local_to_map will still return SOME cell for
	# any input; the check is that it's not walkable, so resolve_click returns
	# NO_CELL.
	assert_eq(pf.resolve_click(Vector2(500.0, 500.0)), Pathfinder.NO_CELL)


func test_resolve_click_prefers_higher_altitude_when_stacked() -> void:
	# Two layers painted on the same cell at different altitudes. resolve_click
	# iterates altitudes descending, so the higher layer wins the click when
	# the click lands on the high-altitude visual position.
	var painted := Vector2i(1, 1)
	var low := _spawn_coord_layer(0, painted)
	var high := _spawn_coord_layer(4, painted)
	pf.tile_map_layers = [low, high]
	pf.rebuild()

	# After build, tallest-wins means the CELL is owned by `high` in the grid,
	# so any click that lands on the painted column resolves to `high`.
	# Clicking at the HIGH layer's visual center for the shared cell.
	var screen_pos := high.map_to_local(painted) + high.position
	assert_eq(pf.resolve_click(screen_pos), painted)
