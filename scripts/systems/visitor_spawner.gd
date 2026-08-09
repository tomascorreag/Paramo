class_name VisitorSpawner
extends Node

# ============================================================================
# VisitorSpawner
# ============================================================================
#
# Puts bodies on the mountain for the visitors VisitorFlow already counted.
#
# ----------------------------------------------------------------------------
# Why this is not part of VisitorFlow
# ----------------------------------------------------------------------------
#
# VisitorFlow is the ECONOMY: it turns a day into an arrival count and banks the
# tokens, with no entity involved, and the balance simulator instantiates that
# script directly. Bodies are a separate concern with a separate lifetime
# (nodes, freeing, a scene), so they are a separate node.
#
# What is NOT true any more — it was, until visitors started trampling — is
# that the simulator can skip this node. A footfall costs vegetation, vegetation
# is appeal, and appeal is the next day's arrivals; a run that spawns nobody is
# modelling a different game. sim_runner constructs this exactly like the other
# systems and drives `tick`, so the sim walks the SAME visitors the player
# watches. Everything that makes that safe is here rather than there:
#   - `tick(delta)`, so a run with _process disabled still advances (and the
#     crowd updates in a defined ORDER, which matters once two visitors can
#     trample the same cell in one frame);
#   - `despawn_all` on _exit_tree, because visitors are parented to the WORLD
#     and would otherwise survive into the next run;
#   - `anchor_cell_override`, because the sim's player is a RefCounted bot that
#     cannot join the `player` group.
#
# ----------------------------------------------------------------------------
# Where they walk
# ----------------------------------------------------------------------------
#
# The project has no trailhead, road or map-edge concept, and the playable area
# is a disc rather than a rectangle, so the entry point is DERIVED: the
# southernmost cell of the landmass connected to the player's start, tie-broken
# toward the middle. That reads as the way up from the valley, and being taken
# from the player's own reachable set it cannot land on an island.
#
# Goals are sampled from that same reachable set, so a goal is reachable by
# construction instead of by check. `Visitor.nearest_reachable` still exists
# because the graph changes under a walk — the player builds a fence across a
# visitor's route — and that is the case a spawn-time check cannot cover.
#
# ----------------------------------------------------------------------------
# When they come, and in what shape
# ----------------------------------------------------------------------------
#
# Arrivals are let in in GROUPS of 1..5 sharing a pace, during opening hours
# only. Both exist because the raw signal is a COUNT for a whole day, banked by
# VisitorFlow at the midnight boundary: released one at a time on a fixed timer
# that is a metronome, and released when it arrives that is a crowd appearing at
# midnight. So the queue is held (never dropped) until opening, then paid out
# party by party.
#
# Everything about how they look and move is tunable from the Inspector; the
# groups are ordered by what they answer. Retuning any of it now MOVES THE
# BALANCE, because more visitors walking further is more ground worn away —
# re-run the simulator after changing pace, group size, opening hours or the
# concurrency cap.
#
# ============================================================================

const VISITOR_SCENE := "res://scenes/entities/visitor.tscn"
const PALETTE := "res://resources/characters/visitor_palette.tres"

## Derived stream, in the xor style every stochastic system here uses
## (ObjectPainter.OBJECT_SEED_XOR and friends), so a crowd is reproducible and
## never perturbs another system's draws.
const SEED_XOR_VISITORS: int = 0x5171705E

## The player's seconds-per-cell, mirrored rather than read: Player is a scene
## instance and reading its export would define visitors against whatever node a
## map happens to carry. This is the SHIPPED value —
## scenes/entities/player.tscn's override, NOT player.gd's 0.45 default, because
## the two disagree and it is the shipped one the player sees a visitor walking
## beside. Move this when that override moves.
const PLAYER_STEP_DURATION: float = 0.6

## Hard ceiling on the speed fraction below, so a map cannot export its way to a
## visitor that keeps up with the player — equal pace is not visibly slower, it
## is a tourist sitting on the player's heels for the whole climb.
const MAX_PACE_FRACTION: float = 0.9


@export var visitor_scene: PackedScene = preload(VISITOR_SCENE)
@export var palette: VisitorPalette = preload(PALETTE)

## Where visitors are parented. Must NOT be a node ObjectPainter sweeps: it
## frees every child in the `procedural_object` group on regenerate, so
## visitors deliberately never join that group and are cleaned up here instead.
@export var entity_parent: Node2D = null

