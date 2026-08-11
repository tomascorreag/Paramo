extends GutTest

# ===========================================================================
# Removing a structure — what it costs the pathfinder
# ===========================================================================
#
# Pathfinder.rebuild() re-ingests every layer of every cell and measures 18.7 ms
# on level1: a dropped frame on one of the most interactive actions in the game.
# Most removals do not need it. A fence, a ladder and a rock all do their work
# through an OCCUPANT CLAIM (or a traversal edge) on the live TileGrid, and
# paint only tiles listed in TileGrid._DECORATIVE — so there is nothing to
# re-ingest and the graph merely needs announcing.
#
# The tell that this was wrong was an asymmetry: BUILDING a fence already used
# notify_graph_changed, while REMOVING one rebuilt. Identical state changes, two
# orders of magnitude apart.
#
# These tests guard the decision, not the timing: `changes_terrain()` is what
# routes a removal down the cheap or the correct-but-slow path, and the DEFAULT
# has to stay the slow one (a traversal whose deck really is terrain and which
# forgets to answer must come out un-crossable-but-slow, never invisible-to-
# pathfinding-but-fast).


class _PlainTraversal extends Traversal:
	pass


class _DecorativeTraversal extends Traversal:
	func changes_terrain() -> bool:
		return false


func test_base_traversal_defaults_to_the_safe_slow_answer() -> void:
	var t := _PlainTraversal.new()
	autofree(t)
	assert_true(t.changes_terrain(),
			"a traversal that does not answer must be treated as terrain-painting")


func test_fence_and_ladder_opt_into_the_cheap_path() -> void:
	var f := Fence.new()
	autofree(f)
	assert_false(f.changes_terrain(),
			"a fence paints FENCE_* which is in TileGrid._DECORATIVE")
	var l := Ladder.new()
	autofree(l)
	assert_false(l.changes_terrain(),
			"a ladder paints LADDER_* which is in TileGrid._DECORATIVE")


func test_bridge_still_declares_itself_terrain() -> void:
	var b := Bridge.new()
	autofree(b)
	assert_true(b.changes_terrain(),
			"a bridge deck IS ground the player stands on; it must be re-ingested")


# ---------------------------------------------------------------------------
# The behaviour the cheap path has to preserve
# ---------------------------------------------------------------------------
#
# Dropping the rebuild is only safe because clearing an occupant is already live
# on the current grid AND bumps TileGrid.structure_version, which drops the
# pathfinder's resolved-edge cache. If either stopped being true, a removed
# fence would keep blocking the cell it no longer stands on.

class _Blocker extends Node2D:
	func blocks_movement() -> bool:
		return true


func test_clearing_an_occupant_reopens_the_cell_without_a_rebuild() -> void:
	var pf := Pathfinder.new()
	autofree(pf)
	pf._grid = TileGrid.new()
	for x in 3:
		pf._grid._test_put(Vector2i(x, 0),
				CellData.make_walkable(null, &"FLAT", Vector2i.ZERO, 0, 0))

	var blocker := _Blocker.new()
	autofree(blocker)
	pf._grid.set_occupant(Vector2i(1, 0), blocker)
	assert_eq(pf.find_path(Vector2i(0, 0), Vector2i(2, 0)), [] as Array[Vector2i],
			"the blocked middle cell should sever the row")

	var version_before: int = pf._grid.structure_version
	pf._grid.clear_occupant(Vector2i(1, 0), blocker)
	assert_gt(pf._grid.structure_version, version_before,
			"clear_occupant must bump the version the edge cache validates against")

	# No rebuild() anywhere in this test — this is exactly what the controller
	# now does.
	pf.notify_graph_changed()
	assert_eq(pf.find_path(Vector2i(0, 0), Vector2i(2, 0)).size(), 3,
			"the cell is free again; the route must reopen without a rebuild")
