extends GutTest

# Guards the bot's placement fidelity: a sim-planted frailejon is the REAL
# scene running the game's own code — occupant registration, walk penalty,
# fire char hook, and burnout death (queue_free -> occupant slot vacated via
# the runner's deletion flush, since a single-frame sim never reaches the
# idle deletion pass).

var _world: SimWorld = null
var _saved_paused: bool


func before_each() -> void:
	_saved_paused = TimeManager.paused
	TimeManager.paused = false
	_world = SimWorld.new()
	add_child_autofree(_world)
	var params := TerrainGenerationParams.new()
	params.seed = 7
	_world.regenerate(params)
	FireManager.spawn_vfx = false
	FireManager._wipe_all_fires()
	FireManager._attach_to_pathfinder(_world.pathfinder)
	FireManager._refresh_grid_and_vfx()


func after_each() -> void:
	FireManager._wipe_all_fires()
	FireManager._pathfinder = null
	FireManager._grid = null
	FireManager.spawn_vfx = true
	TimeManager.paused = _saved_paused


# A grass cell fire could take, with no occupant — plantable AND ignitable.
func _find_open_grass_cell() -> Vector2i:
	var grid: TileGrid = _world.pathfinder.grid()
	var b: Rect2i = grid.bounds()
	for y in range(b.position.y, b.end.y):
		for x in range(b.position.x, b.end.x):
			var c := Vector2i(x, y)
			if FireManager.can_ignite(c) and grid.occupant_at(c) == null:
				return c
	return Vector2i(-1, -1)


func test_planted_frailejon_lives_and_dies_by_the_games_rules() -> void:
	var cell: Vector2i = _find_open_grass_cell()
	assert_true(cell.x >= 0, "seed 7 must offer an open grass cell")

	var bot := SimBot.new()
	bot.pathfinder = _world.pathfinder
	bot.object_parent = _world.object_parent
	bot._plant_frailejon(cell)

	var grid: TileGrid = _world.pathfinder.grid()
	var occ: Node2D = grid.occupant_at(cell)
	assert_not_null(occ, "the real scene self-registers as the cell's occupant")
	assert_almost_eq(float(occ.call(&"walk_penalty")), 0.4, 0.001,
			"pathfinding penalty flows through the occupant, not a raw number")

	assert_true(FireManager.ignite(cell), "an occupied grass cell still ignites")
	assert_eq(FireManager._burning[cell]["frailejon"], occ,
			"the fire grabbed the plant through the occupant hook")

	FireManager._complete_burn(cell)
	assert_true(occ.is_queued_for_deletion(),
			"burnout destroys the plant (the 5-token asset is lost)")

	# The runner's day-boundary flush: inside a single-frame run queue_free
	# never lands on its own; freeing must vacate the occupant slot.
	occ.free()
	assert_null(grid.occupant_at(cell),
			"death vacates the cell — replanting is possible again")
