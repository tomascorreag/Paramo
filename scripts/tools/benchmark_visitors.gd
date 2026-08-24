extends SceneTree
## Prices the visitor system's three expensive operations against a REAL crowd
## on a real map.
##
## Why this exists rather than reading the balance simulator's wall clock: the
## sim is dominated by fire (~1900 ignitions and ~90 concurrent fires a run
## against 8 visitors), so a visitor change lands inside its noise — measured,
## two 16-seed sweeps of the SAME code disagreed by 8% purely on machine drift,
## which is larger than anything this system can do. So the operations are timed
## HERE, in one process, with the old and new implementations ALTERNATED round
## by round. Drift then hits both arms equally and the RATIO is trustworthy even
## when the absolute milliseconds are not.
##
## Three phases, each answering a question the code comments make a claim about:
##
##   graph change   The player lays a fence. Every tile of the run emits
##                  Pathfinder.graph_changed, and a visitor's response used to
##                  be an unconditional re-route (several A* runs). It is now
##                  GridWalker.path_is_valid() first, which re-routes only the
##                  visitors the change actually broke. Times both per visitor.
##
##   nearest goal   Visitor.nearest_reachable, the relocation a visitor does
##                  when a fence cuts it off from its goal. The old version
##                  sort_custom'd the whole reachable set through a GDScript
##                  lambda; the new one keeps the nearest few in one linear
##                  pass. Times both against the spawner's real reach set.
##
##   per frame      What the crowd costs every frame with nobody re-routing:
##                  VisitorSpawner.tick driving N visitors. No A/B — it is the
##                  floor, reported so the two figures above can be read
##                  against it.
##
## Needs a rendering context — do NOT pass --headless (the map paints tiles).
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/benchmark_visitors.gd
##
## Args:
##   --scene <res>   map to run on (default: level1)
##   --count <n>     crowd size (default 8, the shipped max_concurrent)
##   --frames <n>    frames of walking before measuring (default 400), so the
##                   crowd is spread out and mid-route rather than stacked on
##                   the entry cell with two-step paths
##   --rounds <n>    A/B rounds per phase (default 6)

const DEFAULT_SCENE := "res://scenes/maps/level1.tscn"
const WINDOW_SIZE := Vector2i(960, 540)
const GRID_STABLE_FRAMES: int = 90
const MIN_SETTLE_FRAMES: int = 60

## Mirrors the bound in Visitor. Kept as a literal so the old and new
## implementations here stay independent of an edit to that constant.
const NEAREST_CANDIDATES: int = 12

var _scene_path: String = DEFAULT_SCENE
var _count: int = 8
var _walk_frames: int = 400
var _rounds: int = 6

var _map: Node = null
var _spawner: Node = null
var _pathfinder: Pathfinder = null
var _frames: int = 0
var _walk_until: int = -1
var _grid_stamp: int = 0
var _stable_since: int = 0


func _initialize() -> void:
	_parse_args()


func _parse_args() -> void:
	var argv := OS.get_cmdline_user_args()
	var i: int = 0
	while i < argv.size():
		match argv[i]:
			"--scene": _scene_path = argv[i + 1]; i += 1
			"--count": _count = int(argv[i + 1]); i += 1
			"--frames": _walk_frames = int(argv[i + 1]); i += 1
			"--rounds": _rounds = int(argv[i + 1]); i += 1
		i += 1


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		if current_scene != null:
			current_scene.queue_free()
		DisplayServer.window_set_size(WINDOW_SIZE)
		_map = load(_scene_path).instantiate()
		root.add_child(_map)
		return false
	if _walk_until < 0:
		# The map generates and PAINTS across many frames, rebuilding the
		# pathfinder graph as it goes; measuring before it settles measures the
		# generator.
		if not _grid_settled():
			if _frames > 3000:
				push_error("benchmark_visitors: the grid never settled.")
				quit(1)
				return true
			return false
		if not _start_crowd():
			quit(1)
			return true
		_walk_until = _frames + _walk_frames
		return false
	if _frames < _walk_until:
		return false

	var crowd := _live_visitors()
	print("\n=== benchmark_visitors: %s ===" % _scene_path)
	if crowd.is_empty():
		push_error("benchmark_visitors: nobody spawned; nothing to measure.")
		quit(1)
		return true
	print("crowd %d, reachable set %d cells, %d frames walked, %d rounds"
			% [crowd.size(), _reach().size(), _walk_frames, _rounds])

	_phase_graph_change(crowd)
	_phase_nearest_reachable(crowd)
	_phase_per_frame()
	_phase_routing_strategies()
	quit(0)
	return true