## Ceiling on bodies at once. Arrivals beyond it wait; arrivals beyond twice it
## are dropped, because RunController's M key fires many day boundaries inside a
## single frame and an unbounded queue would spawn a crowd for a season nobody
## watched.
## (Raised with VisitorFlow.base_visitors_per_day: this gate is a CEILING on
## bodies, so leaving it behind an arrival bump converts the extra visitors into
## queue rather than into a bigger crowd.)
@export var max_concurrent: int = 8

## Seconds between GROUPS, so a day's arrivals trickle in instead of appearing
## as a clump at midnight.
@export var stagger_seconds: float = 4.0

## Seconds a visitor stands at its goal before walking back.
@export var linger_seconds: float = 6.0

## Cells between the entry and a goal, so nobody walks two steps and turns round.
@export var min_goal_distance: int = 6

## Set to override the derived entry cell (a map that wants a specific
## trailhead). Left at NO_CELL, the entry is derived — see the header.
@export var entry_cell_override: Vector2i = Pathfinder.NO_CELL

@export var enabled: bool = true

@export_group("Groups")
## Party size, drawn per group. People visit a mountain together; a stream of
## evenly spaced loners reads as spawner output rather than as tourism.
@export var group_size_min: int = 1
@export var group_size_max: int = 5

## Seconds between MEMBERS of one group. Short (they arrive together) but never
## zero: spawning a party in one frame stacks it on the entry cell.
@export var group_member_stagger_seconds: float = 0.9

@export_group("Pace")
## Walking speed as a FRACTION OF THE PLAYER'S, drawn per GROUP; its members
## then vary around that draw by group_pace_spread — walking together is most of
## what makes a party read as a party.
##
## A fraction rather than a duration because the requirement is relative ("half
## to three quarters of the player's speed") and because it makes "a visitor can
## never outpace the player" structural: the value is clamped to
## MAX_PACE_FRACTION, so no export or jitter can reach 1. Seconds per cell is
## the reciprocal — 0.5 is the SLOW end, 0.75 the quick one.
@export_range(0.1, 1.0, 0.01) var pace_fraction_min: float = 0.5
@export_range(0.1, 1.0, 0.01) var pace_fraction_max: float = 0.75

## Fraction by which each member's speed varies around its group's. Small on
## purpose — the brief is "the same, or very similar". It is also what stops a
## party that shares the opening stretch of route walking in lockstep: measured
## before any jitter existed, six visitors spawned in one frame stayed stacked on
## a single cell for the whole climb and read as one sprite with a rendering bug.
@export var group_pace_spread: float = 0.06

## Frame-hold chance at pace_fraction_min, scaled down linearly toward 0 at the
## player's own speed. The walk cycle otherwise ticks at a fixed WALK_FPS
## whatever the step takes, so a slow visitor glides — feet at a brisk cadence,
## body crawling.
##
## Deliberately WELL BELOW the value that would make the cadence physically
## match the pace (a visitor at half speed would need 0.5). A hold is a RANDOM
## repeat, so a high chance reads as the sprite stuttering rather than as a
## slower walk, and the error it corrects is subtle enough that a light touch
## covers it. Judge it in motion, not from the arithmetic.
@export_range(0.0, 0.9, 0.01) var max_frame_hold_chance: float = 0.12

@export_group("Opening hours")
## Visitors arrive only between these hours (24h clock, fractions allowed). The
## park has operating hours; a tourist wandering the paramo at 3am does not read
## as tourism. Arrivals queued outside them WAIT rather than being dropped —
## VisitorFlow banks the day's count at midnight, so without that every visitor
## would be thrown away before opening.
@export var opening_hour: float = 6.0
@export var closing_hour: float = 17.0

## At closing, send everyone still on the mountain home. Off, they finish their
## walk in the dark.
@export var send_home_at_closing: bool = true

@export_group("Wandering")
## Forwarded to each Visitor — see visitor.gd for what they do.
@export_range(0.0, 1.0, 0.05) var wander_chance: float = 0.75
@export var wander_waypoints_max: int = 2
@export var wander_radius_cells: int = 2
@export_range(0.0, 1.0, 0.01) var rest_chance_per_step: float = 0.04
@export var rest_seconds_min: float = 1.2
@export var rest_seconds_max: float = 3.5


var rng := RandomNumberGenerator.new()

