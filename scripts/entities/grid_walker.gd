class_name GridWalker
extends Node2D

# ============================================================================
# GridWalker
# ============================================================================
#
# Walks a Node2D along a Pathfinder path, cell by cell: step timing, the
# 4-facing x 6-frame walk cycle, and the Y-sort/altitude bookkeeping that makes
# a character interleave correctly with the tile stack.
#
# BOTH characters in the game are built on this: Visitor and Player. The step
# math used to be duplicated in scripts/player.gd, and the duplication was
# already costing — the per-step world-position caching added for the crowd did
# nothing for the player until Player was migrated onto this class. A fix to the
# interpolation now lands once.
#
# What is player-specific stayed in player.gd (camera and its opening pan,
# lantern, shadow altitude cutoff, footsteps, trampling, the ProceduralWorld
# placement handshake), reaching in through the hooks below. Anything a SECOND
# character would also want belongs here; anything only one of them wants
# belongs in the subclass, behind a hook.
#
# ----------------------------------------------------------------------------
# Contract
# ----------------------------------------------------------------------------
#
#   bind(pathfinder, sprite, shadow)   wire it up (shadow optional)
#   place_at(cell)                     teleport, no animation
#   follow_path(cells)                 cells are NEXT DESTINATIONS — drop the
#                                      start cell that Pathfinder.find_path
#                                      returns, as ClickToMoveController does
#   stop() / is_moving() / current_altitude()
#   pause_movement(seconds)            stand still at the next step boundary
#   frame_hold_chance                  repeat walk frames (slow walkers)
#   path_is_valid()                    is the queued path still legal?
#   anim_frame()                       monotonic walk-cycle index
#
# Subclass hooks: `_on_arrived` (path exhausted), `_on_step_started`,
# `_on_path_blocked` (the path ran into a wall), `_on_visual_lift` (anything
# that must ride the character's feet rather than its sort position).
#
# Driven from _process, not _physics_process — same reason as Player: the
# camera smooths on the render clock, so a character stepped on the 60 Hz
# physics clock visibly stutters against a world that scrolls every frame.
# Nothing here needs a fixed timestep.
#
# ============================================================================

const FACING_SW: int = 0
const FACING_SE: int = 1
const FACING_NE: int = 2
const FACING_NW: int = 3

## The rig every character currently ships with: 4 facings x 6 frames on one
## row, played at 8 fps. Kept as constants because they are the DEFAULTS and
## several tests assert against them — the live values are the exports below.
const WALK_FRAMES_PER_DIR: int = 6
const WALK_FPS: float = 8.0

const DIR_TO_FACING: Dictionary = {
	Vector2i(0, 1): FACING_SW,
	Vector2i(1, 0): FACING_SE,
	Vector2i(0, -1): FACING_NE,
	Vector2i(-1, 0): FACING_NW,
}

## Tiles all carry y_sort_origin = -16, so a character has to sort from the same
## reference to interleave with them; +1 puts it in front of the tile it stands
## on and behind the next one to the SE. Mirrors Player._SORT_OFFSET — if the
## tileset's y_sort_origin changes, both move.
const SORT_OFFSET: float = -15.0

## Fraction of a ladder step spent on the vertical leg, over the lower cell.
const CLIMB_VERTICAL_FRAC: float = 0.65


@export var step_duration: float = 0.45
@export var climb_duration_multiplier: float = 2.0
@export var scramble_duration_multiplier: float = 4.0

@export_group("Rig")
## Frames per facing on the sheet, and the cadence they play at. Per-INSTANCE
## rather than baked in, because a sheet's frame count is a property of the ART,
## not of walking: a two-frame bird or a twelve-frame quadruped is the same
## locomotion with a different rig, and a constant here would have forced it to
## be a different class. The FACING count stays fixed at 4 — that is not art, it
## is the grid: movement is 4-connected, so there are exactly four directions to
## draw (and the shadow sheet is indexed by facing too).
@export var walk_frames_per_dir: int = WALK_FRAMES_PER_DIR
@export var walk_fps: float = WALK_FPS

## Chance, rolled once per animation tick, that the walk cycle REPEATS its
## current frame instead of advancing. The cycle otherwise runs at a fixed
## WALK_FPS no matter how long a step takes, so a slow walker glides — its feet
## keep the pace of a brisk one while its body does not. Holding frames is the
## sprite-sheet equivalent of dropping the frame rate for that one character,
## and being a per-tick ROLL rather than a divisor it also breaks the lockstep
## between two walkers moving at the same speed. 0 reproduces the old fixed
## cadence exactly.
@export_range(0.0, 0.9, 0.01) var frame_hold_chance: float = 0.0