# ----------------------------------------------------------------------------
# Phase 4 — per-member A* vs a per-party cost field
# ----------------------------------------------------------------------------

## Settles the "surely a Dijkstra field is heavy" question with numbers instead
## of intuition. Times, on the real graph:
##   - one Pathfinder.find_path between two random reachable cells (what a
##     member pays PER WAYPOINT today, on spawn and on every re-route)
##   - one full cost-to-goal FIELD, heap Dijkstra over the same traversal model
##     and the same per-step costs the walkers pay
##   - one greedy DESCENT of that field, which is what a member would pay
##     instead of an A* once the party holds a field
##
## VERDICT, so nobody re-argues it: the field LOSES here, at every party size.
## A*'s cost scales with LEG LENGTH, a field's with REACHABLE-SET SIZE, and this
## map has the worst possible ratio — ~4-cell legs across a ~450-cell disc. The
## field is ~8x one A*, so sharing it across even five members does not pay for
## it, and a graph change that invalidates it costs ~9x the re-route it replaced.
##
## Note the sampling: legs are DISTANCE-MATCHED to the real waypoint spacing. An
## earlier version drew random cross-map pairs, which put A* at 8.3 ms instead of
## 2.3 ms and made the field look like a 2.5x win at M=5. It was measuring the
## sample. If you change the sampler, you are changing the answer.
func _phase_routing_strategies() -> void:
	var reach := _reach()
	var cells: Array = reach.keys()
	if cells.size() < 8:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210
	# Distance-MATCHED, not random cross-map pairs. A*'s cost scales with how far
	# it has to search and a field's does not, so comparing them on a sample of
	# whatever-length routes measures the sample, not the algorithms. A real leg
	# is short: min_goal_distance is 6 cells and the waypoints cut the route into
	# wander_waypoints_max+1 pieces.
	var pairs: Array = []
	var legs := _real_leg_cells(crowd_legs())
	for i in _rounds:
		var a: Vector2i = cells[rng.randi_range(0, cells.size() - 1)]
		var b := _cell_about(a, legs, cells, rng)
		if b != Pathfinder.NO_CELL:
			pairs.append([a, b])
	if pairs.is_empty():
		return
	print("\n(legs sampled at ~%d cells, the real spacing between waypoints)" % legs)

	var astar_us: float = 0.0
	for p in pairs:
		var t := Time.get_ticks_usec()
		_pathfinder.find_path(p[0], p[1])
		astar_us += float(Time.get_ticks_usec() - t)
	astar_us /= float(pairs.size())

	var field_us: float = 0.0
	var descent_us: float = 0.0
	var descent_ok: int = 0
	for p in pairs:
		var t := Time.get_ticks_usec()
		var field := _cost_field(p[1], reach)
		field_us += float(Time.get_ticks_usec() - t)
		var t2 := Time.get_ticks_usec()
		var route := _descend(field, p[0], p[1], rng)
		descent_us += float(Time.get_ticks_usec() - t2)
		if not route.is_empty():
			descent_ok += 1
	field_us /= float(pairs.size())
	descent_us /= float(pairs.size())

	print("\nrouting strategies over %d reachable cells" % reach.size())
	print("  A* find_path (per waypoint, per member)  %8.1f us" % astar_us)
	print("  cost FIELD  (per waypoint, per PARTY)    %8.1f us" % field_us)
	print("  field DESCENT (per waypoint, per member) %8.1f us   (%d/%d routed)"
			% [descent_us, descent_ok, pairs.size()])

	# What a party actually costs to route, which is the number that decides it.
	var waypoints: int = _spawner.get(&"wander_waypoints_max") + 1
	print("  a party of M, %d legs each:" % waypoints)
	for m in [1, 3, 5]:
		var now: float = float(m * waypoints) * astar_us
		var fld: float = float(waypoints) * field_us + float(m * waypoints) * descent_us
		print("    M=%d   per-member A* %8.1f us   vs   party field %8.1f us   (%.2fx)"
				% [m, now, fld, now / maxf(fld, 0.001)])


