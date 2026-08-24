extends SceneTree
## Prices Pathfinder.find_path on REAL legs, and A/Bs the levers that could make
## it cheaper.
##
## Why: profile_day_boundary.gd measured a 30-step route at 48 ms — one frame of
## stutter per visitor spawn, and the whole crowd's worth at closing time. The
## repo's existing "one A* costs 2.3 ms" figure came from benchmark_visitors.gd,
## which samples the 4-cell legs BETWEEN waypoints; the leg a visitor actually
## builds at spawn is entry->goal, tens of cells, and A* cost is superlinear in
## it here.
##
## Variants timed against the shipped implementation, all on the same graph and
## the same leg set. Each isolates ONE suspicion:
##
##   cached-enter  identical search, but `_cell_enter_cost(nb)` memoized per
##                 cell for the duration of one search. It is a pure function of
##                 the cell (ramp size, penalty dict, occupant walk_penalty) and
##                 is currently recomputed on every edge INTO that cell — up to
##                 4 incoming directions x every parent state.
##
##   no-dir        drops the incoming direction from the search key, which the
##                 original search carried to buy a 1e-4 turn penalty at a 5x
##                 state space. SHIPPED SINCE 2026-08-10, so this row is now a
##                 record of where that 3.4x came from rather than a proposal;
##                 `mirror` is the version it replaced.
##
##   weighted      admissibility traded for focus: h x `--weight`. The shipped
##                 heuristic is Manhattan with a unit step, but every ramp cell
##                 charges _RAMP_PENALTY_PER_STEP on top, so a real path costs
##                 more per step than the heuristic predicts and the search
##                 degenerates toward Dijkstra. Reports the path-length penalty
##                 paid for the speed.
##
## Needs a rendering context — do NOT pass --headless (the map paints tiles).
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/benchmark_pathfinder.gd
##
## Args:
##   --scene <res>   map (default: level1)
##   --legs <n>      legs sampled (default 24)
##   --weight <f>    heuristic weight for the weighted variant (default 1.25)

const DEFAULT_SCENE := "res://scenes/maps/level1.tscn"
const WINDOW_SIZE := Vector2i(960, 540)
const GRID_STABLE_FRAMES: int = 90
const MIN_SETTLE_FRAMES: int = 60

const _DIRS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
const _TURN_EPSILON: float = 1e-4
const _RAMP_PENALTY_PER_STEP: float = 0.15

var _scene_path: String = DEFAULT_SCENE
var _legs: int = 24
var _weight: float = 1.25

var _map: Node = null
var _pathfinder: Pathfinder = null
var _grid: TileGrid = null
var _frames: int = 0
var _grid_stamp: int = 0
var _stable_since: int = 0

## Expansions (heap pops) of the last variant search, so the timings can be read
## as "explored N states" rather than as an opaque millisecond count.
var _pops: int = 0


func _initialize() -> void:
	var argv := OS.get_cmdline_user_args()
	var i: int = 0
	while i < argv.size():
		match argv[i]:
			"--scene": _scene_path = argv[i + 1]; i += 1
			"--legs": _legs = int(argv[i + 1]); i += 1
			"--weight": _weight = float(argv[i + 1]); i += 1
		i += 1


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		if current_scene != null:
			current_scene.queue_free()
		DisplayServer.window_set_size(WINDOW_SIZE)
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
		_map = load(_scene_path).instantiate()
		root.add_child(_map)
		return false
	if not _settled():
		if _frames > 3000:
			push_error("benchmark_pathfinder: the grid never settled.")
			quit(1)
			return true
		return false

	_grid = _pathfinder.grid()
	_report()
	quit(0)
	return true