## Stream for the frame-hold roll. Left null, a private one is seeded off the
## instance id — deterministic per node, but owners that need a reproducible
## crowd (VisitorSpawner) assign their own derived stream instead.
var rng: RandomNumberGenerator = null

var current_cell: Vector2i = Vector2i.ZERO

var _pathfinder: Pathfinder = null
var _sprite: Sprite2D = null
var _shadow: Sprite2D = null
var _base_sprite_offset_y: float = 0.0
var _base_visual_y_offset: float = 0.0

var _path: Array[Vector2i] = []
var _altitude: float = 0.0
var _facing: int = FACING_SW
var _walk_time: float = 0.0
var _pause_left: float = 0.0
## The walk cycle is now COUNTED, not derived from _walk_time: a hold has to
## persist, and a frame index recomputed from elapsed time every frame cannot
## remember that it skipped an advance.
var _anim_index: int = 0
var _anim_accum: float = 0.0

var _stepping: bool = false
var _step_t: float = 0.0
var _step_duration_effective: float = 0.45
var _step_from_cell: Vector2i = Vector2i.ZERO
var _step_to_cell: Vector2i = Vector2i.ZERO
var _step_from_alt: float = 0.0
var _step_to_alt: float = 0.0
var _step_is_climb: bool = false
var _step_climb_turned: bool = false
# The two cells' world positions and the Y they snap to, resolved ONCE at step
# start. They cannot change mid-step (the step is aborted if the graph does), and
# cell_to_world is not free — it walks to the reference TileMapLayer and does two
# transform conversions. Recomputing both every frame cost the balance simulator
# two of those per walking visitor per tick.
var _step_from_world: Vector2 = Vector2.ZERO
var _step_to_world: Vector2 = Vector2.ZERO
var _step_snap_y: float = 0.0

# Cached so the per-frame lift write does not re-run the `as ShaderMaterial`
# cast; the shadow's material never changes after bind.
var _shadow_material: ShaderMaterial = null
# Last frame index actually written to the sprite. Writing a Sprite2D property is
# a setter call through the bindings even when the value is unchanged, and the
# frame only changes ~8 times a second while this runs every frame.
var _sprite_frame_written: int = -1


# ----------------------------------------------------------------------------
# Setup
# ----------------------------------------------------------------------------

## `shadow` is reparented to the walker's parent so it y-sorts against tiles on
## its own — a shadow that stays a child would inherit the sprite's sort key and
## draw over the ground in front of it. The caller owns freeing it; `free_shadow`
## does that and every subclass should call it from _exit_tree.
func bind(pathfinder: Pathfinder, sprite: Sprite2D, shadow: Sprite2D = null) -> void:
	_pathfinder = pathfinder
	_sprite = sprite
	_shadow = shadow
	_sprite_frame_written = -1
	if _sprite != null:
		_base_sprite_offset_y = _sprite.offset.y
	if _shadow != null:
		_shadow_material = _shadow.material as ShaderMaterial
		if _shadow_material != null:
			var v: Variant = _shadow_material.get_shader_parameter(&"visual_y_offset")
			if v != null:
				_base_visual_y_offset = float(v)
		if _shadow.get_parent() == self:
			remove_child(_shadow)
			# Deferred only when the new parent is still setting its own children
			# up. A walker instanced at RUNTIME (every Visitor) binds against a
			# parent that is long since ready, and there the reparent must be
			# SYNCHRONOUS: a balance-simulator run is a single frame, so a deferred
			# call never lands and the shadow is still a child when the visitor is
			# freed. A walker in an AUTHORED scene (Player) binds from its own
			# _ready, which runs bottom-up — the parent is mid-setup and Godot
			# rejects an add_child there.
			var host := get_parent()
			if host.is_node_ready():
				host.add_child(_shadow)
			else:
				host.add_child.call_deferred(_shadow)
		_shadow.add_to_group(&"shadow")
		_shadow.set_meta(&"shadow_scale", 1.0)


