extends GutTest

# ===========================================================================
# VisitorSpawner — entry derivation, goals, caps and gates
# ===========================================================================
#
# The grid is injected into the Pathfinder directly (test_pathfinder.gd's
# technique). The shapes below are chosen so "the southernmost cell of the
# landmass connected to the player" has an answer that is obvious by eye — the
# derivation is the part of this system with no other way to check it.
#
# The spawner is ticked by calling _process with explicit deltas: its stagger
# is measured in seconds and a test that waited for real frames would be both
# slow and flaky.

var pf: Pathfinder
var spawner: VisitorSpawner
var parent: Node2D
var player: Node2D
var _phase_before: int
var _paused_before: bool
var _time_before: float


class FakePlayer extends Node2D:
	var current_cell: Vector2i = Vector2i.ZERO


func before_each() -> void:
	# VisitorStanding is static, so claims outlive the visitors that made them
	# and would leak from one test into the next as permanently-taken ground.
	VisitorStanding.clear()
	pf = Pathfinder.new()
	pf._grid = TileGrid.new()
	add_child_autofree(pf)

	parent = Node2D.new()
	add_child_autofree(parent)

	player = FakePlayer.new()
	player.add_to_group(&"player")
	add_child_autofree(player)

	# ACTIVE is the only phase in which anyone visits; every spawn test would
	# otherwise be testing the gate instead of the thing under it.
	_phase_before = SeasonManager.phase
	SeasonManager.phase = SeasonManager.Phase.ACTIVE
	# Both autoloads are shared across the whole GUT run, and an earlier script
	# leaving the clock paused silently turns every spawn test into a test of
	# the pause gate — which is what happened the first time these were run.
	_paused_before = TimeManager.paused
	TimeManager.paused = false
	# Midday: inside opening hours, so every test below is about the thing it
	# names rather than about the clock. The hours gate has its own tests.
	_time_before = TimeManager.time_of_day
	TimeManager.time_of_day = 0.5


func after_each() -> void:
	SeasonManager.phase = _phase_before
	TimeManager.paused = _paused_before
	TimeManager.time_of_day = _time_before


func _inject_rect(origin: Vector2i, size: Vector2i) -> void:
	for x in range(origin.x, origin.x + size.x):
		for y in range(origin.y, origin.y + size.y):
			pf._grid._test_put(Vector2i(x, y),
					CellData.make_walkable(null, &"FLAT", Vector2i.ZERO, 0, 0))


func _make_spawner() -> VisitorSpawner:
	var s := VisitorSpawner.new()
	s.entity_parent = parent
	s.stagger_seconds = 0.0
	s.group_member_stagger_seconds = 0.0
	s.min_goal_distance = 2
	add_child_autofree(s)
	return s


func _visitors() -> Array:
	var out: Array = []
	for c in parent.get_children():
		if c is Visitor:
			out.append(c)
	return out


# ---------------------------------------------------------------------------
# The entry cell
# ---------------------------------------------------------------------------

func test_entry_is_the_southernmost_connected_cell() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(5, 5))
	player.current_cell = Vector2i(2, 2)
	spawner = _make_spawner()
	assert_eq(spawner.entry_cell().y, 4, "the entry must sit on the southern edge")


func test_entry_breaks_ties_toward_the_middle() -> void:
	# A whole southern row qualifies on y; the tie-break is what stops the entry
	# landing in a corner, where a trailhead reads as an accident.
	# TileGrid grows _bounds as cells are put, so the injected rect is already
	# the grid's bounds and the x-centre the tie-break reads is 2.
	_inject_rect(Vector2i(0, 0), Vector2i(5, 5))
	player.current_cell = Vector2i(2, 2)
	spawner = _make_spawner()
	assert_eq(spawner.entry_cell(), Vector2i(2, 4))


func test_entry_ignores_a_southern_island_it_cannot_reach() -> void:
	# Derived from the player's REACHABLE set, not from the whole grid — an
	# entry across water would strand every visitor at spawn.
	_inject_rect(Vector2i(0, 0), Vector2i(5, 3))
	_inject_rect(Vector2i(0, 8), Vector2i(5, 2))  # disconnected, further south
	player.current_cell = Vector2i(2, 1)
	spawner = _make_spawner()
	assert_eq(spawner.entry_cell().y, 2, "the island must not win on y alone")


func test_entry_override_wins() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(5, 5))
	player.current_cell = Vector2i(2, 2)
	spawner = _make_spawner()
	spawner.entry_cell_override = Vector2i(0, 0)
	assert_eq(spawner.entry_cell(), Vector2i(0, 0))


func test_entry_is_unresolved_until_the_player_is_placed() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(5, 5))
	player.current_cell = Vector2i(99, 99)  # not walkable
	spawner = _make_spawner()
	assert_eq(spawner.entry_cell(), Pathfinder.NO_CELL)


# ---------------------------------------------------------------------------
# Spawning
# ---------------------------------------------------------------------------

func test_spawns_one_visitor_per_arrival() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(8, 8))
	player.current_cell = Vector2i(4, 4)
	spawner = _make_spawner()
	spawner.request_visitors(3)
	for _i in 3:
		spawner._process(0.016)
	assert_eq(_visitors().size(), 3)
	assert_eq(spawner.pending_count(), 0)


