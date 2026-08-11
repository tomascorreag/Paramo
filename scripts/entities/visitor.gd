class_name Visitor
extends GridWalker

# ============================================================================
# Visitor
# ============================================================================
#
# One eco-tourist, on screen: walks in from the trailhead, out to somewhere on
# the mountain, stands there a while, walks back, and leaves.
#
# The economics are NOT here — VisitorFlow computes the day's arrivals and banks
# the tokens with no entity involved, and it stays that way. What a visitor
# costs is the GROUND: every step it takes wears the grass a little
# (_on_step_started -> RegrowthManager.trample), and worn grass is lower appeal,
# which is fewer arrivals tomorrow. So a body is no longer free — the balance
# simulator walks these same nodes, and spawning none would model a different
# game. Where a visitor WALKS is a balance input; how it is coloured is not.
#
# Appearance comes from the indexed sheet + visitor_recolor.gdshader (see
# scripts/data/visitor_slots.gd). The spawner rolls the colours from its own
# seeded stream and hands them over before add_child.
#
# ----------------------------------------------------------------------------
# Spawn contract
# ----------------------------------------------------------------------------
#
# Set entry_cell / goal_cell / colors / reach / rng BEFORE add_child — _ready
# places and dispatches. `reach` is the spawner's cached reachable set (shared
# by reference, never mutated here); the spawner replaces it on graph changes.
# `rng` (declared on GridWalker) is the ONE stream this visitor draws from —
# route noise, breathers and frame holds all come off it, so a crowd is
# reproducible from the spawner's seed alone.
#
# ----------------------------------------------------------------------------
# Why the route is noisy
# ----------------------------------------------------------------------------
#
# Two visitors handed the same entry and goal get the same route back, so a
# group walks it in single file. Note WHY, because it is not what this comment
# used to say: the route is not geometrically unique, it is unique because
# Pathfinder's A* breaks ties deterministically (a FIFO counter on equal f).
# MEASURED on level1 terrain, 39 routes / 1051 steps: 24% of steps have a
# neighbour of EQUAL cost, mean branching factor 1.24 — so the shortest-path
# corridor is a few cells wide and a randomised tie-break would spread walkers
# across it for free. See the note in CLAUDE.md; that is the cheap half of what
# this feature does, and the waypoints below are the half that cannot come from
# tie-breaking (a detour OFF the corridor, to somewhere worth looking at). The
# noise is added as detour WAYPOINTS rather than as jitter on the path, so every
# step remains a real find_path result and no visitor can wander through a fence
# or across a gap. See _wandering_path.
#
# The noise is drawn at TWO scales, because a party and a stranger are different
# questions:
#   - PARTY scale: the spawner draws one set of waypoints per group
#     (`route_anchors`, via draw_route_anchors) off the straight entry->goal
#     line, at wander_radius_cells. That is what makes one party's trail differ
#     from another's — and it is drawn ONCE, so the members of a group cost one
#     route draw between them instead of one each.
#   - MEMBER scale: each visitor re-scatters around its party's waypoints at the
#     much smaller member_wander_radius_cells. Members converge at each shared
#     waypoint and drift apart between them, which is a party walking together
#     rather than a column on one line.
# With no anchors assigned (a bare Visitor in a test, or a goal relocated
# mid-walk) the visitor draws its own party-scale set and behaves as before.
#
# ----------------------------------------------------------------------------
# Why waypoints are also STOPS
# ----------------------------------------------------------------------------
#
# A visitor always stands a moment on each of its waypoints (waypoint_pause_*).
# It reads as the reason the detour existed — someone walked over there to look
# at something — where silently rounding a corner reads as bad pathfinding.
#
# It is also load-bearing for SEPARATION, and that is the part to keep in mind
# before retuning it. A party's members now share a pace to within
# group_pace_spread (small on purpose: they walk together) and near-identical
# routes, so pace alone no longer pulls them apart the way it did when routes
# were independent. What desynchronises them is that each stops at its OWN
# scattered waypoint for its OWN rolled duration. Set the pause to zero and a
# party collapses back into one stack of sprites.
#
# BOTH ShaderMaterials in visitor.tscn are resource_local_to_scene. A .tscn's
# sub-resources are shared across instances otherwise, and both of these carry
# PER-VISITOR state: the recolour's slot_colors (the whole crowd would take the
# last one rolled) and the shadow's visual_y_offset (every shadow would sit at
# the last visitor's altitude). The player never needed this because there is
# only ever one of it.
#
# ============================================================================

