extends GutTest

# ===========================================================================
# TileAction base proximity gate (_within_range) + is_available structure
# ===========================================================================
# TileAction and ActionContext are plain RefCounted, so the base contract is
# unit-testable without a scene. We assert the default proximity rule: an
# action applies only on a cell Chebyshev-adjacent to the player (distance == 1),
# never on the player's own tile (0) or farther (>= 2), and that _applies still
# gates on top of range.


# Dummy whose tile predicate always passes — isolates the proximity gate.
class _AlwaysApplies extends TileAction:
	func _applies(_ctx: ActionContext) -> bool:
		return true


func _ctx(cell: Vector2i, player_cell: Vector2i) -> ActionContext:
	var c := ActionContext.new()
	c.cell = cell
	c.player_cell = player_cell
	return c


func test_orthogonal_adjacent_is_available() -> void:
	var a := _AlwaysApplies.new()
	assert_true(a.is_available(_ctx(Vector2i(1, 0), Vector2i(0, 0))))
	assert_true(a.is_available(_ctx(Vector2i(0, -1), Vector2i(0, 0))))


func test_diagonal_adjacent_is_available() -> void:
	var a := _AlwaysApplies.new()
	assert_true(a.is_available(_ctx(Vector2i(1, 1), Vector2i(0, 0))))
	assert_true(a.is_available(_ctx(Vector2i(-1, -1), Vector2i(0, 0))))


func test_own_tile_not_available() -> void:
	var a := _AlwaysApplies.new()
	assert_false(a.is_available(_ctx(Vector2i(3, 3), Vector2i(3, 3))))


func test_two_cells_away_not_available() -> void:
	var a := _AlwaysApplies.new()
	assert_false(a.is_available(_ctx(Vector2i(2, 0), Vector2i(0, 0))))
	assert_false(a.is_available(_ctx(Vector2i(2, 2), Vector2i(0, 0))))


func test_null_ctx_not_available() -> void:
	var a := _AlwaysApplies.new()
	assert_false(a.is_available(null))


func test_applies_false_blocks_even_when_adjacent() -> void:
	# Base TileAction._applies returns false — adjacency alone is not enough.
	var a := TileAction.new()
	assert_false(a.is_available(_ctx(Vector2i(1, 0), Vector2i(0, 0))))