func test_a_spawned_visitor_does_not_also_drive_itself() -> void:
	# The spawner ticks its whole crowd (see its `tick`), so a visitor running
	# its own _process as well advances TWICE a frame and walks at double the
	# pace it was given — which is how visitors ended up outrunning the player
	# they are clamped to stay behind. The spawner used to call
	# set_process(false) BEFORE add_child, and entering the tree re-enabled it,
	# so the guard has to be observed on a visitor that is already in the tree.
	_inject_rect(Vector2i(0, 0), Vector2i(8, 8))
	player.current_cell = Vector2i(4, 4)
	spawner = _make_spawner()
	spawner.request_visitors(2)
	for _i in 2:
		spawner._process(0.016)
	var seen := _visitors()
	assert_gt(seen.size(), 0, "nothing spawned — the rest of this test is vacuous")
	for v in seen:
		assert_true(v.driven_externally, "spawned visitor is not flagged as driven")
		assert_false(v.is_processing(),
				"spawned visitor still runs its own _process: it will tick twice a frame")


func test_a_hand_built_visitor_drives_itself() -> void:
	# The flag is opt-IN: a visitor a tool or a test builds by hand has no driver
	# and must keep its own _process, or it stands still forever.
	_inject_rect(Vector2i(0, 0), Vector2i(8, 8))
	var v: Visitor = load("res://scenes/entities/visitor.tscn").instantiate()
	v.entry_cell = Vector2i(4, 4)
	v.goal_cell = Vector2i(6, 6)
	parent.add_child(v)
	assert_false(v.driven_externally)
	assert_true(v.is_processing())
	v.queue_free()


func test_every_goal_is_reachable_from_the_entry() -> void:
	# The whole point of sampling goals out of the reachable set: reachability
	# is a property of the draw, not something checked afterwards.
	_inject_rect(Vector2i(0, 0), Vector2i(8, 8))
	player.current_cell = Vector2i(4, 4)
	spawner = _make_spawner()
	spawner.request_visitors(6)
	for _i in 6:
		spawner._process(0.016)
	var entry := spawner.entry_cell()
	for v in _visitors():
		assert_gte(pf.find_path(entry, v.goal_cell).size(), 2,
				"goal %s is not reachable from the entry %s" % [v.goal_cell, entry])


func test_goals_respect_the_minimum_distance() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(12, 12))
	player.current_cell = Vector2i(6, 6)
	spawner = _make_spawner()
	spawner.min_goal_distance = 5
	spawner.request_visitors(6)
	for _i in 6:
		spawner._process(0.016)
	var entry := spawner.entry_cell()
	for v in _visitors():
		assert_gte(Visitor.dist2(v.goal_cell, entry), 25,
				"goal %s is too close to the entry %s" % [v.goal_cell, entry])


func test_concurrency_cap_holds_the_rest_back() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(8, 8))
	player.current_cell = Vector2i(4, 4)
	spawner = _make_spawner()
	spawner.max_concurrent = 2
	spawner.request_visitors(4)
	for _i in 8:
		spawner._process(0.016)
	assert_eq(_visitors().size(), 2, "no more than max_concurrent bodies at once")
	assert_gt(spawner.pending_count(), 0, "the rest are still queued, not dropped")


func test_pending_is_clamped_against_a_burst_of_day_boundaries() -> void:
	# RunController's M key ends a season by emitting day_completed in a
	# synchronous loop, so a whole season's arrivals can land in one frame.
	_inject_rect(Vector2i(0, 0), Vector2i(8, 8))
	player.current_cell = Vector2i(4, 4)
	spawner = _make_spawner()
	spawner.max_concurrent = 3
	for _i in 20:
		spawner.request_visitors(4)
	assert_eq(spawner.pending_count(), 6, "pending is capped at max_concurrent * 2")


func test_stagger_spaces_the_arrivals_out() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(8, 8))
	player.current_cell = Vector2i(4, 4)
	spawner = _make_spawner()
	# Parties of one, so this measures the BETWEEN-group stagger; the gap inside
	# a group is group_member_stagger_seconds and has its own test.
	spawner.group_size_min = 1
	spawner.group_size_max = 1
	spawner.stagger_seconds = 2.0
	spawner.request_visitors(3)
	spawner._process(0.016)
	assert_eq(_visitors().size(), 1)
	spawner._process(1.0)
	assert_eq(_visitors().size(), 1, "still inside the stagger window")
	spawner._process(1.5)
	assert_eq(_visitors().size(), 2)


func test_nobody_arrives_outside_an_active_season() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(8, 8))
	player.current_cell = Vector2i(4, 4)
	spawner = _make_spawner()
	SeasonManager.phase = SeasonManager.Phase.IDLE
	spawner.request_visitors(3)
	for _i in 5:
		spawner._process(0.016)
	assert_eq(_visitors().size(), 0)
	assert_eq(spawner.pending_count(), 3, "they wait for the season, they are not lost")


func test_disabled_spawner_queues_nothing() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(8, 8))
	player.current_cell = Vector2i(4, 4)
	spawner = _make_spawner()
	spawner.enabled = false
	spawner.request_visitors(3)
	assert_eq(spawner.pending_count(), 0)