## Cost-to-goal for every reachable cell, by Dijkstra with a binary heap.
##
## Prices each edge with TileGrid.step_duration_for — the same table the walkers
## pay — so ramps and ladders cost what they really cost. The relaxation is on
## the REVERSE edge (can_transition(nb, cur)): this is cost TO the goal, and
## ladder/ramp transitions are not symmetric, so relaxing the forward edge would
## quietly let walkers descend cliffs they cannot climb.
func _cost_field(goal: Vector2i, reach: Dictionary) -> Dictionary:
	var grid: TileGrid = _pathfinder.grid()
	var dist: Dictionary[Vector2i, float] = {goal: 0.0}
	var heap: Array = [[0.0, goal]]
	while not heap.is_empty():
		var top: Array = _heap_pop(heap)
		var cur: Vector2i = top[1]
		if float(top[0]) > float(dist[cur]) + 0.0001:
			continue
		for d in _DIRS:
			var nb: Vector2i = cur + d
			if not reach.has(nb) or not grid.can_transition(nb, cur):
				continue
			var kind: int = grid.classify_step(nb, cur)
			var alt_delta: float = absf(
					grid.altitude_center(cur) - grid.altitude_center(nb))
			var nd: float = float(dist[cur]) \
					+ TileGrid.step_duration_for(kind, alt_delta, 1.0, 2.0, 4.0)
			if not dist.has(nb) or nd < float(dist[nb]) - 0.0001:
				dist[nb] = nd
				_heap_push(heap, [nd, nb])
	return dist


## Walk down the field from `from` to `goal`, breaking ties RANDOMLY — which is
## where the route variety comes from, in place of per-member scattered
## waypoints. Every step is a legal transition by construction.
func _descend(field: Dictionary, from: Vector2i, goal: Vector2i,
		stream: RandomNumberGenerator) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if not field.has(from):
		return out
	var grid: TileGrid = _pathfinder.grid()
	var cur := from
	var guard: int = 0
	while cur != goal and guard < 4000:
		guard += 1
		var best: float = INF
		var ties: Array[Vector2i] = []
		for d in _DIRS:
			var nb: Vector2i = cur + d
			if not field.has(nb) or not grid.can_transition(cur, nb):
				continue
			var c: float = float(field[nb])
			if c < best - 0.0001:
				best = c
				ties = [nb]
			elif absf(c - best) <= 0.0001:
				ties.append(nb)
		if ties.is_empty() or best >= float(field[cur]):
			return [] as Array[Vector2i]
		cur = ties[stream.randi_range(0, ties.size() - 1)]
		out.append(cur)
	return out


const _DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]


## How many legs a party's route is cut into (waypoints + the final hop).
func crowd_legs() -> int:
	return maxi(int(_spawner.get(&"wander_waypoints_max")), 0) + 1


## Cells between consecutive waypoints on a real route: the entry-to-goal span
## divided by the number of legs. Measured off the live crowd rather than
## assumed, because the goal sampler only guarantees a MINIMUM distance.
func _real_leg_cells(legs: int) -> int:
	var entry: Vector2i = _spawner.call(&"entry_cell")
	var spans: Array[float] = []
	for v in _live_visitors():
		spans.append(sqrt(float(Visitor.dist2(v.get(&"goal_cell"), entry))))
	if spans.is_empty():
		return maxi(int(_spawner.get(&"min_goal_distance")), 1)
	var total: float = 0.0
	for s in spans:
		total += s
	return maxi(int(round(total / float(spans.size()) / float(legs))), 1)


## A reachable cell roughly `want` cells away from `around`. Sampled rather than
## searched — the set is a few hundred cells and most radii are populated.
func _cell_about(around: Vector2i, want: int, cells: Array,
		stream: RandomNumberGenerator) -> Vector2i:
	var target_d2: int = want * want
	var best := Pathfinder.NO_CELL
	var best_err: int = 1 << 30
	for _attempt in 48:
		var c: Vector2i = cells[stream.randi_range(0, cells.size() - 1)]
		var err: int = absi(Visitor.dist2(c, around) - target_d2)
		if err < best_err:
			best_err = err
			best = c
	return best