signal despawned(visitor: Visitor)

enum State { TO_GOAL, LINGER, TO_EXIT, LEAVING }

# Barrier keys for the walk home live above any outbound key, so the two legs
# cannot share a latched release. Far above wander_waypoints_max, which is a
# handful.
const _RETURN_LEG_INDEX_BASE: int = 1000

## Whoever set this drives `tick` themselves, so this visitor must not also run
## its own _process. VisitorSpawner sets it on every visitor it spawns (see the
## ordering note in _ready); a visitor built by hand in a test or a tool is
## self-driving by default.
var driven_externally: bool = false

## Seconds spent standing at the goal before heading back.
@export var linger_seconds: float = 6.0

## Fade in on arrival and out on departure. Visitors appear at a fixed cell, so
## without this they pop in and out at the same spot every time. The recolour
## shader multiplies by the node's modulate for exactly this.
@export var fade_seconds: float = 0.6

@export_group("Wandering")
## Chance that a leg is routed through detour waypoints at all. At 0 every
## visitor walks the pathfinder's optimal line, and a group sharing an entry and
## a goal walks it single-file — the shortest path is unique, so identical
## endpoints give identical routes.
@export_range(0.0, 1.0, 0.05) var wander_chance: float = 0.75
## Upper bound on detour waypoints per leg. Each one is a separate find_path, so
## this is also the per-leg pathfinding cost multiplier.
@export var wander_waypoints_max: int = 2
## How far off the straight line a waypoint may sit, in cells. Too large and the
## visitor visibly doubles back; too small and the detour is invisible.
## (Was 5, which at a 5-cell scatter routed people around whole hillsides and
## read as them not knowing where they were going.)
##
## This is the PARTY-scale radius — it separates one group's trail from the next
## group's. Within a group see member_wander_radius_cells.
@export var wander_radius_cells: int = 2

## How far a single member strays from its PARTY's shared waypoint, in cells.
## Deliberately much smaller than wander_radius_cells: at 0 the whole party walks
## one line, and at wander_radius_cells the group draw stops meaning anything
## because members scatter as far as parties do. 1 gives a couple of cells of
## width to a trail that is still recognisably one trail.
@export var member_wander_radius_cells: int = 1

## Seconds a visitor stands on each waypoint it reaches. Always — this is not a
## roll (that is rest_chance_per_step, below). See the header on why the stop is
## also what keeps a party's members from stacking.
@export var waypoint_pause_min: float = 1.5
@export var waypoint_pause_max: float = 4.0

## Longest a member will hold a waypoint waiting for the rest of its party
## (VisitorParty). This is the guarantee that a regroup can never deadlock: it
## applies whatever the party thinks, so a drop-out route nobody anticipated
## still resolves. Generous, because expiring it early defeats the regroup — it
## is a safety net, not a tuning knob for how long people wait.
@export var regroup_timeout_seconds: float = 20.0

## After a party regroups, each member waits a further 0..this before setting
## off. Without it the whole party leaves on one frame at near-identical pace
## along near-identical routes, which is exactly the stack the regroup was
## supposed to look better than.
@export var regroup_release_spread: float = 1.2

@export_group("Breathers")
## Chance, rolled when each step BEGINS, that the visitor stands still once that
## step lands. Per step rather than on a timer so a slow walker (fewer steps per
## minute) does not also stop more often than a fast one.
@export_range(0.0, 1.0, 0.01) var rest_chance_per_step: float = 0.04
@export var rest_seconds_min: float = 1.2
@export var rest_seconds_max: float = 3.5