func test_visitors_stay_out_of_the_procedural_object_group() -> void:
	# ObjectPainter._clear_existing frees every child of World in that group on
	# regenerate. A visitor caught by that sweep would be freed mid-step with
	# its world-reparented shadow left behind.
	_inject_rect(Vector2i(0, 0), Vector2i(8, 8))
	player.current_cell = Vector2i(4, 4)
	spawner = _make_spawner()
	spawner.request_visitors(1)
	spawner._process(0.016)
	for v in _visitors():
		assert_false(v.is_in_group(&"procedural_object"))


func test_each_visitor_gets_its_own_material() -> void:
	# visitor.tscn marks the recolour material resource_local_to_scene; without
	# it every visitor shares one and the crowd takes the last roll.
	_inject_rect(Vector2i(0, 0), Vector2i(8, 8))
	player.current_cell = Vector2i(4, 4)
	spawner = _make_spawner()
	spawner.request_visitors(2)
	spawner._process(0.016)
	spawner._process(0.016)
	var mats: Array = []
	for v in _visitors():
		mats.append(v.get_node("Sprite2D").material)
	assert_eq(mats.size(), 2)
	assert_ne(mats[0], mats[1], "two visitors must not share one ShaderMaterial")


# ---------------------------------------------------------------------------
# Groups and pace
# ---------------------------------------------------------------------------

func test_a_group_arrives_before_the_next_group_does() -> void:
	# The gap inside a party is short and the gap between parties is long; that
	# difference IS the group, visually. Fixed to 3 so the boundary is known.
	_inject_rect(Vector2i(0, 0), Vector2i(8, 8))
	player.current_cell = Vector2i(4, 4)
	spawner = _make_spawner()
	spawner.group_size_min = 3
	spawner.group_size_max = 3
	spawner.group_member_stagger_seconds = 0.5
	spawner.stagger_seconds = 5.0
	spawner.request_visitors(6)

	for _i in 3:
		spawner._process(0.6)
	assert_eq(_visitors().size(), 3, "the whole party is in after 3 member gaps")
	spawner._process(0.6)
	assert_eq(_visitors().size(), 3, "the next party waits out the longer stagger")
	spawner._process(5.0)
	assert_eq(_visitors().size(), 4)


func test_a_group_walks_at_one_pace() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(8, 8))
	player.current_cell = Vector2i(4, 4)
	spawner = _make_spawner()
	spawner.group_size_min = 4
	spawner.group_size_max = 4
	spawner.group_pace_spread = 0.06
	spawner.request_visitors(4)
	for _i in 4:
		spawner._process(0.016)

	var paces: Array[float] = []
	for v in _visitors():
		paces.append(v.step_duration)
	assert_eq(paces.size(), 4)
	var lo: float = paces.min()
	var hi: float = paces.max()
	# Two members sit at most one spread either side of the shared pace, so the
	# widest possible ratio between them is (1+s)/(1-s).
	var widest: float = (1.0 + spawner.group_pace_spread) \
			/ (1.0 - spawner.group_pace_spread) - 1.0
	assert_lt((hi - lo) / lo, widest + 0.001,
			"party members must walk at very similar speeds: %s" % [paces])


func test_members_do_not_all_walk_at_exactly_one_pace() -> void:
	# The complement of the test above, and the reason jitter exists at all:
	# identical paces put a party on a single cell for the whole climb.
	_inject_rect(Vector2i(0, 0), Vector2i(8, 8))
	player.current_cell = Vector2i(4, 4)
	spawner = _make_spawner()
	spawner.group_size_min = 4
	spawner.group_size_max = 4
	spawner.request_visitors(4)
	for _i in 4:
		spawner._process(0.016)
	var paces: Array[float] = []
	for v in _visitors():
		paces.append(v.step_duration)
	assert_ne(paces.min(), paces.max(), "identical paces means lockstep")


func test_visitors_walk_at_half_to_three_quarters_of_the_player() -> void:
	# The shipped brief, stated as the durations it produces: a visitor takes
	# 1/f player-steps per cell, so f in [0.5, 0.75] is 1.333x .. 2x the
	# player's seconds-per-cell. The jitter widens each end by group_pace_spread.
	_inject_rect(Vector2i(0, 0), Vector2i(10, 10))
	player.current_cell = Vector2i(5, 5)
	spawner = _make_spawner()
	spawner.request_visitors(6)
	for _i in 6:
		spawner._process(0.016)
	var spread: float = spawner.group_pace_spread
	var quickest: float = VisitorSpawner.PLAYER_STEP_DURATION \
			/ (spawner.pace_fraction_max * (1.0 + spread))
	var slowest: float = VisitorSpawner.PLAYER_STEP_DURATION \
			/ (spawner.pace_fraction_min * (1.0 - spread))
	assert_gt(_visitors().size(), 0, "the test needs a crowd to measure")
	for v in _visitors():
		assert_between(v.step_duration, quickest - 0.001, slowest + 0.001,
				"pace must sit inside the authored fraction range")


