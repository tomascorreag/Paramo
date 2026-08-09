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
# A pathfinder's shortest route between two cells is essentially unique, so a
# group sharing an entry and a goal walks the same line in single file. The
# noise is added as detour WAYPOINTS rather than as jitter on the path, so every
# step remains a real find_path result and no visitor can wander through a fence
# or across a gap. See _wandering_path.
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
@export var wander_radius_cells: int = 2

@export_group("Breathers")
## Chance, rolled when each step BEGINS, that the visitor stands still once that
## step lands. Per step rather than on a timer so a slow walker (fewer steps per
## minute) does not also stop more often than a fast one.
@export_range(0.0, 1.0, 0.01) var rest_chance_per_step: float = 0.04
@export var rest_seconds_min: float = 1.2
@export var rest_seconds_max: float = 3.5

var entry_cell: Vector2i = Vector2i.ZERO
var goal_cell: Vector2i = Vector2i.ZERO
## Which indexed sheet this person is built from. Null keeps the scene's own.
var sheet: Texture2D = null
var colors: PackedColorArray = PackedColorArray()
var reach: Dictionary = {}

var _state: int = State.TO_GOAL
var _linger_left: float = 0.0
var _fade: float = 0.0
var _regrowth: Node = null

# get_node_or_null, not $: a visitor is normally instanced from visitor.tscn,
# but nothing here NEEDS a body — GridWalker walks fine without one — and a
# bare `Visitor.new()` is the cheapest way for a test to exercise the state
# machine.
@onready var _visitor_sprite: Sprite2D = get_node_or_null(^"Sprite2D")
@onready var _visitor_shadow: Sprite2D = get_node_or_null(^"Shadow")


func _process(delta: float) -> void:
	tick(delta)


func _ready() -> void:
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


## The frame body. Public and separate from _process because VisitorSpawner
## drives its whole crowd itself (see its `tick`) — in the game as well as in
## the balance simulator, so there is one update path and one order rather than
## a headless special case.
func tick(delta: float) -> void:
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
## opened a route. `new_reach` is the spawner's freshly computed reachable set
## from the entry cell.
func _on_graph_changed() -> void:
	if _state == State.LEAVING:
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
static func nearest_reachable(reach_set: Dictionary, target: Vector2i,
		from: Vector2i, pathfinder: Pathfinder) -> Vector2i:
	if pathfinder == null:
		return Pathfinder.NO_CELL
	var ordered: Array = reach_set.keys()
	ordered.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return dist2(a, target) < dist2(b, target))
	for cell: Vector2i in ordered:
		if cell == from or not pathfinder.is_walkable(cell):
			continue
		if pathfinder.find_path(from, cell).size() >= 2:
			return cell
	return Pathfinder.NO_CELL


static func dist2(a: Vector2i, b: Vector2i) -> int:
	var d := a - b
	return d.x * d.x + d.y * d.y


## Route to `cell`, usually via a couple of detour waypoints (see the "noise"
## note in the header). Falls back to the direct path whenever the detour cannot
## be built — a wandering visitor that fails to route is worse than a tidy one.
func _walk_to(cell: Vector2i) -> bool:
	if _pathfinder == null or cell == current_cell:
		return false
	var path := _wandering_path(cell)
	if path.is_empty():
		path = _direct_path(cell)
	if path.is_empty():
		return false
	follow_path(path)
	return true


## find_path includes the start cell; follow_path takes NEXT destinations only.
func _direct_path(cell: Vector2i) -> Array[Vector2i]:
	var path := _pathfinder.find_path(current_cell, cell)
	if path.size() < 2:
		return [] as Array[Vector2i]
	path.remove_at(0)
	return path


# The straight line, cut at even fractions, each cut nudged somewhere random
# nearby, then re-joined by the pathfinder. Perturbing WAYPOINTS rather than the
# path itself keeps every step legal by construction: each leg is still a real
# find_path result, so no wandering visitor can walk through a fence or off a
# cliff, and terrain still shapes the route between the detours.
func _wandering_path(target: Vector2i) -> Array[Vector2i]:
	if wander_chance <= 0.0 or wander_waypoints_max <= 0:
		return [] as Array[Vector2i]
	if _rng().randf() >= wander_chance:
		return [] as Array[Vector2i]

	var count: int = _rng().randi_range(1, wander_waypoints_max)
	var stops: Array[Vector2i] = []
	for i in count:
		var t: float = float(i + 1) / float(count + 1)
		var on_line := Vector2(current_cell).lerp(Vector2(target), t)
		var cell := _scatter_near(Vector2i(on_line.round()))
		if cell != Pathfinder.NO_CELL:
			stops.append(cell)
	stops.append(target)

	var out: Array[Vector2i] = []
	var from := current_cell
	for stop: Vector2i in stops:
		if stop == from:
			continue
		var leg := _pathfinder.find_path(from, stop)
		if leg.size() < 2:
			return [] as Array[Vector2i]
		leg.remove_at(0)
		out.append_array(leg)
		from = stop
	return out


# A walkable cell within wander_radius_cells of `around`. Sampled rather than
# searched: the radius is small and most of a landmass is walkable, so a handful
# of draws beats scanning the disc, and giving up costs only a straighter route.
func _scatter_near(around: Vector2i) -> Vector2i:
	for _attempt in 8:
		var offset := Vector2i(
				_rng().randi_range(-wander_radius_cells, wander_radius_cells),
				_rng().randi_range(-wander_radius_cells, wander_radius_cells))
		var cell := around + offset
		if _pathfinder.is_walkable(cell):
			return cell
	return Pathfinder.NO_CELL


# Breathers are rolled at step START so the pause lands when that step does —
# GridWalker holds it to the boundary either way, but rolling here means the
# odds are per cell walked, which is what makes them independent of pace.
func _on_step_started(cell: Vector2i, _kind: int) -> void:
	_trample(cell)
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
