extends GutTest

# ===========================================================================
# GridWalker — path consumption, step timing, facing
# ===========================================================================
#
# The grid is injected straight into the Pathfinder (same technique as
# test_pathfinder.gd / test_tile_grid.gd) because the walker only ever asks it
# is_walkable / classify_step / altitude_center / cell_to_world.
#
# The walker is driven through `tick_movement` with fixed deltas rather than by
# adding it to the tree, so a step's DURATION is an assertion instead of a race
# against the frame rate.

var pf: Pathfinder
var walker: GridWalker
var sprite: Sprite2D


class ArrivalSpy extends GridWalker:
	var arrivals: int = 0
	var steps: Array[Vector2i] = []

	func _on_arrived() -> void:
		arrivals += 1

	func _on_step_started(cell: Vector2i, _kind: int) -> void:
		steps.append(cell)


func before_each() -> void:
	pf = Pathfinder.new()
	pf._grid = TileGrid.new()
	_inject_rect(Vector2i(0, 0), Vector2i(6, 6))

	walker = ArrivalSpy.new()
	sprite = Sprite2D.new()
	sprite.hframes = 24
	walker.add_child(sprite)
	walker.bind(pf, sprite)
	walker.place_at(Vector2i(2, 2))


func after_each() -> void:
	walker.free()
	pf.free()


func _inject_rect(origin: Vector2i, size: Vector2i) -> void:
	for x in range(origin.x, origin.x + size.x):
		for y in range(origin.y, origin.y + size.y):
			pf._grid._test_put(Vector2i(x, y),
					CellData.make_walkable(null, &"FLAT", Vector2i.ZERO, 0, 0))


## Advance `seconds` in 60 Hz slices, the way _process would.
func _run(seconds: float) -> void:
	var dt := 1.0 / 60.0
	var t := 0.0
	while t < seconds:
		walker.tick_movement(dt)
		t += dt


# ---------------------------------------------------------------------------
# Path consumption
# ---------------------------------------------------------------------------

func test_place_at_sets_the_cell_without_moving() -> void:
	walker.place_at(Vector2i(4, 1))
	assert_eq(walker.current_cell, Vector2i(4, 1))
	assert_false(walker.is_moving())


func test_follows_a_path_to_its_end() -> void:
	walker.follow_path([Vector2i(3, 2), Vector2i(4, 2), Vector2i(4, 3)] as Array[Vector2i])
	assert_true(walker.is_moving(), "a queued path counts as moving before the first tick")
	_run(walker.step_duration * 3.0 + 0.1)
	assert_eq(walker.current_cell, Vector2i(4, 3))
	assert_false(walker.is_moving())


func test_commits_the_cell_at_step_start_not_at_step_end() -> void:
	# A re-path mid-step must plan from the cell being committed to, not the one
	# being left — otherwise the new path starts with a step the walker is
	# already halfway through and fails the adjacency guard.
	walker.follow_path([Vector2i(3, 2)] as Array[Vector2i])
	_run(walker.step_duration * 0.25)
	assert_eq(walker.current_cell, Vector2i(3, 2))
	assert_true(walker.is_moving())


func test_a_flat_step_takes_step_duration() -> void:
	walker.step_duration = 0.5
	walker.follow_path([Vector2i(3, 2)] as Array[Vector2i])
	_run(0.4)
	assert_true(walker.is_moving(), "still stepping at 0.4s of a 0.5s step")
	_run(0.2)
	assert_false(walker.is_moving(), "the step is over by 0.6s")


func test_stop_abandons_the_queued_path() -> void:
	walker.follow_path([Vector2i(3, 2), Vector2i(4, 2)] as Array[Vector2i])
	walker.stop()
	assert_false(walker.is_moving())


func test_non_adjacent_step_is_skipped_not_walked() -> void:
	# A diagonal or a jump means the caller built the path wrong; walking it
	# would slide the sprite across the map.
	walker.follow_path([Vector2i(5, 5)] as Array[Vector2i])
	_run(0.1)
	assert_eq(walker.current_cell, Vector2i(2, 2), "the walker must not teleport")


func test_step_into_an_unwalkable_cell_drops_the_whole_path() -> void:
	# The graph changed under the path — a fence went up. Freezing mid-route is
	# wrong; the owner re-paths on Pathfinder.graph_changed.
	# (6, 2) is ADJACENT to (5, 2) and outside the injected 6x6 grid, so this
	# exercises the walkability guard rather than the adjacency one.
	walker.place_at(Vector2i(5, 2))
	walker.follow_path([Vector2i(6, 2), Vector2i(6, 3)] as Array[Vector2i])
	_run(0.1)
	assert_eq(walker.current_cell, Vector2i(5, 2))
	assert_false(walker.is_moving(), "the rest of the path is dropped, not queued")


# ---------------------------------------------------------------------------
# Hooks
# ---------------------------------------------------------------------------

func test_arrival_fires_once_when_the_path_runs_out() -> void:
	walker.follow_path([Vector2i(3, 2), Vector2i(4, 2)] as Array[Vector2i])
	_run(walker.step_duration * 2.0 + 0.5)
	assert_eq((walker as ArrivalSpy).arrivals, 1,
			"arrival must fire once, not every idle frame")