func _report() -> void:
	var spawner := _map.find_child("VisitorSpawner", true, false)
	var entry: Vector2i = spawner.call(&"entry_cell") if spawner != null \
			else Pathfinder.NO_CELL
	var reach: Dictionary = _pathfinder.compute_reachable_set(entry)
	var cells: Array = reach.keys()
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234567

	# The leg a visitor really builds at SPAWN: entry -> goal, goal drawn the way
	# VisitorSpawner._pick_goal draws it. Not the short between-waypoint hop
	# benchmark_visitors.gd samples.
	var min_d: int = int(spawner.get(&"min_goal_distance")) if spawner != null else 6
	var pairs: Array = []
	while pairs.size() < _legs:
		var c: Vector2i = cells[rng.randi_range(0, cells.size() - 1)]
		if Visitor.dist2(c, entry) < min_d * min_d:
			continue
		pairs.append([entry, c])

	print("\n=== benchmark_pathfinder: %s ===" % _scene_path)
	print("grid %d walkable cells, reachable from entry %s: %d cells"
			% [_grid.walkable_cells().size(), entry, reach.size()])
	print("%d legs, entry -> a goal at least %d cells away (a real SPAWN leg)"
			% [_legs, min_d])

	var shipped := _time(pairs, func(a: Vector2i, b: Vector2i) -> Array:
		return _pathfinder.find_path(a, b))
	var cached := _time(pairs, func(a: Vector2i, b: Vector2i) -> Array:
		return _astar(a, b, true, true, 1.0))
	var nodir := _time(pairs, func(a: Vector2i, b: Vector2i) -> Array:
		return _astar(a, b, false, true, 1.0))
	var weighted := _time(pairs, func(a: Vector2i, b: Vector2i) -> Array:
		return _astar(a, b, true, true, _weight))
	var nodir_w := _time(pairs, func(a: Vector2i, b: Vector2i) -> Array:
		return _astar(a, b, false, true, _weight))

	# The edge TABLE: every walkable cell's legal exits and their costs, resolved
	# once. In the real system it is built per graph change and reused by every
	# search until the next one, so its build cost is reported separately rather
	# than charged to a leg.
	var tb := Time.get_ticks_usec()
	_build_edges()
	var build_ms := float(Time.get_ticks_usec() - tb) / 1000.0
	var tabled := _time(pairs, func(a: Vector2i, b: Vector2i) -> Array:
		return _astar_tabled(a, b, true, 1.0))
	var tabled_nodir := _time(pairs, func(a: Vector2i, b: Vector2i) -> Array:
		return _astar_tabled(a, b, false, 1.0))

	# The shipped implementation re-derived here, to prove the copy is faithful
	# before any of its numbers are believed.
	var mirror := _time(pairs, func(a: Vector2i, b: Vector2i) -> Array:
		return _astar(a, b, true, false, 1.0))

	# `mirror` is the ORIGINAL search — (cell, direction) state, turn penalty and
	# all — so this reports how far the shipped one has drifted from it. LENGTH
	# is the contract and must never differ; the ROUTE is expected to, now that
	# the direction key is gone and ties fall to the heap's FIFO order.
	var differ: int = 0
	var longer: int = 0
	for pair in pairs:
		var now: Array = _pathfinder.find_path(pair[0], pair[1])
		var was: Array = _astar(pair[0], pair[1], true, false, 1.0)
		if now == was:
			continue
		differ += 1
		if now.size() != was.size():
			longer += 1
		print("  %s -> %s: %d steps now, %d before" % [pair[0], pair[1], now.size(), was.size()])
	print("\npath equivalence, shipped vs pre-cache search: %d of %d legs differ, %d at a different LENGTH"
			% [differ, pairs.size(), longer])
	print("(same-length differences are expected: the shipped search no longer")
	print(" prefers the straightest of the equally-short routes. A difference at a")
	print(" different LENGTH is a real regression.)")

	print("\n%-14s %10s %10s %10s %8s" % ["variant", "mean ms", "worst ms", "pops", "steps"])
	_row("shipped", shipped)
	_row("mirror", mirror)
	_row("cached-enter", cached)
	_row("no-dir", nodir)
	_row("weighted %.2f" % _weight, weighted)
	_row("no-dir+w", nodir_w)
	_row("edge-table", tabled)
	_row("table+no-dir", tabled_nodir)
	print("
edge table: %d cells resolved in %.1f ms, once per graph change"
			% [_edges.size(), build_ms])
	print("\n'mirror' is this tool's copy of the shipped search with no change at all —")
	print("if it does not match 'shipped' on ms and steps, every row below it is noise.")
	print("'steps' is the mean path length: the weighted rows pay for their speed there.")


