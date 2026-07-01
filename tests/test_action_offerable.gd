extends GutTest

# ===========================================================================
# TileAction reachability gate (is_offerable / standing_cells)
# ===========================================================================
# is_offerable is the menu-facing gate: an action shows for a cell when it
# _applies AND at least one cell it can be performed from (standing_cells) is
# reachable by the player (ctx.reachable). Unlike is_available (act-from-here),
# it's what lets a far-but-reachable tile surface its actions.
#
# standing_cells only needs pathfinder.is_walkable(), so a tiny Pathfinder
# subclass stub over a walkable set isolates the gate without building a grid.


# Pathfinder stub: is_walkable() consults an injected set. Extends Pathfinder so
# it satisfies ActionContext.pathfinder's static type.
class _StubPathfinder extends Pathfinder:
	var walkable: Dictionary = {}
	func is_walkable(cell: Vector2i) -> bool:
		return walkable.has(cell)


# Tile predicate always passes — isolates the reachability gate.
class _AlwaysApplies extends TileAction:
	func _applies(_ctx: ActionContext) -> bool:
		return true


func _pf(walkable: Array[Vector2i]) -> _StubPathfinder:
	var pf := autofree(_StubPathfinder.new()) as _StubPathfinder
	for c in walkable:
		pf.walkable[c] = true
	return pf


func _ctx(cell: Vector2i, pf: _StubPathfinder, reachable: Array[Vector2i]) -> ActionContext:
	var c := ActionContext.new()
	c.cell = cell
	c.pathfinder = pf
	var reach: Dictionary = {}
	for r in reachable:
		reach[r] = true
	c.reachable = reach
	return c


func test_offerable_when_a_walkable_neighbour_is_reachable() -> void:
	var target := Vector2i(5, 5)
	var neighbour := Vector2i(5, 4)
	var pf := _pf([neighbour] as Array[Vector2i])
	var ctx := _ctx(target, pf, [neighbour] as Array[Vector2i])
	assert_true(_AlwaysApplies.new().is_offerable(ctx))


func test_not_offerable_when_no_neighbour_reachable() -> void:
	var target := Vector2i(5, 5)
	var neighbour := Vector2i(5, 4)
	# Neighbour is walkable but NOT in the reachable set.
	var pf := _pf([neighbour] as Array[Vector2i])
	var ctx := _ctx(target, pf, [] as Array[Vector2i])
	assert_false(_AlwaysApplies.new().is_offerable(ctx))


func test_not_offerable_when_neighbour_reachable_but_not_walkable() -> void:
	var target := Vector2i(5, 5)
	var neighbour := Vector2i(5, 4)
	# Reachable set claims the cell, but it isn't a walkable standing cell.
	var pf := _pf([] as Array[Vector2i])
	var ctx := _ctx(target, pf, [neighbour] as Array[Vector2i])
	assert_false(_AlwaysApplies.new().is_offerable(ctx))


func test_not_offerable_when_applies_false() -> void:
	var target := Vector2i(5, 5)
	var neighbour := Vector2i(5, 4)
	var pf := _pf([neighbour] as Array[Vector2i])
	var ctx := _ctx(target, pf, [neighbour] as Array[Vector2i])
	# Base TileAction._applies == false → reachability alone is not enough.
	assert_false(TileAction.new().is_offerable(ctx))


func test_standing_cells_are_walkable_chebyshev1_neighbours() -> void:
	var target := Vector2i(5, 5)
	var walkable := [
		Vector2i(5, 4),  # N   — in range, walkable
		Vector2i(6, 6),  # SE  — diagonal, in range, walkable
		Vector2i(5, 5),  # origin — walkable but excluded by _range_ok
		Vector2i(5, 3),  # 2 away — out of range
	] as Array[Vector2i]
	var pf := _pf(walkable)
	var ctx := _ctx(target, pf, [] as Array[Vector2i])
	var cells := _AlwaysApplies.new().standing_cells(ctx)
	assert_eq(cells.size(), 2)
	assert_has(cells, Vector2i(5, 4))
	assert_has(cells, Vector2i(6, 6))
	assert_does_not_have(cells, target)
	assert_does_not_have(cells, Vector2i(5, 3))


func test_reachable_defaults_to_empty_dict() -> void:
	assert_eq(ActionContext.new().reachable, {})