## Bodies put on the mountain over this spawner's lifetime. A run statistic, and
## the cheapest proof that the gates above actually let anyone through.
var stats_spawned: int = 0

## Anchor for the DERIVED entry cell, when there is no node in the `player`
## group to read one from. The balance simulator's player is a SimBot, which is
## a RefCounted and cannot join a group, so it passes the world's spawn cell
## here — the derivation itself (southernmost reachable cell) stays shared, only
## the answer to "where does the player stand" comes from elsewhere.
var anchor_cell_override: Vector2i = Pathfinder.NO_CELL

var _pathfinder: Pathfinder = null
var _flow: Node = null
var _live: Array[Visitor] = []
var _pending: int = 0
var _cooldown: float = 0.0
var _entry: Vector2i = Pathfinder.NO_CELL
var _reach: Dictionary = {}
## Members still owed for the group being let in, and the speed fraction of the
## player's they share.
var _group_left: int = 0
var _group_pace: float = 0.0
## Edge-detects closing time; the sweep home must fire once, not every frame.
var _was_open: bool = true
## Instance id, not the TileGrid itself — a reference here would keep the whole
## previous grid alive for the sake of an identity comparison.
var _grid_stamp: int = 0


func _ready() -> void:
	rng.seed = hash(get_path()) ^ SEED_XOR_VISITORS
	_pathfinder = get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	if _pathfinder == null:
		push_error("VisitorSpawner: no Pathfinder in group '%s'." % Pathfinder.GROUP_NAME)
		set_process(false)
		return
	_pathfinder.graph_changed.connect(_on_graph_changed)

	_flow = get_tree().get_first_node_in_group(VisitorFlow.GROUP_NAME)
	if _flow == null:
		push_warning("VisitorSpawner: no VisitorFlow found; no visitors will arrive.")
	else:
		_flow.visitors_arrived.connect(request_visitors)

	if entity_parent == null:
		entity_parent = _pathfinder.get_parent() as Node2D

	# Seeded from the current clock, so booting into the small hours does not
	# read as a closing edge and sweep a crowd that was never let in.
	_was_open = is_open_now()


func _exit_tree() -> void:
	despawn_all()


## Free the whole crowd NOW, with no walk home and no fade.
##
## Visitors are parented to `entity_parent`, not to this node, so they outlive
## it — and the balance simulator builds a fresh spawner per run against a
## re-used world, where that means every run inherits the last one's tourists.
## begin_leaving() is not a substitute: it walks them off over the following
## minutes, and a sim run is one frame in which that never completes.
func despawn_all() -> void:
	for v in _live:
		if is_instance_valid(v):
			# Explicitly, and BEFORE the visitor goes: the shadow is a sibling
			# reparented into the world, and its own queued free would never land
			# in a simulator run (see GridWalker.free_shadow).
			v.free_shadow(true)
			v.free()
	_live.clear()


## Seed the stream explicitly (tools, tests, a future per-run seed). Call before
## the first arrival or the crowd already rolled stays as it was.
func set_seed(value: int) -> void:
	rng.seed = value ^ SEED_XOR_VISITORS


func live_count() -> int:
	return _live.size()


func pending_count() -> int:
	return _pending


## The derived (or overridden) entry cell, resolved on first use. NO_CELL until
## the pathfinder has a graph and the player has been placed.
func entry_cell() -> Vector2i:
	if _entry != Pathfinder.NO_CELL:
		return _entry
	if entry_cell_override != Pathfinder.NO_CELL:
		_entry = entry_cell_override
		_reach = _pathfinder.compute_reachable_set(_entry)
		return _entry

	var anchor := _player_cell()
	if anchor == Pathfinder.NO_CELL:
		return Pathfinder.NO_CELL
	# compute_reachable_set, NOT reachable_from: the latter caches exactly one
	# anchor and the hover reticle + action controller both anchor it on the
	# player, so borrowing it here would thrash their cache every query.
	var reach := _pathfinder.compute_reachable_set(anchor)
	if reach.is_empty():
		return Pathfinder.NO_CELL

	var mid_x: float = float(_pathfinder.grid().bounds().get_center().x)
	var best := Pathfinder.NO_CELL
	var best_key := Vector2(-INF, INF)
	for cell: Vector2i in reach:
		var key := Vector2(float(cell.y), -absf(float(cell.x) - mid_x))
		if key.x > best_key.x or (key.x == best_key.x and key.y > best_key.y):
			best_key = key
			best = cell
	_entry = best
	_reach = reach
	return _entry