func _row(name: String, r: Dictionary) -> void:
	print("%-14s %10.2f %10.2f %10.1f %8.1f"
			% [name, r["mean_ms"], r["worst_ms"], r["pops"], r["steps"]])


func _time(pairs: Array, fn: Callable) -> Dictionary:
	var total: float = 0.0
	var worst: float = 0.0
	var steps: float = 0.0
	var pops: float = 0.0
	for p in pairs:
		_pops = 0
		var t := Time.get_ticks_usec()
		var path: Array = fn.call(p[0], p[1])
		var ms := float(Time.get_ticks_usec() - t) / 1000.0
		total += ms
		worst = maxf(worst, ms)
		steps += float(path.size())
		pops += float(_pops)
	var n := float(pairs.size())
	return {"mean_ms": total / n, "worst_ms": worst, "steps": steps / n, "pops": pops / n}


# ----------------------------------------------------------------------------
# The variants
# ----------------------------------------------------------------------------

## One parameterised A*, so the variants differ ONLY in the axis being tested:
##   use_dir    keep the incoming direction in the state key (shipped: true)
##   cache      memoize the per-cell enter cost for this search (shipped: false)
##   weight     heuristic multiplier (shipped: 1.0)
func _astar(from: Vector2i, to: Vector2i, use_dir: bool, cache: bool,
		weight: float) -> Array:
	if not _grid.is_walkable(from) or not _grid.is_walkable(to):
		return []
	if from == to:
		return [from]

	var enter_cache: Dictionary = {}
	var start_key := Vector3i(from.x, from.y, 0)
	var g: Dictionary = {start_key: 0.0}
	var came: Dictionary = {}
	var open: Array = [[float(_h(from, to)) * weight, 0, from, -1, start_key]]
	var counter: int = 0

	while not open.is_empty():
		var cur: Array = _pop(open)
		_pops += 1
		var cell: Vector2i = cur[2]
		var dir: int = cur[3]
		var key: Vector3i = cur[4]
		if cell == to:
			return _rebuild(came, key, from)
		var cur_g: float = g[key]
		for di in _DIRS.size():
			var nb: Vector2i = cell + _DIRS[di]
			if not _grid.is_walkable(nb) or not _grid.can_transition(cell, nb):
				continue
			var turn: float = 0.0 if (not use_dir or dir == -1 or dir == di) \
					else _TURN_EPSILON
			var step: float = 1.0
			if _grid.has_traversal_edge(cell, nb):
				var ad: float = absf(_grid.altitude_center(nb) - _grid.altitude_center(cell))
				if ad > step:
					step = ad
			elif _grid.classify_step(cell, nb) == TileGrid.StepKind.SCRAMBLE:
				step = 2.0 * absf(_grid.altitude_center(nb) - _grid.altitude_center(cell))
			var enter: float = 0.0
			if cache:
				enter = enter_cache.get(nb, -1.0)
				if enter < 0.0:
					enter = _enter_cost(nb)
					enter_cache[nb] = enter
			else:
				enter = _enter_cost(nb)
			var ng: float = cur_g + step + turn + enter
			var nk := Vector3i(nb.x, nb.y, di + 1 if use_dir else 0)
			if g.has(nk) and ng >= float(g[nk]):
				continue
			g[nk] = ng
			came[nk] = [key, nb]
			counter += 1
			_push(open, [ng + float(_h(nb, to)) * weight, counter, nb, di, nk])
	return []


## cell -> flat [nb, dir_idx, cost, ...] triples. Everything the inner loop of
## A* asks about an edge, resolved once: walkability (a blocked edge is simply
## absent), the transition legality, the step cost and the destination's enter
## cost. What is left in the search is dictionary and array reads.
var _edges: Dictionary = {}