func test_arrival_does_not_fire_for_a_walker_that_never_walked() -> void:
	_run(1.0)
	assert_eq((walker as ArrivalSpy).arrivals, 0)


func test_step_started_reports_every_destination_in_order() -> void:
	walker.follow_path([Vector2i(3, 2), Vector2i(3, 3)] as Array[Vector2i])
	_run(walker.step_duration * 2.0 + 0.1)
	assert_eq((walker as ArrivalSpy).steps, [Vector2i(3, 2), Vector2i(3, 3)] as Array[Vector2i])


# ---------------------------------------------------------------------------
# Facing and frames
# ---------------------------------------------------------------------------

func test_facing_follows_the_grid_direction() -> void:
	var cases := {
		Vector2i(3, 2): GridWalker.FACING_SE,
		Vector2i(2, 3): GridWalker.FACING_SW,
		Vector2i(1, 2): GridWalker.FACING_NW,
		Vector2i(2, 1): GridWalker.FACING_NE,
	}
	for target: Vector2i in cases:
		walker.place_at(Vector2i(2, 2))
		walker.follow_path([target] as Array[Vector2i])
		_run(0.05)
		assert_eq(walker.facing(), cases[target], "walking to %s" % target)


func test_frame_holds_slow_the_walk_cycle() -> void:
	# The cycle ticks at WALK_FPS whatever the step costs, so this is the only
	# lever that makes a slow walker's feet match its speed.
	walker.rng = RandomNumberGenerator.new()
	walker.frame_hold_chance = 1.0
	walker.step_duration = 2.0
	walker.follow_path([Vector2i(3, 2)] as Array[Vector2i])
	_run(1.0)
	assert_eq(sprite.frame, walker.facing() * GridWalker.WALK_FRAMES_PER_DIR,
			"a certain hold must never advance the cycle")


func test_no_hold_chance_reproduces_the_fixed_cadence() -> void:
	# 8 fps for 0.5s of walking is 4 frames advanced, exactly as the old
	# elapsed-time formula gave.
	walker.frame_hold_chance = 0.0
	walker.step_duration = 2.0
	walker.follow_path([Vector2i(3, 2)] as Array[Vector2i])
	_run(0.55)
	assert_eq(sprite.frame, walker.facing() * GridWalker.WALK_FRAMES_PER_DIR + 4)


# ---------------------------------------------------------------------------
# Pausing
# ---------------------------------------------------------------------------

func test_a_pause_holds_the_walker_between_steps() -> void:
	walker.step_duration = 0.2
	walker.follow_path([Vector2i(3, 2), Vector2i(4, 2)] as Array[Vector2i])
	_run(0.1)  # mid-step when the rest is called for
	walker.pause_movement(1.0)
	_run(0.3)
	assert_eq(walker.current_cell, Vector2i(3, 2), "the step in flight still lands")
	assert_true(walker.is_paused())
	_run(0.5)
	assert_eq(walker.current_cell, Vector2i(3, 2), "and then it stands there")
	_run(0.9)
	assert_eq(walker.current_cell, Vector2i(4, 2), "the rest of the path resumes")


func test_a_pause_never_freezes_mid_stride() -> void:
	# Stopping halfway across a step parks the sprite on the join between two
	# tiles, which reads as a stuck sprite rather than as a rest.
	# (Asserted on _stepping rather than on position: this harness's Pathfinder
	# has no TileMapLayers, so every cell maps to the same world point.)
	walker.step_duration = 0.4
	walker.follow_path([Vector2i(3, 2)] as Array[Vector2i])
	_run(0.2)
	assert_true(walker._stepping, "precondition: mid-stride")
	walker.pause_movement(2.0)
	_run(0.1)
	assert_true(walker._stepping, "the step in flight must keep running")
	_run(0.2)
	assert_false(walker._stepping, "and land before the rest begins")
	assert_true(walker.is_paused())


func test_a_pause_shows_the_standing_pose() -> void:
	walker.step_duration = 0.1
	walker.follow_path([Vector2i(3, 2), Vector2i(4, 2)] as Array[Vector2i])
	walker.pause_movement(1.0)
	_run(0.3)
	assert_eq(sprite.frame, walker.facing() * GridWalker.WALK_FRAMES_PER_DIR,
			"a resting walker must not keep cycling its legs")


func test_place_at_clears_a_pending_pause() -> void:
	walker.pause_movement(5.0)
	walker.place_at(Vector2i(1, 1))
	assert_false(walker.is_paused())


func test_sprite_frame_stays_inside_the_facing_block() -> void:
	# frame = facing * 6 + (0..5). Overrunning the block plays another
	# direction's animation, which reads as the sprite spinning.
	walker.follow_path([Vector2i(3, 2), Vector2i(4, 2), Vector2i(5, 2)] as Array[Vector2i])
	var dt := 1.0 / 60.0
	for _i in 120:
		walker.tick_movement(dt)
		var block: int = walker.facing() * GridWalker.WALK_FRAMES_PER_DIR
		assert_between(sprite.frame, block, block + GridWalker.WALK_FRAMES_PER_DIR - 1)