var entry_cell: Vector2i = Vector2i.ZERO
var goal_cell: Vector2i = Vector2i.ZERO
## The party's shared detour waypoints for the OUTBOUND leg, entry -> goal, in
## order. Assign via set_group_route before add_child; the return leg walks them
## reversed. Shared BY REFERENCE across a group, so nothing here may mutate it.
var route_anchors: Array[Vector2i] = []
## Which indexed sheet this person is built from. Null keeps the scene's own.
var sheet: Texture2D = null
var colors: PackedColorArray = PackedColorArray()
var reach: Dictionary = {}

var _state: int = State.TO_GOAL
var _linger_left: float = 0.0
var _fade: float = 0.0
var _regrowth: Node = null
# Distinguishes "the spawner gave this party no detours" from "nobody assigned a
# route", which an empty route_anchors cannot: the first must NOT be re-rolled
# per member (the party agreed to walk straight), the second must self-draw.
var _has_group_route: bool = false
# Cells of the CURRENT path the visitor should stand on when it gets there,
# mapped to their index along the route (which is what a regroup barrier is
# keyed on). Entries are erased as they are consumed, so a path that crosses one
# waypoint twice still only stops once.
var _waypoints: Dictionary[Vector2i, int] = {}
# The party this visitor regroups with, and which barrier it is currently held
# at (-1 = walking). Null party = nobody to wait for; the stops still happen.
var _party: VisitorParty = null
var _regroup_index: int = -1
var _regroup_left: float = 0.0
# This member's OWN cell near the party's shared goal. The party shares one
# goal_cell, so without a per-member standing cell every member of a party would
# linger on one tile — the most visible way two characters end up stacked.
var _goal_stand: Vector2i = Pathfinder.NO_CELL
# Set by the graph_changed handler, consumed at the top of tick(). A fence RUN
# emits one signal PER TILE laid, all inside one frame, and re-pathing on each
# would mean this visitor rebuilding its whole route twenty times to answer the
# same question once.
var _graph_dirty: bool = false

# get_node_or_null, not $: a visitor is normally instanced from visitor.tscn,
# but nothing here NEEDS a body — GridWalker walks fine without one — and a
# bare `Visitor.new()` is the cheapest way for a test to exercise the state
# machine.
@onready var _visitor_sprite: Sprite2D = get_node_or_null(^"Sprite2D")
@onready var _visitor_shadow: Sprite2D = get_node_or_null(^"Shadow")


func _process(delta: float) -> void:
	tick(delta)


func _ready() -> void:
	# Set BEFORE anything else and from _ready, not by the owner: entering the
	# tree RE-ENABLES processing on a node whose script declares _process, so an
	# owner calling set_process(false) before add_child has that silently undone
	# and the visitor then ticks TWICE a frame — once here, once from the driver
	# — walking at double pace. Measured: visitors covered a cell in 0.73 s
	# against an authored 0.99, i.e. faster than the player they are supposed to
	# trail. _ready runs inside add_child, after the re-enable, so this sticks
	# wherever the owner sets the flag, and it survives a reparent.
	set_process(not driven_externally)

	var pf := get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	if pf == null:
		push_error("Visitor: no Pathfinder in group '%s'." % Pathfinder.GROUP_NAME)
		queue_free()
		return

	# Build first, then colours: both are per-instance and the sheet swap must
	# not disturb hframes/offset, which stay authored on the node.
	if sheet != null:
		_visitor_sprite.texture = sheet
	if not colors.is_empty():
		VisitorAppearance.apply(_visitor_sprite.material as ShaderMaterial, colors)

	bind(pf, _visitor_sprite, _visitor_shadow)
	place_at(entry_cell)
	modulate.a = 0.0
	_fade = 0.0

	pf.graph_changed.connect(_on_graph_changed)

	_state = State.TO_GOAL
	if not _walk_to(goal_cell):
		# Nowhere to go (goal is the entry, or already unreachable at spawn):
		# stand a moment so the arrival still reads, then leave.
		_begin_linger()


func _exit_tree() -> void:
	free_shadow()
	# Both are global-ish state this visitor is holding. VisitorStanding sweeps
	# dead claimants lazily anyway, but a party waiting on a member that is being
	# freed would otherwise hold its barrier until every waiter timed out.
	VisitorStanding.release_all_for(self)
	_drop_out_of_party()