func _build_edges() -> void:
	_edges.clear()
	for cell: Vector2i in _grid.walkable_cells():
		var row: Array = []
		for di in _DIRS.size():
			var nb: Vector2i = cell + _DIRS[di]
			if not _grid.is_walkable(nb) or not _grid.can_transition(cell, nb):
				continue
			var step: float = 1.0
			if _grid.has_traversal_edge(cell, nb):
				var ad: float = absf(_grid.altitude_center(nb) - _grid.altitude_center(cell))
				if ad > step:
					step = ad
			elif _grid.classify_step(cell, nb) == TileGrid.StepKind.SCRAMBLE:
				step = 2.0 * absf(_grid.altitude_center(nb) - _grid.altitude_center(cell))
			row.append(nb)
			row.append(di)
			row.append(step + _enter_cost(nb))
		_edges[cell] = row


func _astar_tabled(from: Vector2i, to: Vector2i, use_dir: bool,
		weight: float) -> Array:
	if not _edges.has(from) or not _edges.has(to):
		return []
	if from == to:
		return [from]
	var start_key := Vector3i(from.x, from.y, 0)
	var g: Dictionary = {start_key: 0.0}
	var came: Dictionary = {}
	var open: Array = [[float(_h(from, to)) * weight, 0, from, -1, start_key]]
	var counter: int = 0
	while not open.is_empty():
		var cur: Array = _pop(open)
		_pops += 1
		var cell: Vector2i = cur[2]
		var dir: int = cur[3]
		var key: Vector3i = cur[4]
		if cell == to:
			return _rebuild(came, key, from)
		var cur_g: float = g[key]
		var row: Array = _edges[cell]
		var i: int = 0
		while i < row.size():
			var nb: Vector2i = row[i]
			var di: int = row[i + 1]
			var cost: float = row[i + 2]
			i += 3
			var turn: float = 0.0 if (not use_dir or dir == -1 or dir == di) 					else _TURN_EPSILON
			var ng: float = cur_g + cost + turn
			var nk := Vector3i(nb.x, nb.y, di + 1 if use_dir else 0)
			if g.has(nk) and ng >= float(g[nk]):
				continue
			g[nk] = ng
			came[nk] = [key, nb]
			counter += 1
			_push(open, [ng + float(_h(nb, to)) * weight, counter, nb, di, nk])
	return []


func _enter_cost(cell: Vector2i) -> float:
	# get_cell_penalty too: _cell_penalties is private to Pathfinder, and leaving
	# it out of this copy would make the copy disagree with the shipped search on
	# any map that registers one — a tool bug that reads exactly like a
	# regression.
	var out: float = float(_grid.ramp_size(cell)) * _RAMP_PENALTY_PER_STEP \
			+ _pathfinder.get_cell_penalty(cell)
	var occ: Node2D = _grid.occupant_at(cell)
	if occ != null and occ.has_method(&"walk_penalty"):
		out += float(occ.call(&"walk_penalty"))
	return out


static func _h(a: Vector2i, b: Vector2i) -> int:
	return absi(a.x - b.x) + absi(a.y - b.y)


func _rebuild(came: Dictionary, end_key: Vector3i, start: Vector2i) -> Array:
	var out: Array = []
	var k: Vector3i = end_key
	while came.has(k):
		var e: Array = came[k]
		out.append(e[1])
		k = e[0]
	out.append(start)
	out.reverse()
	return out


static func _lt(a: Array, b: Array) -> bool:
	if a[0] < b[0]:
		return true
	if a[0] > b[0]:
		return false
	return a[1] < b[1]


static func _push(heap: Array, item: Array) -> void:
	heap.append(item)
	var i: int = heap.size() - 1
	while i > 0:
		var p: int = (i - 1) >> 1
		if not _lt(heap[i], heap[p]):
			break
		var t: Array = heap[p]
		heap[p] = heap[i]
		heap[i] = t
		i = p


static func _pop(heap: Array) -> Array:
	var top: Array = heap[0]
	var last: Array = heap.pop_back()
	if heap.is_empty():
		return top
	heap[0] = last
	var i: int = 0
	var n: int = heap.size()
	while true:
		var l: int = 2 * i + 1
		var r: int = 2 * i + 2
		var s: int = i
		if l < n and _lt(heap[l], heap[s]):
			s = l
		if r < n and _lt(heap[r], heap[s]):
			s = r
		if s == i:
			break
		var t: Array = heap[i]
		heap[i] = heap[s]
		heap[s] = t
		i = s
	return top


func _settled() -> bool:
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