func _heap_push(heap: Array, item: Array) -> void:
	heap.append(item)
	var i: int = heap.size() - 1
	while i > 0:
		var parent: int = (i - 1) / 2
		if float(heap[parent][0]) <= float(heap[i][0]):
			break
		var tmp: Array = heap[parent]
		heap[parent] = heap[i]
		heap[i] = tmp
		i = parent


func _heap_pop(heap: Array) -> Array:
	var top: Array = heap[0]
	var last: Array = heap.pop_back()
	if heap.is_empty():
		return top
	heap[0] = last
	var i: int = 0
	while true:
		var l: int = 2 * i + 1
		var r: int = l + 1
		var small: int = i
		if l < heap.size() and float(heap[l][0]) < float(heap[small][0]):
			small = l
		if r < heap.size() and float(heap[r][0]) < float(heap[small][0]):
			small = r
		if small == i:
			break
		var tmp: Array = heap[small]
		heap[small] = heap[i]
		heap[i] = tmp
		i = small
	return top


# ----------------------------------------------------------------------------
# Phase 1 — the response to one graph_changed
# ----------------------------------------------------------------------------

## OLD: every visitor re-routes unconditionally. NEW: every visitor validates
## its queued path and only re-routes if it broke. Both are run per round, in
## alternating order, on the same crowd.
##
## The re-route arm MUTATES the crowd (it releases and re-takes standing cells
## and re-rolls the route noise) — that is exactly what the old code did on
## every signal, and it is why the two arms are interleaved rather than run as
## two blocks.
func _phase_graph_change(crowd: Array) -> void:
	var old_us: float = 0.0
	var new_us: float = 0.0
	var broken: int = 0
	for r in _rounds:
		var t0 := Time.get_ticks_usec()
		for v in crowd:
			if is_instance_valid(v):
				v.call(&"_walk_to", v.get(&"goal_cell"))
		old_us += float(Time.get_ticks_usec() - t0)

		var t1 := Time.get_ticks_usec()
		for v in crowd:
			if is_instance_valid(v) and not v.call(&"path_is_valid"):
				broken += 1
		new_us += float(Time.get_ticks_usec() - t1)
	var n: float = float(_rounds * crowd.size())
	print("\ngraph change, per visitor per signal")
	print("  old (always re-route)  %8.1f us" % (old_us / n))
	print("  new (validate first)   %8.1f us   (%d of %d validations found a broken route)"
			% [new_us / n, broken, int(n)])
	print("  speedup                %8.1fx on the unbroken case, which is almost all of them"
			% (old_us / maxf(new_us, 0.001)))
	# A fence RUN emits one signal PER TILE, and the spawner answered each with a
	# full flood fill; both ends are now coalesced into one per frame.
	var t2 := Time.get_ticks_usec()
	for r in _rounds:
		_pathfinder.compute_reachable_set(_spawner.call(&"entry_cell"))
	var fill_us := float(Time.get_ticks_usec() - t2) / float(_rounds)
	print("  spawner flood fill     %8.1f us  x1 per FRAME now, was x1 per fence TILE"
			% fill_us)


# ----------------------------------------------------------------------------
# Phase 2 — relocating a cut-off visitor's goal
# ----------------------------------------------------------------------------

func _phase_nearest_reachable(crowd: Array) -> void:
	var reach := _reach()
	var from: Vector2i = crowd[0].get(&"current_cell")
	var target: Vector2i = crowd[0].get(&"goal_cell")
	var old_us: float = 0.0
	var new_us: float = 0.0
	for r in _rounds:
		var t0 := Time.get_ticks_usec()
		var a := _nearest_reachable_old(reach, target, from)
		old_us += float(Time.get_ticks_usec() - t0)
		var t1 := Time.get_ticks_usec()
		var b := Visitor.nearest_reachable(reach, target, from, _pathfinder)
		new_us += float(Time.get_ticks_usec() - t1)
		if r == 0:
			print("\nnearest_reachable over %d reachable cells" % reach.size())
			print("  old picked %s, new picked %s%s"
					% [a, b, "" if a == b else "   <-- DIFFERENT, investigate"])
	print("  old (sort the whole set)  %8.1f us" % (old_us / float(_rounds)))
	print("  new (nearest %d only)      %8.1f us" % [NEAREST_CANDIDATES, new_us / float(_rounds)])
	print("  speedup                   %8.1fx" % (old_us / maxf(new_us, 0.001)))