## The frame body. Public and separate from _process because VisitorSpawner
## drives its whole crowd itself (see its `tick`) — in the game as well as in
## the balance simulator, so there is one update path and one order rather than
## a headless special case.
func tick(delta: float) -> void:
	# BEFORE the movement tick, so a route invalidated by this frame's graph
	# change is repaired before the walker tries to step into the new wall — and
	# specifically before GridWalker drops the path itself, which this state
	# machine would read as an arrival.
	if _graph_dirty:
		_graph_dirty = false
		_revalidate_route()
	# BEFORE the movement tick, so a member held at a barrier re-arms its pause
	# in the same frame the walker consults it.
	_tick_regroup(delta)
	tick_movement(delta)

	# Fade tracks the direction of travel through the lifecycle, so an early
	# despawn (regenerate, cut-off) still fades rather than blinking out.
	var target: float = 0.0 if _state == State.LEAVING else 1.0
	var faded := move_toward(_fade, target, delta / maxf(fade_seconds, 0.001))
	# Assigning modulate dirties the canvas item, so skip it once the fade has
	# settled — which is all but the first and last second of a visitor's life.
	# The balance simulator walks a crowd for ~23k ticks a run and paid for every
	# one of those writes.
	if faded != _fade:
		_fade = faded
		modulate.a = _fade
		if _visitor_shadow != null and is_instance_valid(_visitor_shadow):
			_visitor_shadow.modulate.a = _fade

	if _state == State.LEAVING and _fade <= 0.0:
		_despawn()
		return

	if _state == State.LINGER:
		_linger_left -= delta
		if _linger_left <= 0.0:
			_state = State.TO_EXIT
			if not _walk_to(entry_cell):
				begin_leaving()


## Cut the visit short and WALK to the entry cell. The closing-hours sweep.
##
## Deliberately not begin_leaving: the two answer different questions. This one
## is a person deciding to go home, so it has to be real walking — the park
## empties over the next few minutes and the trailhead sees the traffic (and the
## trampling) of everybody leaving. begin_leaving is the terminal fade, for the
## cases where walking is impossible: a regenerated world whose cells are gone,
## or a visitor walled in with no route. Falls back to it when there is no path,
## and when the visitor is already standing on the entry (_walk_to rejects a
## zero-length route) — which is exactly where a fade-out belongs anyway.
func send_home() -> void:
	if _state == State.LEAVING or _state == State.TO_EXIT:
		return
	_state = State.TO_EXIT
	if not _walk_to(entry_cell):
		begin_leaving()


## Stop where it stands, fade out and free. For a world that no longer holds the
## cells this visitor was walking on; see send_home for the ordinary departure.
func begin_leaving() -> void:
	if _state == State.LEAVING:
		return
	_state = State.LEAVING
	# It will never reach another waypoint, so it must stop being counted, and
	# the ground it had spoken for goes back.
	_drop_out_of_party()
	VisitorStanding.release_all_for(self)
	stop()


func _despawn() -> void:
	despawned.emit(self)
	queue_free()


func _on_arrived() -> void:
	match _state:
		State.TO_GOAL:
			_begin_linger()
		State.TO_EXIT:
			begin_leaving()


func _begin_linger() -> void:
	_state = State.LINGER
	_linger_left = linger_seconds


## The graph changed under a walk — the player built a fence, or a bridge
## opened a route. Only flagged here: see _revalidate_route for why the work is
## deferred to the next tick.
func _on_graph_changed() -> void:
	_graph_dirty = true