func test_nobody_can_outpace_the_player() -> void:
	# The clamp is on the spawned value, not on the export, so a map that sets a
	# silly pace still cannot produce a visitor quicker than Player.
	_inject_rect(Vector2i(0, 0), Vector2i(10, 10))
	player.current_cell = Vector2i(5, 5)
	spawner = _make_spawner()
	spawner.pace_fraction_min = 4.0
	spawner.pace_fraction_max = 8.0
	spawner.request_visitors(6)
	for _i in 6:
		spawner._process(0.016)
	assert_gt(_visitors().size(), 0, "the test needs a crowd to measure")
	for v in _visitors():
		assert_gte(v.step_duration, VisitorSpawner.PLAYER_STEP_DURATION,
				"a visitor must never be quicker than the player")


func test_frame_holds_scale_with_slowness() -> void:
	spawner = _make_spawner()
	spawner.pace_fraction_min = 0.5
	spawner.pace_fraction_max = 0.75
	spawner.max_frame_hold_chance = 0.4
	assert_almost_eq(spawner._frame_hold_for_fraction(1.0), 0.0, 0.001,
			"at the player's own speed the cycle is not slowed at all")
	assert_almost_eq(spawner._frame_hold_for_fraction(0.5), 0.4, 0.001,
			"the slowest authored fraction takes the full hold chance")
	assert_gt(spawner._frame_hold_for_fraction(0.55),
			spawner._frame_hold_for_fraction(0.75),
			"slower must mean more repeats, not fewer")


func test_a_slow_visitor_gets_a_hold_chance() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(8, 8))
	player.current_cell = Vector2i(4, 4)
	spawner = _make_spawner()
	spawner.request_visitors(1)
	spawner._process(0.016)
	var v: Visitor = _visitors()[0]
	assert_gt(v.frame_hold_chance, 0.0,
			"every visitor is slower than the player, so every one holds frames")


func test_each_visitor_draws_from_its_own_stream() -> void:
	# Route noise and breathers are rolled per visitor across many frames. Off a
	# shared stream those draws interleave with the spawner's, so what the NEXT
	# visitor looks like would depend on how long the previous one walked.
	_inject_rect(Vector2i(0, 0), Vector2i(8, 8))
	player.current_cell = Vector2i(4, 4)
	spawner = _make_spawner()
	spawner.request_visitors(2)
	spawner._process(0.016)
	spawner._process(0.016)
	var vs := _visitors()
	assert_eq(vs.size(), 2)
	assert_ne(vs[0].rng, vs[1].rng)
	assert_ne(vs[0].rng, spawner.rng)


# ---------------------------------------------------------------------------
# Route noise
# ---------------------------------------------------------------------------
#
# Visitors are built straight from the scene here rather than through the
# spawner: the property under test is the route between a KNOWN pair of cells,
# and the spawner picks its goals at random.

func _make_visitor(goal: Vector2i, stream_seed: int, wander: float) -> Visitor:
	var v: Visitor = load("res://scenes/entities/visitor.tscn").instantiate()
	v.entry_cell = Vector2i(1, 1)
	v.goal_cell = goal
	v.wander_chance = wander
	v.rest_chance_per_step = 0.0
	v.rng = RandomNumberGenerator.new()
	v.rng.seed = stream_seed
	parent.add_child(v)
	return v


func test_the_shortest_path_is_unique_which_is_why_noise_exists() -> void:
	# The baseline the noise exists to break, now stated against the PATHFINDER
	# rather than against two visitors. It used to be asserted by walking two
	# wander-free visitors to one goal and comparing their paths — which stopped
	# being possible when standing cells became exclusive: they can no longer
	# share a destination, so their routes differ for a reason that has nothing
	# to do with the claim being made here.
	_inject_rect(Vector2i(0, 0), Vector2i(12, 12))
	var a := pf.find_path(Vector2i(1, 1), Vector2i(10, 10))
	var b := pf.find_path(Vector2i(1, 1), Vector2i(10, 10))
	assert_gt(a.size(), 0, "there must actually be a route")
	assert_eq(a, b, "identical endpoints give identical routes")


func test_two_visitors_never_stand_on_the_same_cell() -> void:
	# Even with no route noise at all, and even aimed at one goal, two visitors
	# must end up on different tiles.
	_inject_rect(Vector2i(0, 0), Vector2i(12, 12))
	var a := _make_visitor(Vector2i(10, 10), 1, 0.0)
	var b := _make_visitor(Vector2i(10, 10), 999, 0.0)
	assert_gt(a._path.size(), 0, "the visitor must actually have a route")
	assert_ne(a._goal_stand, b._goal_stand, "two visitors claimed one tile")
	assert_lte(Visitor.dist2(a._goal_stand, Vector2i(10, 10)), 8,
			"a standing cell must still be at the goal")
	assert_lte(Visitor.dist2(b._goal_stand, Vector2i(10, 10)), 8,
			"a standing cell must still be at the goal")


func test_a_crowded_goal_pushes_visitors_outward() -> void:
	# More visitors than the radius-1 disc holds: reserve_near must ring outward
	# rather than give up and stack everyone on the anchor.
	_inject_rect(Vector2i(0, 0), Vector2i(12, 12))
	var seen: Dictionary = {}
	for s in range(1, 13):
		var v := _make_visitor(Vector2i(6, 6), s, 0.0)
		assert_false(seen.has(v._goal_stand),
				"visitor %d stacked on %s" % [s, v._goal_stand])
		seen[v._goal_stand] = true