## The implementation this replaced, kept here ONLY so the comparison above runs
## both in one process. Do not reintroduce it: it sort_custom's the entire
## reachable set through a GDScript lambda.
func _nearest_reachable_old(reach_set: Dictionary, target: Vector2i,
		from: Vector2i) -> Vector2i:
	var ordered: Array = reach_set.keys()
	ordered.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return Visitor.dist2(a, target) < Visitor.dist2(b, target))
	for cell: Vector2i in ordered:
		if cell == from or not _pathfinder.is_walkable(cell):
			continue
		if _pathfinder.find_path(from, cell).size() >= 2:
			return cell
	return Pathfinder.NO_CELL


# ----------------------------------------------------------------------------
# Phase 3 — the steady-state frame cost
# ----------------------------------------------------------------------------

## No A/B: this is the floor the two phases above should be read against. The
## spawner drives the whole crowd itself, so one tick IS the crowd's frame.
func _phase_per_frame() -> void:
	var live: int = int(_spawner.call(&"live_count"))
	var ticks: int = 600
	var t0 := Time.get_ticks_usec()
	for i in ticks:
		_spawner.call(&"tick", 1.0 / 60.0)
	var per_tick := float(Time.get_ticks_usec() - t0) / float(ticks)
	print("\nsteady state, %d visitor(s)" % live)
	print("  spawner.tick   %8.1f us/frame  (%.1f us per visitor)"
			% [per_tick, per_tick / maxf(float(live), 1.0)])


# ----------------------------------------------------------------------------
# Setup
# ----------------------------------------------------------------------------

func _reach() -> Dictionary:
	return _pathfinder.compute_reachable_set(_spawner.call(&"entry_cell"))


func _grid_settled() -> bool:
	_pathfinder = root.get_tree().get_first_node_in_group(&"pathfinder") as Pathfinder
	if _pathfinder == null:
		return false
	var grid: Object = _pathfinder.grid()
	var stamp: int = grid.get_instance_id() if grid != null else 0
	if stamp == 0:
		return false
	if stamp != _grid_stamp:
		_grid_stamp = stamp
		_stable_since = _frames
		return false
	return _frames >= MIN_SETTLE_FRAMES and (_frames - _stable_since) >= GRID_STABLE_FRAMES


## Same gates preview_visitor_palettes.gd forces, and for the same reason: a
## paused clock or a planning phase is real gameplay behaviour that would leave
## this tool measuring an empty map. Reached through the tree rather than by
## name — under --script the autoloads are not global identifiers when this file
## compiles.
func _start_crowd() -> bool:
	_spawner = _map.find_child("VisitorSpawner", true, false)
	if _spawner == null:
		push_error("benchmark_visitors: no VisitorSpawner in %s." % _scene_path)
		return false
	var seasons := root.get_node_or_null(^"/root/SeasonManager")
	if seasons != null:
		seasons.set(&"phase", 1)  # SeasonManager.Phase.ACTIVE
	var clock := root.get_node_or_null(^"/root/TimeManager")
	if clock != null:
		clock.set(&"paused", false)
		clock.set(&"time_of_day", 0.5)  # midday, inside opening hours
	_spawner.set(&"stagger_seconds", 0.0)
	_spawner.set(&"group_member_stagger_seconds", 0.0)
	_spawner.set(&"max_concurrent", maxi(int(_spawner.get(&"max_concurrent")), _count))
	_spawner.call(&"request_visitors", _count)
	return true


## Visitors are deliberately NOT in a group (ObjectPainter's regenerate sweep
## frees group members under World), so they are found by type.
func _live_visitors() -> Array:
	var out: Array = []
	for n in _map.find_children("*", "Node2D", true, false):
		if n is Visitor:
			out.append(n)
	return out