## Repair the route if — and only if — this graph change actually broke it.
##
## The overwhelmingly common case is that it did not: the player fenced a cell
## on the far side of the mountain and every visitor's queued path is still
## legal. Re-pathing regardless cost several A* runs per visitor per signal, and
## it was not merely wasted work — it re-rolled the route noise, released and
## re-reserved every standing cell, and could drop the visitor out of its party,
## so a distant fence visibly reshuffled a crowd that should have ignored it.
##
## A LINGERING visitor is skipped outright: it is standing still, so no queued
## step can be invalidated, and it re-paths from scratch when the linger ends.
## (Before this it re-pathed toward the ENTRY while still in LINGER, which
## started the walk home early on any unrelated graph change.)
func _revalidate_route() -> void:
	if _state == State.LEAVING or _state == State.LINGER:
		return
	if path_is_valid() and is_moving():
		return

	# The spawner recomputes `reach` on the same signal; ordering between the
	# two handlers is not guaranteed, so re-path against the pathfinder itself
	# and only consult `reach` to relocate an unreachable goal.
	var target: Vector2i = goal_cell if _state == State.TO_GOAL else entry_cell
	if _walk_to(target):
		return
	if _state == State.TO_GOAL:
		var alt := nearest_reachable(reach, target, current_cell, _pathfinder)
		if alt != Pathfinder.NO_CELL and _walk_to(alt):
			goal_cell = alt
			return
		# Cut off from anywhere worth going: turn round now.
		_state = State.TO_EXIT
		if _walk_to(entry_cell):
			return
	# Walled in with no way home. Fade out where it stands rather than freeze
	# mid-stride or walk through the new wall.
	begin_leaving()


## Closest cell to `target` that is BOTH in `reach` and actually walkable from
## `from` right now. `reach` narrows the search to the connected landmass (it is
## the spawner's cached set — cheap to scan, no path per candidate); find_path
## does the expensive confirmation once, on the winner.
##
## Only the CANDIDATES nearest the target are considered, and that bound is the
## point. The reachable set is thousands of cells; the old implementation
## sort_custom'd all of them through a GDScript lambda — tens of thousands of
## script-level comparator calls — and then, in the case that matters (a visitor
## walled off from everywhere), ran an A* against every one of them in turn
## before giving up. This makes one linear pass keeping the nearest
## _NEAREST_CANDIDATES, then confirms them in order. The set is a connected
## component, so all but a handful of its members are walkable and the first
## candidate almost always wins; a genuinely cut-off visitor now gives up in
## bounded time and fades out, which is what it did at the end of the long scan
## anyway.
const _NEAREST_CANDIDATES: int = 12

static func nearest_reachable(reach_set: Dictionary, target: Vector2i,
		from: Vector2i, pathfinder: Pathfinder) -> Vector2i:
	if pathfinder == null:
		return Pathfinder.NO_CELL
	# Parallel arrays kept sorted by distance, at most _NEAREST_CANDIDATES long.
	var best: Array[Vector2i] = []
	var best_d: PackedInt32Array = PackedInt32Array()
	for cell: Vector2i in reach_set:
		if cell == from:
			continue
		var d := dist2(cell, target)
		var n := best.size()
		if n >= _NEAREST_CANDIDATES and d >= best_d[n - 1]:
			continue
		var at: int = n
		while at > 0 and best_d[at - 1] > d:
			at -= 1
		best.insert(at, cell)
		best_d.insert(at, d)
		if best.size() > _NEAREST_CANDIDATES:
			best.resize(_NEAREST_CANDIDATES)
			best_d.resize(_NEAREST_CANDIDATES)
	for cell: Vector2i in best:
		if not pathfinder.is_walkable(cell):
			continue
		if pathfinder.find_path(from, cell).size() >= 2:
			return cell
	return Pathfinder.NO_CELL


static func dist2(a: Vector2i, b: Vector2i) -> int:
	var d := a - b
	return d.x * d.x + d.y * d.y