func test_noise_gives_two_visitors_two_routes() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(12, 12))
	var a := _make_visitor(Vector2i(10, 10), 1, 1.0)
	var b := _make_visitor(Vector2i(10, 10), 999, 1.0)
	assert_ne(a._path, b._path)


func test_a_noisy_route_is_still_a_legal_walk() -> void:
	# The reason the noise is applied to WAYPOINTS and not to the path: every
	# leg is still a find_path result, so no amount of wandering can produce a
	# step through a wall or across a gap.
	_inject_rect(Vector2i(0, 0), Vector2i(12, 12))
	for s in [1, 2, 3, 7, 11, 23]:
		var v := _make_visitor(Vector2i(10, 10), s, 1.0)
		var prev := v.current_cell
		for cell: Vector2i in v._path:
			var d := cell - prev
			assert_eq(absi(d.x) + absi(d.y), 1,
					"seed %d: %s -> %s is not one step" % [s, prev, cell])
			assert_true(pf.is_walkable(cell), "seed %d: %s is not walkable" % [s, cell])
			prev = cell
		# Arrives at ITS OWN standing cell, which is near the goal rather than on
		# it — the goal is shared, standing cells are not.
		assert_eq(prev, v._goal_stand, "seed %d: the detour must still arrive" % s)
		assert_lte(Visitor.dist2(v._goal_stand, Vector2i(10, 10)), 8,
				"seed %d: it arrived somewhere other than the goal" % s)


func test_a_noisy_route_is_a_detour_not_a_different_destination() -> void:
	# A wandering route leaves the optimal line — that is what makes it read as
	# wandering — but still arrives, and can never beat the optimum.
	#
	# The strong property is the SHAPE, not the length, and the distinction is
	# not pedantic: this map is an open rectangle, so every monotone route from
	# (1,1) to (10,10) is 18 steps and a waypoint only costs distance if it
	# leaves the start/goal bounding box. MEASURED over 400 seeds: routes leave
	# the direct line 100% of the time but come out LONGER only ~8% of it. An
	# earlier version of this test asserted the length on 6 hand-picked seeds and
	# passed on 2 of them by luck — it was measuring the geometry of the test
	# fixture, not the noise. Hence: shape on every seed, length over a range
	# wide enough for the real rate.
	# The optimum is measured PER VISITOR, against the cell that visitor actually
	# walks to: standing cells are exclusive, so each one has its own
	# destination near the shared goal and a single shared baseline would be
	# comparing routes to different places.
	_inject_rect(Vector2i(0, 0), Vector2i(12, 12))

	for s in [1, 2, 3, 7, 11, 23]:
		var v := _make_visitor(Vector2i(10, 10), s, 1.0)
		var optimal := pf.find_path(Vector2i(1, 1), v._goal_stand)
		var on_line: Dictionary = {}
		for cell: Vector2i in optimal:
			on_line[cell] = true
		assert_gte(v._path.size(), optimal.size() - 1,
				"seed %d: no route beats the optimum" % s)
		var strayed := false
		for cell: Vector2i in v._path:
			if not on_line.has(cell):
				strayed = true
				break
		assert_true(strayed, "seed %d: a noisy route must leave the direct line" % s)

	var longer: int = 0
	for s in range(1, 61):
		var w := _make_visitor(Vector2i(10, 10), s, 1.0)
		if w._path.size() > pf.find_path(Vector2i(1, 1), w._goal_stand).size() - 1:
			longer += 1
	assert_gt(longer, 0, "at least some noisy routes must actually detour")


# ---------------------------------------------------------------------------
# A party shares its waypoints
# ---------------------------------------------------------------------------

func _make_party_member(goal: Vector2i, anchors: Array[Vector2i],
		stream_seed: int) -> Visitor:
	var v: Visitor = load("res://scenes/entities/visitor.tscn").instantiate()
	v.entry_cell = Vector2i(1, 1)
	v.goal_cell = goal
	v.set_group_route(anchors)
	v.rest_chance_per_step = 0.0
	v.rng = RandomNumberGenerator.new()
	v.rng.seed = stream_seed
	parent.add_child(v)
	return v


func test_a_party_walks_near_its_shared_waypoints_not_identically() -> void:
	# The whole point of the two scales: members converge on the party's
	# waypoints and differ between them. Identical routes would be a column of
	# sprites; unrelated routes would make the group draw meaningless.
	_inject_rect(Vector2i(0, 0), Vector2i(12, 12))
	var anchors: Array[Vector2i] = [Vector2i(4, 6), Vector2i(7, 8)]
	var routes: Array = []
	for s in [1, 2, 3, 5, 8]:
		routes.append(_make_party_member(Vector2i(10, 10), anchors, s)._path)

	var distinct := 0
	for i in routes.size():
		var unique := true
		for j in range(0, i):
			if routes[i] == routes[j]:
				unique = false
		if unique:
			distinct += 1
	assert_gt(distinct, 1, "members must not all walk one identical line")

	# ...but every member must pass within a member-scatter of each waypoint.
	for i in routes.size():
		for anchor: Vector2i in anchors:
			var closest: int = 1 << 30
			for cell: Vector2i in routes[i]:
				closest = mini(closest, Visitor.dist2(cell, anchor))
			assert_lte(closest, 8,
					"member %d never came near the party's waypoint %s" % [i, anchor])


