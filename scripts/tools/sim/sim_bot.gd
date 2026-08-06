class_name SimBot
extends RefCounted

## The balance simulator's scripted player. Verbs: walk to fires and douse
## them (the exact economics of ActionExtinguishFire — ring order, 1 water
## per cell, atomic try_spend), buy unlocks during planning phases, and place
## ladders/frailejones during planning (see _try_place — random-valid, not
## value-scored).
##
## Movement is modeled as time, not animation: a decision computes the real
## travel seconds over the actual Pathfinder route (per-step durations via
## TileGrid.step_duration_for — the player's own table) and the bot is
## "busy" until arrival. Two-clock caveat honoured: travel is REAL seconds
## while fire/economy run on game-day time; at the sim's time_scale 1 the
## clocks coincide, which models normal (non-fast-forwarded) play.
##
## All stochastic choices (decision noise) come from the injected rng.

const WATER: StringName = &"water"
const WATER_PER_CELL: float = 1.0

## Idle back-off between fire scans when no fire is actionable — the scan
## (a reachability query + sort) must not run every 0.25 s tick.
const SCAN_COOLDOWN_SECONDS: float = 1.0

const FRAILEJON_SCENE_PATH: String = "res://scenes/tools/frailejon.tscn"

var policy: BotPolicy = null
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var pathfinder: Pathfinder = null
## Parent for planted frailejon scenes (SimWorld.object_parent).
var object_parent: Node2D = null
## The autoload; injected so this class has no compile-time autoload names.
var fire_manager: Node = null
var ledger: Node = null

## Cells this bot's ladders occupy. Real ladders register as blocking
## occupants on the grid; the sim's edge-only ladders don't, so the bot keeps
## its own set and folds it into the blocked-cells rule below.
var _ladder_cells: Dictionary = {}

var cell: Vector2i = Vector2i(-1, -1)
var busy_until: float = 0.0
## Cell the current walk ends at; douse target on arrival ((-1,-1) = idle).
var _walk_to: Vector2i = Vector2i(-1, -1)
var _douse_target: Vector2i = Vector2i(-1, -1)

# --- run stats (read by SimRunner) ---
var travel_seconds: float = 0.0
var douses: int = 0
var unlock_days: Dictionary = {}  # StringName -> int day bought
var placements: Dictionary = {}   # StringName -> int count placed


## One decision step at real-time `now`. Cheap while walking or idle.
func tick(now: float) -> void:
	if now < busy_until:
		return
	if _walk_to.x >= 0:
		_arrive()
		return
	_consider_fires(now)


func _arrive() -> void:
	cell = _walk_to
	_walk_to = Vector2i(-1, -1)
	# Douse whatever still burns around the target, nearest-first — the same
	# ring order and atomic per-cell spend as the player's action. The fire
	# may have burned out or spread during the walk; douse what's there now.
	for c: Vector2i in ActionExtinguishFire.footprint_by_ring(_douse_target):
		if not bool(fire_manager.call(&"is_burning", c)):
			continue
		if float(ledger.call(&"get_amount", WATER)) - WATER_PER_CELL \
				< policy.water_reserve:
			break
		if not bool(ledger.call(&"try_spend", WATER, WATER_PER_CELL,
				&"extinguish_fire")):
			break
		fire_manager.call(&"extinguish", c)
		douses += 1
	_douse_target = Vector2i(-1, -1)


func _consider_fires(now: float) -> void:
	# By-reference read-only view — the zero-copy poll this decision loop
	# relies on (see FireManager.burning_view).
	var burning: Dictionary = fire_manager.call(&"burning_view")
	if burning.size() < policy.min_fires_to_act:
		return
	if float(ledger.call(&"get_amount", WATER)) - WATER_PER_CELL \
			< policy.water_reserve:
		return

	# Reachability once per decision (Pathfinder caches per anchor); every
	# stand-cell test below is then a dict lookup, and exactly ONE A* runs —
	# for the stand that wins. Without this bound the bot was the sim's
	# hottest path by an order of magnitude (measured: 40 A* calls per
	# decision, every idle tick, at 100+ concurrent fires).
	var reach: Dictionary = pathfinder.reachable_from(cell)

	# Candidate fires: nearest few by Manhattan distance, or one uniform pick
	# when the noise roll fires.
	var fires: Array = burning.keys()
	var noisy: bool = policy.decision_noise > 0.0 \
			and rng.randf() < policy.decision_noise
	var candidates: Array = []
	if noisy:
		candidates = [fires[rng.randi() % fires.size()]]
	else:
		fires.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			var da: int = absi(a.x - cell.x) + absi(a.y - cell.y)
			var db: int = absi(b.x - cell.x) + absi(b.y - cell.y)
			return da < db if da != db else a < b)
		candidates = fires.slice(0, policy.candidate_fires)

	# First candidate with a reachable standing cell wins. Standing rule
	# mirrors TileAction: Chebyshev-1 from the target, walkable. Among the
	# reachable stands, walk to the one nearest the bot (Manhattan) — one A*.
	for fire_cell: Vector2i in candidates:
		var best_stand: Vector2i = Vector2i(-1, -1)
		var best_d: int = 0x7FFFFFFF
		for stand: Vector2i in ActionExtinguishFire.footprint_by_ring(fire_cell):
			if stand == fire_cell or not reach.get(stand, false):
				continue
			var d: int = absi(stand.x - cell.x) + absi(stand.y - cell.y)
			if d < best_d:
				best_d = d
				best_stand = stand
		if best_stand.x < 0:
			continue
		var path: Array[Vector2i] = pathfinder.find_path(cell, best_stand)
		if path.is_empty():
			continue
		var travel: float = _travel_seconds(path)
		travel_seconds += travel
		busy_until = now + policy.reaction_delay_seconds + travel
		_walk_to = path[path.size() - 1]
		_douse_target = fire_cell
		return

	# Nothing actionable (every candidate unreachable): don't rescan for a
	# while — fires and reachability don't change tick-to-tick.
	busy_until = now + SCAN_COOLDOWN_SECONDS