## Route toward the party-level target `cell` (the shared goal, the entry, or a
## relocated goal), usually via a couple of detour waypoints — see the "noise"
## note in the header. Falls back to the direct path whenever the detour cannot
## be built: a wandering visitor that fails to route is worse than a tidy one.
##
## `cell` is where the PARTY is headed; where THIS member ends up is resolved
## here, because the goal is shared and a party lingering on one tile is the most
## visible way two characters stack.
func _walk_to(cell: Vector2i) -> bool:
	if _pathfinder == null:
		return false
	# Cleared up front, not in the failure branches: _wandering_path can abandon a
	# route half-built (a leg that no longer connects), and a stale waypoint left
	# behind would stop the visitor on a cell the new path merely passes through.
	_waypoints.clear()
	_leave_regroup()
	# The cells this visitor had spoken for are not where it is going any more.
	# Released BEFORE the new reservations so a re-route can re-take its own
	# spots rather than being crowded out by itself.
	VisitorStanding.release_all_for(self)

	var dest: Vector2i = cell
	if cell == goal_cell:
		# Its own patch of ground near the party's goal. The way HOME is not
		# reserved: everyone converges on the entry cell and fades, and a
		# reservation there would only push the last arrivals off the trailhead.
		_goal_stand = _reserve_near(goal_cell)
		dest = _goal_stand
	if dest == current_cell:
		return false

	var path := _wandering_path(cell, dest)
	if path.is_empty():
		# Not walking the party's line any more, so it must stop being counted:
		# a member that never reaches a waypoint would otherwise hold every
		# barrier open until each waiting member's own timeout expired.
		_drop_out_of_party()
		path = _direct_path(dest)
	if path.is_empty():
		return false
	follow_path(path)
	return true


## A reserved standing cell near `anchor`, falling back to the anchor itself
## when the neighbourhood is full — overlapping beats not walking.
func _reserve_near(anchor: Vector2i) -> Vector2i:
	var cell := VisitorStanding.reserve_near(anchor, member_wander_radius_cells,
			_pathfinder, _rng(), self)
	return anchor if cell == Pathfinder.NO_CELL else cell


## find_path includes the start cell; follow_path takes NEXT destinations only.
func _direct_path(cell: Vector2i) -> Array[Vector2i]:
	var path := _pathfinder.find_path(current_cell, cell)
	if path.size() < 2:
		return [] as Array[Vector2i]
	path.remove_at(0)
	return path


## Hold this visitor at its waypoint until the rest of the party reaches the
## same one. Implemented by RE-ARMING the ordinary pause every frame rather than
## by touching the path: GridWalker only steps when its pause has run out, so a
## pause kept topped up is a hold, and it inherits the step-boundary guarantee
## for free (nobody freezes mid-stride).
##
## The timeout is the reason a regroup cannot deadlock, and it is checked here —
## on the WAITING member — rather than in VisitorParty, so it holds even for a
## drop-out path the party never learned about.
func _tick_regroup(delta: float) -> void:
	if _regroup_index < 0:
		return
	_regroup_left -= delta
	var released: bool = _party == null or _party.is_released(_regroup_index)
	if released or _regroup_left <= 0.0:
		_regroup_index = -1
		# Leave one at a time. Without this the party departs on a single frame
		# at near-identical pace along near-identical routes, which is the stack
		# the regroup was supposed to look better than.
		pause_movement(_rng().randf_range(0.0, maxf(regroup_release_spread, 0.0)))
		return
	# Top up rather than set: whatever remains of the visible dwell is longer
	# early on, and pause_movement keeps the longer of the two.
	pause_movement(delta * 2.0)


## Stop waiting, without departing tidily — used when the route is being rebuilt
## under this visitor.
func _leave_regroup() -> void:
	_regroup_index = -1
	_regroup_left = 0.0


## Stop being counted by the party's barriers. Idempotent: a visitor that has
## already dropped out has no party to tell.
func _drop_out_of_party() -> void:
	if _party == null:
		return
	_party.member_left()
	_party = null
	_leave_regroup()


## Join `party`, whose barriers this visitor will wait at. Call before add_child,
## alongside set_group_route.
func set_party(party: VisitorParty) -> void:
	_party = party
	if party != null:
		party.member_joined()


## Hand this visitor its party's shared waypoints. `anchors` is kept BY
## REFERENCE and never mutated here, so one array serves the whole group; an
## empty array is a valid answer meaning "this party walks straight", which is
## why the flag exists separately. Call before add_child.
func set_group_route(anchors: Array[Vector2i]) -> void:
	route_anchors = anchors
	_has_group_route = true