## `immediate` frees the shadow NOW instead of queueing it. The queue is right
## from _exit_tree (freeing a sibling mid-notification is asking for trouble),
## but wrong for a caller tearing the walker down deliberately: the balance
## simulator runs a whole game inside ONE frame, so a queued free never lands,
## and SimWorld.regenerate then removes the shadow from the tree WITHOUT freeing
## it — an orphan per visitor per run.
func free_shadow(immediate: bool = false) -> void:
	if is_instance_valid(_shadow):
		if immediate:
			_shadow.free()
		else:
			_shadow.queue_free()
	_shadow = null
	_shadow_material = null


# ----------------------------------------------------------------------------
# Public API
# ----------------------------------------------------------------------------

## Teleport to `cell`, cancelling any path. Used at spawn.
func place_at(cell: Vector2i) -> void:
	_path.clear()
	_stepping = false
	_pause_left = 0.0
	current_cell = cell
	_altitude = _pathfinder.altitude_center(cell) if _pathfinder != null else 0.0
	_apply_position(cell, _altitude)
	_rewind_anim()


## `cells` are next destinations, NOT including the current cell. A path
## straight from Pathfinder.find_path must have index 0 removed first.
func follow_path(cells: Array[Vector2i]) -> void:
	_path = cells.duplicate()


func stop() -> void:
	_path.clear()


## Stand still for `seconds` before taking the next step. The pause is applied
## at a step BOUNDARY, never mid-stride: a walker frozen halfway between two
## cells is standing on the join between two tiles, which reads as a stuck
## sprite rather than as someone catching their breath. So a pause requested
## during a step takes effect when that step lands.
## Repeated calls take the LONGER remaining wait rather than stacking.
func pause_movement(seconds: float) -> void:
	_pause_left = maxf(_pause_left, seconds)


func is_paused() -> bool:
	return _pause_left > 0.0


func is_moving() -> bool:
	return _stepping or not _path.is_empty()


## True when every remaining queued step is still legal on the CURRENT graph.
##
## The point is to let an owner answer "did that graph change affect me?" without
## re-pathing. A re-path is several A* runs; this is a dict lookup per queued
## cell, and the answer is yes for almost every walker almost every time — a
## fence goes up on one side of the mountain and nobody else's route touches it.
## Cheap enough to run on every graph change; a fence RUN emits one per tile.
##
## Walks from `current_cell` because that is the cell already committed to (see
## _begin_next_step), which is where _path[0] leads on from.
func path_is_valid() -> bool:
	if _pathfinder == null:
		return false
	if _path.is_empty():
		return true
	var grid := _pathfinder.grid()
	if grid == null:
		return false
	var from: Vector2i = current_cell
	for cell: Vector2i in _path:
		# can_transition, not is_walkable: it checks BOTH cells and the edge
		# between them, and the edge is the part a cell check misses — removing a
		# ladder leaves its two cells walkable and the link between them gone.
		if not grid.can_transition(from, cell):
			return false
		from = cell
	return true


## Altitude in half-steps, interpolated continuously across a step.
func current_altitude() -> float:
	return _altitude


func facing() -> int:
	return _facing


## The walk cycle's frame count since the walker last went idle — MONOTONIC, not
## wrapped to WALK_FRAMES_PER_DIR. Player counts foot contacts off this
## (see its _tick_footfalls): a running total means a frame hitch that skips
## past a contact still produces exactly one footfall, never zero and never a
## burst, which an "is the current frame a contact frame?" test cannot promise.
##
## This is also why the cycle is COUNTED rather than derived from elapsed time:
## a frame_hold_chance repeat has to hold the footfall too.
func anim_frame() -> int:
	return _anim_index


# ----------------------------------------------------------------------------
# Hooks for subclasses
# ----------------------------------------------------------------------------

## The path ran out. Fires once per arrival, not every idle frame.
func _on_arrived() -> void:
	pass


## A step onto `cell` began, classified as TileGrid.StepKind `kind`.
func _on_step_started(_cell: Vector2i, _kind: int) -> void:
	pass


## The queued path led into a cell that is no longer walkable, and has been
## dropped. Silent by default: for a visitor this is routine (the player fenced
## the route) and the owner re-paths on Pathfinder.graph_changed. Player
## overrides it to warn, because a click-to-move path into a wall is a bug.
func _on_path_blocked(_cell: Vector2i) -> void:
	pass


## The visual lift for this frame has been applied to the sprite and shadow.
## `lift` is the pixel offset that undoes altitude and SORT_OFFSET — anything
## else that must sit at the character's FEET rather than at its sort position
## (Player's camera and lantern) hangs off this.
func _on_visual_lift(_lift: float) -> void:
	pass


# ----------------------------------------------------------------------------
# Movement loop
# ----------------------------------------------------------------------------