## Planning-phase actions (clock paused, like the game): buy the next
## affordable unlock(s) in priority order, then place up to
## place_per_planning items. Noise can skip a purchase.
func on_planning(unlock_state: Node, day: int) -> void:
	for type: StringName in policy.unlock_priority:
		if bool(unlock_state.call(&"is_unlocked", type)):
			continue
		if not bool(unlock_state.call(&"can_afford_unlock")):
			break
		if policy.decision_noise > 0.0 and rng.randf() < policy.decision_noise:
			continue
		if bool(unlock_state.call(&"try_unlock", type)):
			unlock_days[type] = day

	for _i in policy.place_per_planning:
		if not _try_place(unlock_state):
			break


# One placement attempt: a ladder if unlocked and a legal wall exists in the
# sample budget, else a frailejon on a free cell. v2 heuristic is random-
# valid, not value-scored (deliberate — score later if sweeps need it).
#
# Fidelity notes: a frailejon is the REAL scene — it self-registers as a
# grid occupant in _ready (walk penalty, fire char/death all flow through
# the game's own code paths). A ladder's mechanical effect IS the traversal
# edge (painted tiles are visual); its cell occupancy is tracked bot-side
# (_ladder_cells) and folded into the same blocked-cells rule the game's
# TraversalPlacementController applies.
func _try_place(unlock_state: Node) -> bool:
	var grid: TileGrid = pathfinder.grid()
	if grid == null:
		return false
	var b: Rect2i = grid.bounds()
	if b.size.x <= 0 or b.size.y <= 0:
		return false

	var ladder_ok: bool = bool(unlock_state.call(&"is_unlocked", &"ladder"))
	var frailejon_ok: bool = bool(unlock_state.call(&"is_unlocked", &"frailejon"))
	if not ladder_ok and not frailejon_ok:
		return false
	if not bool(unlock_state.call(&"can_afford_placement")):
		return false

	var blocked: Dictionary = _blocked_cells(grid)
	for _s in policy.placement_samples:
		var c := Vector2i(
				b.position.x + rng.randi() % b.size.x,
				b.position.y + rng.randi() % b.size.y)
		if not grid.is_walkable(c) or blocked.has(c):
			continue
		if ladder_ok:
			var tops: Array[Vector2i] = Ladder.find_candidates(c, grid, \
					Ladder.MAX_HEIGHT_CUBES, blocked)
			if not tops.is_empty():
				var top: Vector2i = tops[rng.randi() % tops.size()]
				if Ladder.validate(c, top, grid, blocked) == Ladder.Result.OK \
						and bool(unlock_state.call(&"try_pay_placement", &"ladder")):
					pathfinder.add_traversal_edge(c, top)
					_ladder_cells[c] = true
					_ladder_cells[top] = true
					placements[&"ladder"] = int(placements.get(&"ladder", 0)) + 1
					return true
		if frailejon_ok and grid.occupant_at(c) == null:
			if bool(unlock_state.call(&"try_pay_placement", &"frailejon")):
				_plant_frailejon(c)
				placements[&"frailejon"] = int(placements.get(&"frailejon", 0)) + 1
				return true
	return false


# The union the game's TraversalPlacementController._gather_blocked_cells
# builds (occupants of every blocking kind), plus this bot's own ladder
# cells (see _ladder_cells).
func _blocked_cells(grid: TileGrid) -> Dictionary:
	var blocked: Dictionary = _ladder_cells.duplicate()
	for kind: StringName in [&"frailejon", &"bridge_deck", &"ladder", &"rock"]:
		for c: Vector2i in grid.occupants_of_kind(kind).keys():
			blocked[c] = true
	return blocked


# Plant the real scene, in the game's own order (tile_interaction_controller:
# set cell BEFORE add_child so _ready's occupant registration reads it, then
# position). Occupancy, walk penalty, burn char and burnout death all run the
# game's frailejon code from here on.
func _plant_frailejon(c: Vector2i) -> void:
	var inst: Node2D = (load(FRAILEJON_SCENE_PATH) as PackedScene).instantiate()
	inst.set(&"cell", c)
	object_parent.add_child(inst)
	inst.global_position = pathfinder.cell_to_world(c)


func _travel_seconds(path: Array[Vector2i]) -> float:
	var total: float = 0.0
	for i in range(1, path.size()):
		var kind: int = pathfinder.classify_step(path[i - 1], path[i])
		var alt_delta: float = absf(pathfinder.altitude_center(path[i])
				- pathfinder.altitude_center(path[i - 1]))
		total += TileGrid.step_duration_for(kind, alt_delta,
				policy.step_seconds, policy.climb_mult, policy.scramble_mult)
	return total