func test_a_party_route_is_shared_by_reference_and_never_mutated() -> void:
	# One array serves the whole group, and the way home reads it backwards —
	# a reverse() in place would flip the trail out from under members still
	# walking it forwards.
	_inject_rect(Vector2i(0, 0), Vector2i(12, 12))
	var anchors: Array[Vector2i] = [Vector2i(4, 6), Vector2i(7, 8)]
	var before := anchors.duplicate()
	var v := _make_party_member(Vector2i(10, 10), anchors, 1)
	# Drive the visitor home, which is the leg that reads the anchors reversed.
	v._state = Visitor.State.LINGER
	v._linger_left = 0.0
	v.tick(0.1)
	assert_eq(anchors, before, "the party's shared waypoints must not be mutated")


func test_the_spawner_draws_one_route_for_the_whole_party() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(12, 12))
	var s := _make_spawner()
	s.group_size_min = 4
	s.group_size_max = 4
	s.wander_chance = 1.0
	s.rng.seed = 7
	s.request_visitors(4)
	for _i in 8:
		s.tick(0.1)

	var crowd := _visitors()
	assert_eq(crowd.size(), 4, "the party must actually have spawned")
	var goal: Vector2i = crowd[0].goal_cell
	for v in crowd:
		assert_eq(v.goal_cell, goal, "a party shares one destination")
		assert_eq(v.route_anchors, crowd[0].route_anchors,
				"a party shares one set of waypoints")


# ---------------------------------------------------------------------------
# Waypoints are stops
# ---------------------------------------------------------------------------

func test_a_visitor_stands_still_on_each_waypoint() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(12, 12))
	var anchors: Array[Vector2i] = [Vector2i(4, 6)]
	var v := _make_party_member(Vector2i(10, 10), anchors, 1)
	v.member_wander_radius_cells = 0  # walk the party's waypoint exactly
	v.waypoint_pause_min = 2.0
	v.waypoint_pause_max = 2.0
	# Re-route now that the scatter radius is set; _ready already picked one.
	v._walk_to(v.goal_cell)
	assert_eq(v._waypoints.size(), 1, "the waypoint must be registered as a stop")
	assert_true(v._waypoints.has(Vector2i(4, 6)))

	var paused_at: Vector2i = Pathfinder.NO_CELL
	for _i in 400:
		v.tick(0.05)
		if v.is_paused():
			paused_at = v.current_cell
			break
	assert_eq(paused_at, Vector2i(4, 6), "the visitor must stop ON the waypoint")


func test_the_goal_is_not_a_waypoint_stop() -> void:
	# The goal has its own linger; registering it as a waypoint too would make a
	# visitor stand there for both.
	_inject_rect(Vector2i(0, 0), Vector2i(12, 12))
	var anchors: Array[Vector2i] = [Vector2i(4, 6)]
	var v := _make_party_member(Vector2i(10, 10), anchors, 1)
	assert_false(v._waypoints.has(Vector2i(10, 10)))


# ---------------------------------------------------------------------------
# Regrouping
# ---------------------------------------------------------------------------

func test_a_party_barrier_opens_only_when_everyone_has_arrived() -> void:
	var party := VisitorParty.new()
	party.member_joined()
	party.member_joined()
	party.member_joined()
	party.arrive(0)
	assert_false(party.is_released(0), "one arrival must not open a barrier of 3")
	party.arrive(0)
	assert_false(party.is_released(0))
	party.arrive(0)
	assert_true(party.is_released(0), "the last arrival opens it")


func test_a_departed_member_stops_being_waited_for() -> void:
	# The tidy drop-out path: two of three arrive, the third leaves, the barrier
	# opens rather than stranding the two who are already standing there.
	var party := VisitorParty.new()
	for _i in 3:
		party.member_joined()
	party.arrive(0)
	party.arrive(0)
	assert_false(party.is_released(0))
	party.member_left()
	assert_true(party.is_released(0), "a barrier must not wait on a departed member")


func test_a_release_is_latched_for_a_straggler() -> void:
	# A member that timed out at an earlier waypoint arrives here after the rest
	# have gone. It must not block on a barrier the party already passed.
	var party := VisitorParty.new()
	party.member_joined()
	party.arrive(0)
	assert_true(party.is_released(0))
	party.member_joined()
	assert_true(party.is_released(0), "a passed barrier must stay open")


func test_an_empty_party_never_traps_anyone() -> void:
	var party := VisitorParty.new()
	party.arrive(0)
	assert_true(party.is_released(0), "nobody left to wait for")