func _process(delta: float) -> void:
	tick_movement(delta)


## The frame body, public so tests can drive fixed steps with _process off —
## the same shape VisitorFlow.tick and TimeManager.advance use.
## The sprite is OPTIONAL. Everything here except the frame index is world
## state — which cell, which altitude, how far through a step — and the balance
## simulator walks real visitors headlessly to find out what they cost the
## mountain. Requiring a Sprite2D would have forced a second, parallel movement
## model there, which is exactly the divergence this class exists to prevent.
func tick_movement(delta: float) -> void:
	if _pathfinder == null:
		return

	if _stepping:
		_walk_time += delta
		_advance_anim(delta)
		_step_t += delta / _step_duration_effective
		if _step_t >= 1.0:
			_finish_step()
		else:
			_apply_step_interp(_step_t)
		return

	# Checked BEFORE the path, so a pause requested mid-step lands here — at the
	# boundary — and before arrival, so a walker that stops on its last step
	# finishes standing there rather than reporting home early.
	if _pause_left > 0.0:
		_pause_left -= delta
		_rewind_anim()
		return

	if not _path.is_empty():
		_begin_next_step()
	elif _walk_time != 0.0:
		# Fully idle: rewind to the planted-foot pose so the next walk starts
		# from frame 0.
		_walk_time = 0.0
		_rewind_anim()
		_on_arrived()


# One animation tick per 1/WALK_FPS of walking, each of which either advances
# the cycle or repeats the frame. Accumulating rather than sampling elapsed time
# is what lets a hold stick.
func _advance_anim(delta: float) -> void:
	var tick: float = 1.0 / maxf(walk_fps, 0.001)
	_anim_accum += delta
	while _anim_accum >= tick:
		_anim_accum -= tick
		if frame_hold_chance <= 0.0 or _anim_rng().randf() >= frame_hold_chance:
			_anim_index += 1


func _rewind_anim() -> void:
	_anim_index = 0
	_anim_accum = 0.0
	_write_sprite_frame(_facing * walk_frames_per_dir)


func _anim_rng() -> RandomNumberGenerator:
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.seed = get_instance_id()
	return rng


func _begin_next_step() -> void:
	var next_cell: Vector2i = _path[0]
	_path.remove_at(0)

	var dir := next_cell - current_cell
	if absi(dir.x) + absi(dir.y) != 1:
		push_warning("GridWalker: non-adjacent path step %s -> %s; skipping."
				% [current_cell, next_cell])
		return
	if not _pathfinder.is_walkable(next_cell):
		# The graph changed under the path (a fence went up mid-walk). Drop it;
		# the owner re-paths on Pathfinder.graph_changed.
		_path.clear()
		_on_path_blocked(next_cell)
		return

	_step_from_cell = current_cell
	_step_to_cell = next_cell
	_step_from_alt = _altitude
	_step_to_alt = _pathfinder.altitude_center(next_cell)
	_step_from_world = _pathfinder.cell_to_world(current_cell)
	_step_to_world = _pathfinder.cell_to_world(next_cell)
	_step_snap_y = maxf(_step_from_world.y, _step_to_world.y)
	_step_t = 0.0
	_stepping = true

	var kind: int = _pathfinder.classify_step(current_cell, next_cell)
	_step_is_climb = (kind == TileGrid.StepKind.LADDER)
	_step_climb_turned = false
	var alt_delta: float = absf(_step_to_alt - _step_from_alt)
	# Shared with the player and the balance sim's bot, so nobody duplicates
	# the cost rules.
	_step_duration_effective = TileGrid.step_duration_for(
			kind, alt_delta, step_duration,
			climb_duration_multiplier, scramble_duration_multiplier)

	# Commit the logical cell at step START: a re-path mid-step must plan from
	# the cell being committed to, not the one being left.
	current_cell = next_cell
	_on_step_started(next_cell, kind)

	_set_facing(dir)
	_apply_step_interp(0.0)


func _finish_step() -> void:
	_stepping = false
	_altitude = _step_to_alt
	_apply_position(_step_to_cell, _altitude)
	# The walk cycle deliberately continues across step boundaries; only going
	# fully idle rewinds it.