# The party's waypoints for the leg about to be walked. Outbound is the shared
# array as drawn; the way home is the same trail read backwards, which is what a
# party that came up one way does. Anything else — a goal relocated by
# nearest_reachable after a fence went up — has no shared line to follow, so the
# visitor draws its own.
func _anchors_for(target: Vector2i, dest: Vector2i) -> Array[Vector2i]:
	if _has_group_route:
		if target == goal_cell:
			return route_anchors
		if target == entry_cell:
			# duplicate() first: reversing in place would flip the array the rest
			# of the party is still walking forwards along.
			var back := route_anchors.duplicate()
			back.reverse()
			return back
	return draw_route_anchors(current_cell, dest, wander_chance,
			wander_waypoints_max, wander_radius_cells, _pathfinder, _rng())


# The party's waypoints, each nudged a cell or so for THIS member, then re-joined
# by the pathfinder. Perturbing WAYPOINTS rather than the path itself keeps every
# step legal by construction: each leg is still a real find_path result, so no
# wandering visitor can walk through a fence or off a cliff, and terrain still
# shapes the route between the detours.
func _wandering_path(target: Vector2i, dest: Vector2i) -> Array[Vector2i]:
	# Only a route built from the PARTY's anchors can be regrouped on: barrier
	# index i has to mean the same place to every member. A member routing
	# somewhere of its own — a goal relocated by nearest_reachable after the
	# player fenced the route — is no longer on the shared line, so it leaves the
	# party rather than holding barriers its mates will never reach.
	var shared: bool = _has_group_route and (target == goal_cell or target == entry_cell)
	if not shared:
		_drop_out_of_party()
	# The way home walks the same anchors reversed, so without a separate index
	# space its barriers would collide with the outbound ones — which latch when
	# released, so every return barrier would open on arrival.
	var index_base: int = _RETURN_LEG_INDEX_BASE if target == entry_cell else 0

	var anchors := _anchors_for(target, dest)
	if anchors.is_empty():
		return [] as Array[Vector2i]

	var stops: Array[Vector2i] = []
	for anchor: Vector2i in anchors:
		# RESERVE rather than merely scatter: this is both the per-member spread
		# around the party's waypoint AND the guarantee that no two visitors
		# stand on one tile. A failed reservation falls back to the party's own
		# anchor rather than dropping the stop — the anchor is walkable by
		# construction, and dropping it would put this member on a shorter route
		# than the rest of the party. Overlapping is the lesser fault.
		var cell := VisitorStanding.reserve_near(anchor, member_wander_radius_cells,
				_pathfinder, _rng(), self)
		stops.append(anchor if cell == Pathfinder.NO_CELL else cell)
	stops.append(dest)

	var out: Array[Vector2i] = []
	var pending: Dictionary[Vector2i, int] = {}
	var from := current_cell
	for i in stops.size():
		var stop: Vector2i = stops[i]
		if stop == from:
			continue
		var leg := _pathfinder.find_path(from, stop)
		if leg.size() < 2:
			return [] as Array[Vector2i]
		leg.remove_at(0)
		out.append_array(leg)
		from = stop
		# The last stop IS the target — the goal has its own linger and the entry
		# ends the visit, so neither is a waypoint to pause on. `i` is also the
		# barrier key: every member of a party walks the same number of
		# waypoints in the same order, so index i means the same place to all of
		# them even though each stands on its own cell.
		if i < stops.size() - 1:
			pending[stop] = index_base + i
	_waypoints = pending
	return out


## Detour waypoints along the straight line `from` -> `to`: the line cut at even
## fractions, each cut nudged somewhere walkable nearby. Static because the
## SPAWNER draws these once per party (see the header) and a Visitor draws its
## own only as a fallback — both need the same line, and neither should own it.
## Returns empty when this route rolls no detour at all.
static func draw_route_anchors(from: Vector2i, to: Vector2i, chance: float,
		waypoints_max: int, radius: int, pathfinder: Pathfinder,
		stream: RandomNumberGenerator) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if pathfinder == null or chance <= 0.0 or waypoints_max <= 0:
		return out
	if stream.randf() >= chance:
		return out
	var count: int = stream.randi_range(1, waypoints_max)
	for i in count:
		var t: float = float(i + 1) / float(count + 1)
		var on_line := Vector2(from).lerp(Vector2(to), t)
		var cell := scatter_near(Vector2i(on_line.round()), radius, pathfinder, stream)
		if cell != Pathfinder.NO_CELL:
			out.append(cell)
	return out