func _player_cell() -> Vector2i:
	var cell: Vector2i = anchor_cell_override
	if cell == Pathfinder.NO_CELL:
		var player := get_tree().get_first_node_in_group(&"player")
		if player == null or not ("current_cell" in player):
			return Pathfinder.NO_CELL
		cell = player.current_cell
	return cell if _pathfinder.is_walkable(cell) else Pathfinder.NO_CELL


## Queue `count` arrivals. Wired to VisitorFlow.visitors_arrived, and public so
## tools and tests can ask for a crowd without waiting out a game day.
func request_visitors(count: int) -> void:
	if not enabled or count <= 0:
		return
	_pending = mini(_pending + count, max_concurrent * 2)


## Whether `t` (normalized time of day, TimeManager's units) is inside opening
## hours. Written to survive a window that wraps past midnight, so a map is free
## to run a night trail without this becoming a special case.
func is_open_at(t: float) -> bool:
	var open := opening_hour / 24.0
	var close := closing_hour / 24.0
	if is_equal_approx(open, close):
		return false
	if open < close:
		return t >= open and t < close
	return t >= open or t < close


func is_open_now() -> bool:
	return is_open_at(TimeManager.time_of_day)


func _process(delta: float) -> void:
	tick(delta)


## The frame body, public so the headless simulator can drive fixed-dt steps
## with _process disabled — the same shape VisitorFlow.tick and
## RegrowthManager.tick take, and for the same reason.
##
## It also drives every live visitor itself, rather than letting each one's own
## _process do it. Two reasons, and the first applies to the GAME as much as the
## sim: the crowd then updates in a defined order (this list) instead of in tree
## order, so who tramples a shared cell first is not an accident of the scene
## tree. The second is that a sim run is a single frame, in which no child's
## _process ever fires.
func tick(delta: float) -> void:
	if not enabled:
		return

	# Reverse, so a visitor that despawns mid-tick (removing itself from _live)
	# cannot make the loop skip its neighbour.
	for i in range(_live.size() - 1, -1, -1):
		var v: Visitor = _live[i]
		if is_instance_valid(v):
			v.tick(delta)

	var open := is_open_now()
	if _was_open and not open and send_home_at_closing:
		# Closing time: nobody new is let in (the `open` gate below), and everyone
		# already out WALKS to the trailhead — send_home, not begin_leaving, which
		# would stop them mid-mountain and fade them out in 0.6s. They keep their
		# slot in _live until they actually reach the entry, which costs nothing:
		# max_concurrent only gates arrivals, and there are none until morning.
		for v in _live:
			if is_instance_valid(v):
				v.send_home()
	_was_open = open

	_cooldown = maxf(_cooldown - delta, 0.0)
	if _pending <= 0:
		# A party that ran out of arrivals is over; the next batch is a new one
		# with its own size and pace, not the tail of yesterday's.
		_group_left = 0
		return
	if _cooldown > 0.0 or not open:
		return
	# Same gates VisitorFlow applies to its own accumulation: a paused clock or
	# a planning phase is not time the mountain is being visited.
	if TimeManager.paused or SeasonManager.phase != SeasonManager.Phase.ACTIVE:
		return
	if _live.size() >= max_concurrent:
		return

	if _group_left <= 0:
		_group_left = rng.randi_range(maxi(group_size_min, 1), maxi(group_size_max, 1))
		_group_pace = rng.randf_range(
				minf(pace_fraction_min, pace_fraction_max),
				maxf(pace_fraction_min, pace_fraction_max))

	if _spawn_one(_group_pace):
		_pending -= 1
		_group_left -= 1
		_cooldown = group_member_stagger_seconds if _group_left > 0 else stagger_seconds


## Speed, as a fraction of the player's, for one member of a group whose shared
## draw is `group_pace`. Clamped rather than floored on the export so a map is
## free to set whatever it likes without being able to break the rule — and the
## clamp goes AFTER the jitter, which is the only place a value inside the legal
## range can still cross the line.
func _member_pace_fraction(group_pace: float) -> float:
	var jittered: float = group_pace * rng.randf_range(
			1.0 - group_pace_spread, 1.0 + group_pace_spread)
	return clampf(jittered, 0.01, MAX_PACE_FRACTION)