func _apply_step_interp(t: float) -> void:
	var clamped := clampf(t, 0.0, 1.0)
	# Resolved at step start — see _begin_next_step.
	var from_world := _step_from_world
	var to_world := _step_to_world
	var pos: Vector2
	var alt: float
	if _step_is_climb:
		# L-shaped ladder path: the ladder art sits on the LOWER cell, so the
		# climb happens over that cell and the grid step is covered by a
		# screen-diagonal slide at the high altitude.
		var going_up := _step_to_alt > _step_from_alt
		var lower_world: Vector2 = from_world if going_up else to_world
		var high_alt: float = _step_to_alt if going_up else _step_from_alt
		var low_alt: float = _step_from_alt if going_up else _step_to_alt
		var vfrac: float = CLIMB_VERTICAL_FRAC
		if going_up:
			if clamped < vfrac:
				pos = lower_world
				alt = lerpf(low_alt, high_alt, clamped / vfrac)
			else:
				pos = lower_world.lerp(to_world, (clamped - vfrac) / (1.0 - vfrac))
				alt = high_alt
		else:
			var hfrac: float = 1.0 - vfrac
			if clamped < hfrac:
				pos = from_world.lerp(lower_world, clamped / hfrac)
				alt = high_alt
			else:
				# Turn to face the ladder before descending it. Once per step.
				if not _step_climb_turned:
					_set_facing(_step_from_cell - _step_to_cell)
					_step_climb_turned = true
				pos = lower_world
				alt = lerpf(high_alt, low_alt, (clamped - hfrac) / vfrac)
	else:
		pos = from_world.lerp(to_world, clamped)
		alt = lerpf(_step_from_alt, _step_to_alt, clamped)
	_altitude = alt
	# Sort Y snaps to the southernmost of the two cells, so the walker stays in
	# front of BOTH for the whole step instead of popping halfway across.
	var snap_y := _step_snap_y
	global_position = Vector2(pos.x, snap_y) + Pathfinder.VISUAL_SURFACE_OFFSET \
			+ Vector2(0.0, SORT_OFFSET)
	_apply_visual_lift(alt, pos.y - snap_y)
	# The walk cycle ticks at WALK_FPS regardless of how long a step takes, so a
	# slow climb does not play in slow motion; frame_hold_chance is the one thing
	# that slows it, and only for the walker that carries it.
	_write_sprite_frame(_facing * walk_frames_per_dir
			+ (_anim_index % maxi(walk_frames_per_dir, 1)))


func _apply_position(cell: Vector2i, alt: float) -> void:
	if _pathfinder == null:
		return
	global_position = _pathfinder.cell_to_world(cell) + Pathfinder.VISUAL_SURFACE_OFFSET \
			+ Vector2(0.0, SORT_OFFSET)
	_apply_visual_lift(alt, 0.0)


# Altitude and SORT_OFFSET both move global_position away from where the
# character should LOOK like it is standing. Undo both on the sprite so it
# sorts correctly and still reads as standing on the tile. `y_visual_diff`
# compensates the mid-step Y snap (0 at rest).
func _apply_visual_lift(alt: float, y_visual_diff: float) -> void:
	var lift := -alt * Pathfinder.HALF_STEP_PX - SORT_OFFSET + y_visual_diff
	if _sprite != null:
		_sprite.offset.y = _base_sprite_offset_y + lift
	if is_instance_valid(_shadow):
		# The shadow sorts 1px north (always behind the character); its own visual
		# offset is pushed into the shader so its sort Y stays decoupled.
		_shadow.global_position = Vector2(global_position.x, global_position.y - 1.0)
		# The shadow's frame IS the facing, and facing only changes on _set_facing
		# — which writes it there. Rewriting it every frame was pure overhead.
		if _shadow_material != null:
			_shadow_material.set_shader_parameter(&"visual_y_offset",
					_base_visual_y_offset + lift + 1.0)
	# AFTER the shadow but OUTSIDE its validity guard: Player hangs its camera and
	# lantern off this, and neither has anything to do with whether a shadow
	# exists. Skipping the hook with the shadow would freeze the camera.
	_on_visual_lift(lift)


# The sprite's frame is written from the movement loop every frame but only
# CHANGES at WALK_FPS, so guard the property set.
func _write_sprite_frame(frame: int) -> void:
	if _sprite == null or frame == _sprite_frame_written:
		return
	_sprite_frame_written = frame
	_sprite.frame = frame


func _set_facing(dir: Vector2i) -> void:
	if not DIR_TO_FACING.has(dir):
		return
	_facing = DIR_TO_FACING[dir]
	_write_sprite_frame(_facing * walk_frames_per_dir)
	if is_instance_valid(_shadow):
		_shadow.frame = _facing