func test_a_member_waits_at_its_waypoint_for_its_party() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(12, 12))
	var anchors: Array[Vector2i] = [Vector2i(4, 6)]
	var party := VisitorParty.new()
	# A party of two, but only one of them actually exists here — so the barrier
	# can never open and the walker must be held by the timeout, not by luck.
	party.member_joined()
	party.member_joined()

	var v: Visitor = load("res://scenes/entities/visitor.tscn").instantiate()
	v.entry_cell = Vector2i(1, 1)
	v.goal_cell = Vector2i(10, 10)
	v.set_group_route(anchors)
	v._party = party  # already counted above
	v.member_wander_radius_cells = 0
	v.rest_chance_per_step = 0.0
	v.waypoint_pause_min = 0.01
	v.waypoint_pause_max = 0.01
	v.regroup_timeout_seconds = 5.0
	v.rng = RandomNumberGenerator.new()
	v.rng.seed = 1
	parent.add_child(v)

	# NOT `not is_moving()`: a member held at a waypoint still has the rest of
	# its route queued, so is_moving() stays true for the whole wait. The hold
	# shows up as the barrier index being set and the walker being paused.
	var held_at: Vector2i = Pathfinder.NO_CELL
	for _i in 600:
		v.tick(0.05)
		if v._regroup_index >= 0:
			held_at = v.current_cell
			break
	assert_eq(held_at, Vector2i(4, 6), "it must hold ON its waypoint")
	assert_true(v.is_paused(), "a held member must be standing still")

	# It is held well past the visible dwell...
	for _i in 20:
		v.tick(0.05)
	assert_gte(v._regroup_index, 0, "it must still be waiting for its party")

	# ...but the timeout releases it, which is the anti-deadlock guarantee.
	for _i in 200:
		v.tick(0.05)
	assert_eq(v._regroup_index, -1, "the timeout must release a stranded member")


func test_the_return_leg_uses_its_own_barriers() -> void:
	# The way home walks the same waypoints reversed. Sharing barrier keys with
	# the outbound leg would mean every one of them was already latched open.
	_inject_rect(Vector2i(0, 0), Vector2i(12, 12))
	var anchors: Array[Vector2i] = [Vector2i(4, 6)]
	var v := _make_party_member(Vector2i(10, 10), anchors, 1)
	var outbound: Array = v._waypoints.values()
	assert_eq(outbound.size(), 1)
	v._state = Visitor.State.LINGER
	v._linger_left = 0.0
	v.tick(0.1)
	var homeward: Array = v._waypoints.values()
	assert_eq(homeward.size(), 1, "the walk home must have its own waypoint")
	assert_ne(homeward[0], outbound[0],
			"the two legs must not share a barrier key")


class TrampleSpy:
	extends Node

	var cells: Array[Vector2i] = []

	func _ready() -> void:
		add_to_group(&"regrowth")  # literal: see visitor.gd._trample

	func trample(cell: Vector2i) -> void:
		cells.append(cell)


func test_every_step_wears_the_ground_it_lands_on() -> void:
	# Visitors are the ONLY source of trampling, so this connection is the whole
	# feature; RegrowthManager decides what a cell actually loses.
	_inject_rect(Vector2i(0, 0), Vector2i(12, 12))
	var spy := TrampleSpy.new()
	add_child_autofree(spy)
	var v := _make_visitor(Vector2i(10, 10), 5, 0.0)
	var route := v._path.duplicate()

	for _i in 400:
		v.tick_movement(1.0 / 60.0)

	assert_gt(spy.cells.size(), 0, "nothing was reported as walked on")
	assert_eq(spy.cells, route.slice(0, spy.cells.size()),
			"the cells reported must be the cells actually stepped onto, in order")


func test_a_visitor_without_a_regrowth_node_still_walks() -> void:
	# The spawner runs on maps that may not carry every system; a missing one
	# must not stop the walk.
	_inject_rect(Vector2i(0, 0), Vector2i(12, 12))
	var v := _make_visitor(Vector2i(10, 10), 5, 0.0)
	for _i in 60:
		v.tick_movement(1.0 / 60.0)
	assert_ne(v.current_cell, Vector2i(1, 1))


func test_a_breather_stops_the_visitor_where_it_stands() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(12, 12))
	var v := _make_visitor(Vector2i(10, 10), 5, 0.0)
	v.rest_chance_per_step = 1.0  # certain, so this is not a test of the dice
	v.tick_movement(0.016)
	assert_true(v.is_paused(), "the roll happens as a step begins")


# ---------------------------------------------------------------------------
# Opening hours
# ---------------------------------------------------------------------------

func test_the_window_is_a_half_open_interval() -> void:
	spawner = _make_spawner()
	spawner.opening_hour = 6.0
	spawner.closing_hour = 17.0
	assert_false(spawner.is_open_at(5.0 / 24.0), "05:00 is before opening")
	assert_true(spawner.is_open_at(6.0 / 24.0), "opening itself is open")
	assert_true(spawner.is_open_at(12.0 / 24.0))
	assert_false(spawner.is_open_at(17.0 / 24.0), "closing itself is shut")
	assert_false(spawner.is_open_at(23.0 / 24.0))


func test_a_window_may_wrap_past_midnight() -> void:
	spawner = _make_spawner()
	spawner.opening_hour = 20.0
	spawner.closing_hour = 4.0
	assert_true(spawner.is_open_at(22.0 / 24.0))
	assert_true(spawner.is_open_at(1.0 / 24.0))
	assert_false(spawner.is_open_at(12.0 / 24.0))