## Seconds per cell for a visitor walking at `fraction` of the player's speed.
## Speed is the RECIPROCAL of seconds-per-cell, so this divides.
func _member_step_duration(fraction: float) -> float:
	return PLAYER_STEP_DURATION / maxf(fraction, 0.01)


## Frame holds scale with how far below the player this visitor walks: none at
## the player's own speed, max_frame_hold_chance at pace_fraction_min. Taken
## from the SPEED fraction, not the duration, so the ramp stays linear in the
## quantity the pace is authored in.
func _frame_hold_for_fraction(fraction: float) -> float:
	var span: float = maxf(1.0 - minf(pace_fraction_min, pace_fraction_max), 0.001)
	var slowness: float = clampf((1.0 - fraction) / span, 0.0, 1.0)
	return slowness * max_frame_hold_chance


func _spawn_one(group_pace: float) -> bool:
	var entry := entry_cell()
	if entry == Pathfinder.NO_CELL or entity_parent == null:
		return false
	var goal := _pick_goal(entry)
	if goal == Pathfinder.NO_CELL:
		return false

	var v: Visitor = visitor_scene.instantiate()
	v.entry_cell = entry
	v.goal_cell = goal
	v.reach = _reach
	v.linger_seconds = linger_seconds
	var fraction: float = _member_pace_fraction(group_pace)
	v.step_duration = _member_step_duration(fraction)
	v.frame_hold_chance = _frame_hold_for_fraction(fraction)
	v.wander_chance = wander_chance
	v.wander_waypoints_max = wander_waypoints_max
	v.wander_radius_cells = wander_radius_cells
	v.rest_chance_per_step = rest_chance_per_step
	v.rest_seconds_min = rest_seconds_min
	v.rest_seconds_max = rest_seconds_max
	# Its own stream, derived from this one, so a visitor's route noise and
	# breathers cannot change what the NEXT visitor looks like — the draws would
	# otherwise interleave with the spawner's own and depend on frame timing.
	var stream := RandomNumberGenerator.new()
	stream.seed = rng.randi()
	v.rng = stream
	v.sheet = VisitorAppearance.roll_sheet(rng)
	v.colors = VisitorAppearance.roll_colors(palette, rng)
	v.despawned.connect(_on_visitor_despawned)
	# This node drives the crowd (see `tick`), so a visitor must not also drive
	# itself — it would advance twice per frame and walk at double pace.
	v.set_process(false)
	# Parent BEFORE anything reads a world transform — same ordering
	# ObjectPainter relies on; Visitor._ready does its own placement.
	entity_parent.add_child(v)
	_live.append(v)
	stats_spawned += 1
	return true


## Uniform over the entry's reachable set, rejecting cells too close to the
## entry. Rejection sampling rather than filtering the whole set: the set is
## thousands of cells and all but a small disc around the entry qualify, so a
## handful of draws beats building a filtered copy per spawn.
func _pick_goal(entry: Vector2i) -> Vector2i:
	if _reach.is_empty():
		return Pathfinder.NO_CELL
	var cells: Array = _reach.keys()
	var min_d2: int = min_goal_distance * min_goal_distance
	for _attempt in 24:
		var cell: Vector2i = cells[rng.randi_range(0, cells.size() - 1)]
		if Visitor.dist2(cell, entry) < min_d2:
			continue
		if not _pathfinder.is_walkable(cell):
			continue
		return cell
	return Pathfinder.NO_CELL


func _on_visitor_despawned(v: Visitor) -> void:
	_live.erase(v)


# The graph changed. A fresh TileGrid instance means the world was REBUILT
# (ProceduralWorld regenerating), not merely edited — the old cells are gone, so
# the derived entry and every walker on it are stale and the crowd is sent home.
# An edit in place (a fence going up) only needs the reachable set refreshed;
# each Visitor re-paths off the same signal.
func _on_graph_changed() -> void:
	if _pathfinder == null:
		return
	var grid := _pathfinder.grid()
	var stamp: int = grid.get_instance_id() if grid != null else 0
	var rebuilt: bool = stamp != _grid_stamp
	_grid_stamp = stamp

	if rebuilt:
		_entry = Pathfinder.NO_CELL
		_reach = {}
		_pending = 0
		_group_left = 0
		for v in _live:
			if is_instance_valid(v):
				v.begin_leaving()
		return

	if _entry != Pathfinder.NO_CELL:
		_reach = _pathfinder.compute_reachable_set(_entry)
	for v in _live:
		if is_instance_valid(v):
			v.reach = _reach