# A walkable cell within `radius` of `around`. Sampled rather than searched: the
# radius is small and most of a landmass is walkable, so a handful of draws beats
# scanning the disc, and giving up costs only a straighter route.
static func scatter_near(around: Vector2i, radius: int, pathfinder: Pathfinder,
		stream: RandomNumberGenerator) -> Vector2i:
	if radius <= 0:
		return around if pathfinder.is_walkable(around) else Pathfinder.NO_CELL
	for _attempt in 8:
		var offset := Vector2i(
				stream.randi_range(-radius, radius),
				stream.randi_range(-radius, radius))
		var cell := around + offset
		if pathfinder.is_walkable(cell):
			return cell
	return Pathfinder.NO_CELL


# Breathers are rolled at step START so the pause lands when that step does —
# GridWalker holds it to the boundary either way, but rolling here means the
# odds are per cell walked, which is what makes them independent of pace.
func _on_step_started(cell: Vector2i, _kind: int) -> void:
	_trample(cell)
	# A waypoint is an unconditional stop, so it takes precedence over the
	# breather roll — the two would only stack into one longer pause anyway
	# (pause_movement keeps the longer wait). Erasing as it fires makes the stop
	# one-shot: a route that crosses its own waypoint on the way back does not
	# stop there twice.
	if _waypoints.has(cell):
		var index: int = _waypoints[cell]
		_waypoints.erase(cell)
		pause_movement(_rng().randf_range(waypoint_pause_min, waypoint_pause_max))
		# The pause above is the visible dwell; the barrier below may extend it.
		# pause_movement takes the LONGER wait, so the two compose without either
		# needing to know about the other.
		#
		# Arrival is registered at step START, so it runs up to one step early.
		# That is deliberate and harmless: every member reports on the same
		# footing, the pause holds each at its own step boundary anyway, and the
		# alternative (a hook on step completion) would exist only to make the
		# barrier open one step later than it does now.
		if _party != null:
			_party.arrive(index)
			if not _party.is_released(index):
				_regroup_index = index
				_regroup_left = regroup_timeout_seconds
		return
	# No LEAVING guard is needed: begin_leaving() clears the path, so a departing
	# visitor takes no further steps to roll against.
	if rest_chance_per_step <= 0.0:
		return
	if _rng().randf() < rest_chance_per_step:
		pause_movement(_rng().randf_range(rest_seconds_min, rest_seconds_max))


# Feet wear the grass down. Reported per STEP rather than integrated over time,
# so a visitor that stops for breath stops doing damage — the cost is the
# traffic, not the loitering. RegrowthManager decides what (if anything) a given
# cell loses; a visitor knows nothing about vegetation.
func _trample(cell: Vector2i) -> void:
	if _regrowth == null or not is_instance_valid(_regrowth):
		# Lazy group lookup, the same pattern VisitorFlow uses to find this node.
		# Cached per visitor, so it is one lookup per person, not per step.
		#
		# The group name is a LITERAL, not RegrowthManager.GROUP, and that is
		# load-bearing: naming the class here makes regrowth_manager.gd a
		# compile-time dependency of this script, and it references the
		# FireManager / TimeManager / SeasonManager autoloads — which do not
		# resolve while a `--script` tool compiles. The whole dependency chain
		# then fails, this script silently loses its script binding, and the
		# preview tools render visitors that trample nothing. VisitorFlow keeps
		# its own copy of the constant for exactly this reason.
		_regrowth = get_tree().get_first_node_in_group(&"regrowth")
		if _regrowth == null:
			return
	_regrowth.call(&"trample", cell)


func _rng() -> RandomNumberGenerator:
	# GridWalker owns the stream (it needs one for frame holds); the spawner
	# assigns a derived one before add_child so a crowd is reproducible.
	return _anim_rng()