func test_nobody_arrives_before_opening() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(8, 8))
	player.current_cell = Vector2i(4, 4)
	spawner = _make_spawner()
	TimeManager.time_of_day = 3.0 / 24.0
	spawner.request_visitors(3)
	for _i in 5:
		spawner._process(0.016)
	assert_eq(_visitors().size(), 0)
	# VisitorFlow banks the day's arrivals AT MIDNIGHT, so dropping them here
	# would drop every visitor the game ever produces.
	assert_eq(spawner.pending_count(), 3, "they wait for opening, they are not lost")


func test_the_queue_is_paid_out_once_the_gate_opens() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(8, 8))
	player.current_cell = Vector2i(4, 4)
	spawner = _make_spawner()
	TimeManager.time_of_day = 3.0 / 24.0
	spawner.request_visitors(2)
	spawner._process(0.016)
	assert_eq(_visitors().size(), 0)
	TimeManager.time_of_day = 9.0 / 24.0
	spawner._process(0.016)
	assert_eq(_visitors().size(), 1)


func test_closing_time_sends_the_mountain_home() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(8, 8))
	player.current_cell = Vector2i(4, 4)
	spawner = _make_spawner()
	spawner.request_visitors(2)
	spawner._process(0.016)
	spawner._process(0.016)
	assert_eq(_visitors().size(), 2)

	TimeManager.time_of_day = 18.0 / 24.0
	spawner._process(0.016)
	for v in _visitors():
		# TO_EXIT, not LEAVING: closing means WALK to the trailhead. LEAVING is
		# the terminal fade, and setting it here stopped the whole crowd
		# mid-mountain and dissolved it in fade_seconds.
		assert_eq(v._state, Visitor.State.TO_EXIT,
				"everyone still out at closing heads for the entry on foot")
		assert_true(v.is_moving(), "and is actually walking there")


func test_a_visitor_sent_home_reaches_the_entry_before_it_despawns() -> void:
	# The whole point of walking out: the trailhead sees the departing traffic.
	# Driven to completion rather than asserting the state, because "walks home"
	# is only true if the walk ends AT the entry.
	_inject_rect(Vector2i(0, 0), Vector2i(8, 8))
	player.current_cell = Vector2i(4, 4)
	spawner = _make_spawner()
	spawner.request_visitors(1)
	spawner._process(0.016)
	var v: Visitor = _visitors()[0]
	var entry: Vector2i = v.entry_cell

	# Walk it OFF the entry first. A visitor spawns standing on the entry cell,
	# so without this the assertion below holds even for a visitor that never
	# moves — which is exactly the behaviour this test exists to reject.
	for _i in 200:
		if v.current_cell != entry:
			break
		v.tick(0.05)
	assert_ne(v.current_cell, entry, "the test needs it out on the mountain")

	TimeManager.time_of_day = 18.0 / 24.0
	spawner._process(0.016)

	var last_cell := v.current_cell
	for _i in 4000:
		if not is_instance_valid(v) or v._state == Visitor.State.LEAVING:
			break
		v.tick(0.05)
		last_cell = v.current_cell
	assert_eq(last_cell, entry, "the walk home ends on the entry cell")


func test_nobody_new_arrives_after_closing() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(8, 8))
	player.current_cell = Vector2i(4, 4)
	spawner = _make_spawner()
	spawner.request_visitors(3)
	spawner._process(0.016)
	assert_eq(_visitors().size(), 1)

	TimeManager.time_of_day = 18.0 / 24.0
	for _i in 20:
		spawner._process(1.0)
	assert_eq(_visitors().size(), 1,
			"the gate is shut; the queue waits for morning")
	assert_gt(spawner.pending_count(), 0, "and is not thrown away")


func test_closing_can_be_left_to_run_its_course() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(8, 8))
	player.current_cell = Vector2i(4, 4)
	spawner = _make_spawner()
	spawner.send_home_at_closing = false
	spawner.request_visitors(1)
	spawner._process(0.016)
	TimeManager.time_of_day = 18.0 / 24.0
	spawner._process(0.016)
	assert_ne(_visitors()[0]._state, Visitor.State.LEAVING)


# ---------------------------------------------------------------------------
# Visitor.nearest_reachable — the mid-walk graph change
# ---------------------------------------------------------------------------

func test_nearest_reachable_picks_the_closest_qualifying_cell() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(5, 5))
	var reach := pf.compute_reachable_set(Vector2i(0, 0))
	var got := Visitor.nearest_reachable(reach, Vector2i(4, 4), Vector2i(0, 0), pf)
	assert_eq(got, Vector2i(4, 4), "the target itself qualifies when it is reachable")


func test_nearest_reachable_falls_back_to_a_neighbour() -> void:
	_inject_rect(Vector2i(0, 0), Vector2i(5, 5))
	var reach := pf.compute_reachable_set(Vector2i(0, 0))
	# (9, 9) is nowhere near the landmass; the closest set member wins.
	var got := Visitor.nearest_reachable(reach, Vector2i(9, 9), Vector2i(0, 0), pf)
	assert_eq(got, Vector2i(4, 4))


func test_nearest_reachable_returns_no_cell_when_nothing_qualifies() -> void:
	var got := Visitor.nearest_reachable({}, Vector2i(1, 1), Vector2i(0, 0), pf)
	assert_eq(got, Pathfinder.NO_CELL)
