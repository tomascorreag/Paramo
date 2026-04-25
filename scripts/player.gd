class_name Player
extends CharacterBody2D

# ============================================================================
# Player — click-to-move path follower
# ============================================================================
#
# Consumes paths from the Pathfinder (fed via ClickToMoveController) and
# walks them cell-by-cell along the four grid axes. Position AND altitude are
# lerped over each step, so stairs and half-height tiles animate smoothly.
#
# `global_position` tracks the ground-level world position (lerped during
# movement). Sorting uses `y_sort_origin` to snap the sort key to the
# destination cell during transit, preventing mid-step tile overlap.
#
# Facing is picked ONCE per step from the step direction (d = to - from).
# Since movement is strictly along one grid axis per step, there's no
# ambiguity — a direct Vector2i -> frame index lookup does the job.
#
# ============================================================================


const FACING_SW: int = 0
const FACING_SE: int = 1
const FACING_NE: int = 2
const FACING_NW: int = 3

# Sprite sheet layout: 6 walk frames per direction, laid out contiguously.
# Frame 0 of each block is the neutral/planted pose used when idle.
const WALK_FRAMES_PER_DIR: int = 6
const WALK_FPS: float = 8.0

# Grid-axis step direction -> facing index. Keys cover the 4 legal path
# transitions. Any other direction is a bug in the pathfinder.
const DIR_TO_FACING: Dictionary = {
	Vector2i(0, 1): FACING_SW, # step toward SW (down-left on screen)
	Vector2i(1, 0): FACING_SE, # step toward SE (down-right on screen)
	Vector2i(0, -1): FACING_NE, # step toward NE (up-right on screen)
	Vector2i(-1, 0): FACING_NW, # step toward NW (up-left on screen)
}


@export var step_duration: float = 0.45
## Per-cube multiplier applied to step_duration when the step crosses a
## Pathfinder traversal edge (ladders). Total climb time scales with the
## ladder's height: step_duration * climb_duration_multiplier * height_cubes.
## A 1-cube climb at multiplier 1.5 takes 1.5× a normal step; a 4-cube climb
## takes 6×.
@export var climb_duration_multiplier: float = 2
@export var debug_logging: bool = false

@export_group("Lantern")
## Time of day [0..1] when lantern turns on (e.g., 0.75 = dusk).
@export var lantern_activate_time: float = 0.75
## Time of day [0..1] when lantern turns off (e.g., 0.28 = dawn).
@export var lantern_deactivate_time: float = 0.28

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _shadow: Sprite2D = $Shadow
@onready var _camera: Camera2D = $Camera2D
@onready var _light: PlayerLightController = $PlayerLight

# Base sprite offset from the scene (feet-to-center). Altitude lift is added
# on top of this so the visual shifts up while global_position stays at
# ground level for Y-sort.
var _base_sprite_offset_y: float

# Authored shadow visual_y_offset from the scene file. _apply_visual_lift
# adds the lift delta on top of this baseline, so the runtime shadow matches
# the shadow position the artist set up in the player scene.
var _base_visual_y_offset: float = 0.0

# Lerped shadow taper cutoff (screen px from entity cell center, positive in
# the taper direction). _push_shadow_cell_state computes a target from the
# pathfinder's altitude deltas; _physics_process slides current toward target
# at iso step speed (cell_width / step_duration) so the shadow extends/retracts
# at roughly the same pace as the player walks. The "no clip" sentinel is
# pinned to the shadow's own max extent (+ 1 px) so the lerp range stays
# within visible territory — no point lerping through values past where the
# shape would draw anyway.
const _SHADOW_CUTOFF_CELL_W: float = 32.0
const _SHADOW_CUTOFF_HALF_W: float = 16.0
var _shadow_no_clip: float = 1000.0
var _shadow_cutoff_current: float = 1000.0
var _shadow_cutoff_target: float = 1000.0

var _pathfinder: Pathfinder
var _time_manager: Node # TimeManager autoload

var current_cell: Vector2i = Vector2i.ZERO

# Current facing (0..3). The sprite frame is _facing * WALK_FRAMES_PER_DIR +
# walk_frame. Shadow uses a 4-frame base sheet, so its frame == _facing.
var _facing: int = FACING_SE

# Continuous walk-cycle clock. Advances while moving, resets when idle. Keeps
# the cycle at WALK_FPS regardless of step_duration, so cadence stays natural
# even when steps are faster or slower than one cycle.
var _walk_time: float = 0.0

# Step state. _stepping == true iff we're mid-lerp between two cells.
var _stepping: bool = false
var _step_from_cell: Vector2i
var _step_to_cell: Vector2i
var _step_from_alt: float = 0.0
var _step_to_alt: float = 0.0
var _step_t: float = 0.0
var _step_duration_effective: float = 0.45
# True when this step crosses a Pathfinder traversal edge (ladder). Triggers
# L-shaped interpolation in _apply_step_interp instead of a straight lerp.
var _step_is_climb: bool = false
# Set once per descent step when the player flips from walk-direction facing
# to ladder-facing (see _apply_step_interp). Resets each _begin_next_step.
var _step_climb_turned: bool = false

# Queued future destinations (excluding the step currently in progress).
var _path: Array[Vector2i] = []

# Current altitude in half-steps (float so half ramps render smoothly).
var _altitude: float = 0.0

# True while the opening camera pan is running. Suppresses the per-frame
# camera Y write in _apply_visual_lift so the pan is fully decoupled from
# player movement (no tile-cross snaps mid-pan). Cleared by _finish_opening_pan.
var _camera_panning: bool = false

# Tracked every time _apply_visual_lift runs (including during pan). Holds
# the local Y the camera would sit at if it were following normally —
# used by the pan _process loop to chase the player's current rest target.
var _camera_target_local_y: float = 0.0

# Opening pan integration state. Drives a sine ease-in/out toward a moving
# target (the player's current rest position) using a remaining-progress
# lerp factor. Falls back to lerp(camera, target, k) per frame.
var _pan_elapsed: float = 0.0
var _pan_duration: float = 0.0
var _pan_eased_prev: float = 0.0


func _enter_tree() -> void:
	add_to_group(&"player")


func _exit_tree() -> void:
	if is_instance_valid(_shadow):
		_shadow.queue_free()


func _ready() -> void:
	_base_sprite_offset_y = _sprite.offset.y
	var shadow_mat := _shadow.material as ShaderMaterial
	if shadow_mat != null:
		var v: Variant = shadow_mat.get_shader_parameter(&"visual_y_offset")
		if v != null:
			_base_visual_y_offset = float(v)
		# Cache the shadow's max extent so the cutoff lerp range stays within
		# visible territory. extent = |shadow_length| + cap_width matches the
		# shader's vertex-side calculation.
		var slen_v: Variant = shadow_mat.get_shader_parameter(&"shadow_length")
		var capw_v: Variant = shadow_mat.get_shader_parameter(&"cap_width")
		var slen: float = absf(float(slen_v)) if slen_v != null else 0.0
		var capw: float = float(capw_v) if capw_v != null else 0.0
		_shadow_no_clip = slen + capw + 1.0
		_shadow_cutoff_current = _shadow_no_clip
		_shadow_cutoff_target = _shadow_no_clip
		shadow_mat.set_shader_parameter(&"cutoff_x", _shadow_no_clip)
	_time_manager = get_node_or_null("/root/TimeManager")

	# Reparent shadow to world level so it y-sorts independently against tiles.
	remove_child(_shadow)
	get_parent().add_child.call_deferred(_shadow)
	_shadow.add_to_group(&"shadow")
	_shadow.set_meta(&"shadow_scale", 1.0)

	_pathfinder = get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	if _pathfinder == null:
		push_error("Player: no Pathfinder found in group '%s'." % Pathfinder.GROUP_NAME)
		return

	# Pathfinder joins its group in _enter_tree but builds the AStar graph in
	# _ready. Defer the starting-cell snap by one frame so the graph is ready
	# regardless of sibling _ready ordering.
	call_deferred("_snap_to_starting_cell")


# ----------------------------------------------------------------------------
# Public API (called by ClickToMoveController, tests, or future systems)
# ----------------------------------------------------------------------------

func get_shadow_material() -> ShaderMaterial:
	if _shadow and _shadow.material:
		return _shadow.material as ShaderMaterial
	return null


func follow_path(cells: Array[Vector2i]) -> void:
	_path = cells.duplicate()
	# If not currently stepping, the next _physics_process will begin one.
	# If currently stepping, finish the current step first (stay grid-aligned)
	# then consume the new path starting from _step_to_cell.
	if debug_logging:
		print("Player: follow_path with %d cells" % cells.size())


func stop() -> void:
	_path.clear()


func is_moving() -> bool:
	return _stepping or not _path.is_empty()


# ----------------------------------------------------------------------------
# Physics loop
# ----------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	_update_lantern()
	_tick_shadow_cutoff(delta)

	if _pathfinder == null:
		return

	if _stepping:
		_walk_time += delta
		_step_t += delta / _step_duration_effective
		if _step_t >= 1.0:
			_finish_step()
		else:
			_apply_step_interp(_step_t)
		return

	if not _path.is_empty():
		_begin_next_step()
	elif _walk_time != 0.0:
		# Fully idle: snap back to the planted-foot pose.
		_walk_time = 0.0
		_sprite.frame = _facing * WALK_FRAMES_PER_DIR


# ----------------------------------------------------------------------------
# Step machinery
# ----------------------------------------------------------------------------

func _begin_next_step() -> void:
	var next_cell: Vector2i = _path[0]
	_path.remove_at(0)

	var dir := next_cell - current_cell
	# Defensive: if the path has a non-adjacent or illegal move, skip it.
	if abs(dir.x) + abs(dir.y) != 1:
		push_warning("Player: non-adjacent path step %s -> %s; skipping." % [current_cell, next_cell])
		return
	if not _pathfinder.is_walkable(next_cell):
		push_warning("Player: path step into non-walkable cell %s; aborting path." % next_cell)
		_path.clear()
		return

	_step_from_cell = current_cell
	_step_to_cell = next_cell
	_step_from_alt = _altitude
	_step_to_alt = _pathfinder.altitude_center(next_cell)
	_step_t = 0.0
	_stepping = true
	# Ladder steps (any step that crosses a Pathfinder traversal edge) take
	# longer than a normal grid step — the player is climbing, not walking —
	# and follow an L-shaped visual path (see _apply_step_interp).
	_step_is_climb = _pathfinder.has_traversal_edge(current_cell, next_cell)
	_step_climb_turned = false
	if _step_is_climb:
		# Ladder height (in full cubes) = |altitude delta| / 2. Ladders are
		# validated to integer-cube heights, so this divides evenly; floats
		# are used only to tolerate any future sub-cube edges without
		# collapsing to zero. Clamp to >=1 so a degenerate 0-delta edge
		# still takes one climb step's worth of time.
		var alt_delta: float = absf(_step_to_alt - _step_from_alt)
		var cubes: float = maxf(alt_delta / 2.0, 1.0)
		_step_duration_effective = step_duration * climb_duration_multiplier * cubes
	else:
		_step_duration_effective = step_duration

	# Commit the "logical" cell now: future pathfinds will plan from
	# _step_to_cell, not from the cell we're leaving. This lets reclicks
	# mid-step produce paths from the cell the player is committed to
	# reaching, which is the only sensible anchor point.
	current_cell = next_cell
	_push_shadow_cell_state()

	_set_facing(dir)
	_apply_step_interp(0.0)


func _finish_step() -> void:
	_stepping = false
	_altitude = _step_to_alt
	_apply_position(_step_to_cell, _altitude)
	# Intentionally don't reset sprite frame here — the walk cycle continues
	# across step boundaries. Idle reset happens in _physics_process when the
	# path is empty.


func _apply_step_interp(t: float) -> void:
	var clamped := clampf(t, 0.0, 1.0)
	var from_world := _pathfinder.cell_to_world(_step_from_cell)
	var to_world := _pathfinder.cell_to_world(_step_to_cell)
	var pos: Vector2
	var alt: float
	if _step_is_climb:
		# L-shaped ladder path. The ladder sprite sits on the LOWER cell, so
		# the vertical climb happens "over" that cell's (x, y), then a
		# screen-diagonal slide covers the grid step at the HIGH altitude.
		#   Going up  : phase 1 rise in place over from_world, phase 2 slide to to_world at high alt.
		#   Going down: phase 1 slide from from_world to lower_world at high alt, phase 2 descend in place.
		# _CLIMB_VERTICAL_FRAC makes the vertical leg "mostly over the base
		# tile" — the horizontal slide gets the remaining fraction.
		var going_up := _step_to_alt > _step_from_alt
		var lower_world: Vector2 = from_world if going_up else to_world
		var high_alt: float = _step_to_alt if going_up else _step_from_alt
		var low_alt: float = _step_from_alt if going_up else _step_to_alt
		var vfrac: float = _CLIMB_VERTICAL_FRAC
		if going_up:
			if clamped < vfrac:
				var ph := clamped / vfrac
				pos = lower_world
				alt = lerpf(low_alt, high_alt, ph)
			else:
				var ph := (clamped - vfrac) / (1.0 - vfrac)
				pos = lower_world.lerp(to_world, ph)
				alt = high_alt
		else:
			var hfrac: float = 1.0 - vfrac
			if clamped < hfrac:
				var ph := clamped / hfrac
				pos = from_world.lerp(lower_world, ph)
				alt = high_alt
			else:
				# At the top of the ladder, turn around to face it before
				# descending. Fires once per descent step.
				if not _step_climb_turned:
					# _step_from_cell is the upper cell on descent; flipping
					# the subtraction gives the lower→upper direction (NE/NW).
					var ladder_dir := _step_from_cell - _step_to_cell
					_set_facing(ladder_dir)
					_step_climb_turned = true
				var ph := (clamped - hfrac) / vfrac
				pos = lower_world
				alt = lerpf(high_alt, low_alt, ph)
	else:
		pos = from_world.lerp(to_world, clamped)
		alt = lerpf(_step_from_alt, _step_to_alt, clamped)
	_altitude = alt
	# Snap sort-Y to the southernmost (max Y) of origin/destination so the
	# player stays in front of both tiles throughout the step.
	var snap_y := maxf(from_world.y, to_world.y)
	global_position = Vector2(pos.x, snap_y) + Pathfinder.VISUAL_SURFACE_OFFSET + Vector2(0.0, _SORT_OFFSET)
	# Compensate the Y snap on sprite/camera so movement looks smooth.
	_apply_visual_lift(alt, pos.y - snap_y)
	# Walk cycle runs at WALK_FPS independent of step_duration.
	var walk_frame: int = int(_walk_time * WALK_FPS) % WALK_FRAMES_PER_DIR
	_sprite.frame = _facing * WALK_FRAMES_PER_DIR + walk_frame


func _apply_position(cell: Vector2i, alt: float) -> void:
	var base := _pathfinder.cell_to_world(cell)
	global_position = base + Pathfinder.VISUAL_SURFACE_OFFSET + Vector2(0.0, _SORT_OFFSET)
	_apply_visual_lift(alt, 0.0)


# All tiles have y_sort_origin = -16, which shifts their sort point 16 px
# north of their render position. The player must sort from the same
# reference to interleave correctly with tiles. _SORT_OFFSET aligns the
# player's sort key with tiles, plus 1 px so the player draws IN FRONT of
# the tile at their own cell but BEHIND the next tile to the SE.
#
# If per-tile y_sort_origin changes in the tileset, update this constant.
const _SORT_OFFSET: float = -15.0 # tile_y_sort_origin(-16) + 1

# Camera target offset (added on top of lift). Positive Y shifts the framing
# downward, putting the player slightly above center and giving more headroom
# below.
const _CAMERA_TARGET_OFFSET_Y: float = -10.0


# Fraction of a climb step spent on the vertical leg (over the lower cell's
# (x, y)). The remainder is the screen-diagonal slide at the high altitude.
# >0.5 → "mostly over the base tile" per the design intent.
const _CLIMB_VERTICAL_FRAC: float = 0.65


# Altitude and sort-offset both shift global_position away from the visual
# foot position. Undo both on the sprite and camera so the player LOOKS
# correct while sorting correctly. `y_visual_diff` compensates for the Y
# snap during movement (0.0 when at rest).
func _apply_visual_lift(alt: float, y_visual_diff: float) -> void:
	var lift := -alt * Pathfinder.HALF_STEP_PX - _SORT_OFFSET + y_visual_diff
	_sprite.offset.y = _base_sprite_offset_y + lift
	# Shadow sorts 1px north of the player (always behind), visual feet
	# offset is pushed into the vertex shader so sort Y stays decoupled.
	_shadow.global_position = Vector2(global_position.x, global_position.y - 1.0)
	_shadow.material.set_shader_parameter(&"visual_y_offset", _base_visual_y_offset + lift + 1.0)
	# Always cache the local target Y so the opening-pan _process loop can
	# read an up-to-date rest position even while we're not writing to the
	# camera (pan owns the camera transform during top_level mode).
	_camera_target_local_y = lift + _CAMERA_TARGET_OFFSET_Y
	if not _camera_panning:
		_camera.position.y = _camera_target_local_y
	_light.position.y = _base_sprite_offset_y + lift


func _push_shadow_cell_state() -> void:
	# Push per-cell roughness immediately (binary surface change). Recompute
	# the cutoff target from altitude deltas; the actual `cutoff_x` uniform
	# is lerped toward it in _physics_process so the shadow extends/retracts
	# smoothly across cell boundaries.
	if _pathfinder == null or _shadow == null:
		return
	var mat := _shadow.material as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter(&"roughness", _pathfinder.roughness_at(current_cell))
	var slen: Variant = mat.get_shader_parameter(&"shadow_length")
	var dir_sign: int = 1
	if (typeof(slen) == TYPE_FLOAT or typeof(slen) == TYPE_INT) and float(slen) < 0.0:
		dir_sign = -1
	var deltas: Vector3 = _pathfinder.shadow_altitude_deltas(current_cell, dir_sign)
	_shadow_cutoff_target = _cutoff_from_deltas(deltas)


# First mismatching neighbor in (deltas.x, deltas.y, deltas.z) sets the cutoff
# at its near edge. 0.25 threshold tolerates float noise on half-integer
# altitudes; sentinel deltas (empty / non-walkable, e.g. 99.0) also trip it.
func _cutoff_from_deltas(deltas: Vector3) -> float:
	if absf(deltas.x) > 0.25:
		return _SHADOW_CUTOFF_HALF_W
	if absf(deltas.y) > 0.25:
		return _SHADOW_CUTOFF_HALF_W + _SHADOW_CUTOFF_CELL_W
	if absf(deltas.z) > 0.25:
		return _SHADOW_CUTOFF_HALF_W + 2.0 * _SHADOW_CUTOFF_CELL_W
	return _shadow_no_clip


# Slide _shadow_cutoff_current toward _shadow_cutoff_target at iso step speed
# and push the result. Called every physics frame from _physics_process so the
# shadow extends/retracts at the same pace as the player walks.
func _tick_shadow_cutoff(delta: float) -> void:
	if _shadow == null:
		return
	var mat := _shadow.material as ShaderMaterial
	if mat == null:
		return
	# Match player iso step speed: one cell-width per step_duration.
	var speed_px_per_sec: float = _SHADOW_CUTOFF_CELL_W / maxf(_step_duration_effective, 0.001)
	if _shadow_cutoff_target > _shadow_cutoff_current:
		# Extending: move outward at step speed.
		_shadow_cutoff_current = minf(
			_shadow_cutoff_target, _shadow_cutoff_current + speed_px_per_sec * delta
		)
	else:
		# Retracting: move inward at step speed.
		_shadow_cutoff_current = maxf(
			_shadow_cutoff_target, _shadow_cutoff_current - speed_px_per_sec * delta
		)
	# Avoid noise: when within 0.5 px of target, snap to target.
	if absf(_shadow_cutoff_current - _shadow_cutoff_target) < 0.5:
		_shadow_cutoff_current = _shadow_cutoff_target
	mat.set_shader_parameter(&"cutoff_x", _shadow_cutoff_current)


func _update_lantern() -> void:
	if _time_manager == null:
		return
	var t: float = _time_manager.time_of_day
	# activate > deactivate means the active window wraps past midnight
	var should_be_on: bool
	if lantern_activate_time > lantern_deactivate_time:
		should_be_on = t >= lantern_activate_time or t < lantern_deactivate_time
	else:
		should_be_on = t >= lantern_activate_time and t < lantern_deactivate_time

	if should_be_on:
		_light.activate()
	else:
		_light.deactivate()


func _set_facing(dir: Vector2i) -> void:
	if not DIR_TO_FACING.has(dir):
		return
	_facing = DIR_TO_FACING[dir]
	_sprite.frame = _facing * WALK_FRAMES_PER_DIR
	_shadow.frame = _facing


# ----------------------------------------------------------------------------
# Startup positioning
# ----------------------------------------------------------------------------

func _snap_to_starting_cell() -> void:
	if _pathfinder == null:
		return

	var start := _pathfinder.world_to_cell(global_position)
	if not _pathfinder.is_walkable(start):
		push_warning(
			"Player: starting position %s resolves to non-walkable cell %s. "
			% [global_position, start]
			+"Move the player node in the editor to a walkable cell."
		)
		return

	current_cell = start
	_altitude = _pathfinder.altitude_center(start)
	_apply_position(current_cell, _altitude)
	_push_shadow_cell_state()
	# Initial snap: skip the lerp on first frame so the shadow starts in its
	# correct extent rather than retracting in from "no clip".
	_shadow_cutoff_current = _shadow_cutoff_target

	# Opening camera pan: fully detached from player movement (top_level so
	# the parent transform is ignored). The pan target is recomputed every
	# frame in _process so the camera converges on wherever the player
	# currently is — if they walk during the pan, the landing point follows.
	const OPENING_PAN_PX := 120.0
	const OPENING_PAN_DURATION := 10.0
	var rest_world := _camera_pan_target_world()
	_camera_panning = true
	_pan_elapsed = 0.0
	_pan_duration = OPENING_PAN_DURATION
	_pan_eased_prev = 0.0
	_camera.position_smoothing_enabled = false
	_camera.top_level = true
	_camera.position = Vector2(rest_world.x, rest_world.y - OPENING_PAN_PX)

	if debug_logging:
		print("Player: snapped to cell %s at altitude %s" % [current_cell, _altitude])


# Player's current rest position in world space. Used as the pan's moving
# target — if the player walks during the pan, the camera homes in on them
# wherever they end up. Y uses the cached local target (which already
# includes y_visual_diff compensation) so mid-step tile snaps don't bleed
# through.
func _camera_pan_target_world() -> Vector2:
	return Vector2(global_position.x, global_position.y + _camera_target_local_y)


func _process(delta: float) -> void:
	if not _camera_panning:
		return
	_pan_elapsed += delta
	var target: Vector2 = _camera_pan_target_world()
	if _pan_elapsed >= _pan_duration:
		_camera.position = target
		_finish_opening_pan()
		return
	var t: float = _pan_elapsed / _pan_duration
	# Sine ease-in/out: -0.5 * (cos(PI*t) - 1) ∈ [0, 1].
	var eased: float = -0.5 * (cos(PI * t) - 1.0)
	# Remaining-progress lerp factor. Equivalent to a fixed sine curve when
	# the target is static, but tracks a moving target smoothly because k
	# applies to the *current* gap, not a stale start point.
	var k: float = (eased - _pan_eased_prev) / maxf(1.0 - _pan_eased_prev, 0.0001)
	_camera.position = _camera.position.lerp(target, k)
	_pan_eased_prev = eased


# Hand the camera back to the player-follow path after the opening pan.
# Order matters: re-enable smoothing and call reset_smoothing() while the
# camera is still at its world-space pan endpoint so the smoothed view is
# seeded there. Then drop top_level and write the correct local target.
func _finish_opening_pan() -> void:
	_camera.position_smoothing_enabled = true
	_camera.reset_smoothing()
	_camera.top_level = false
	_camera.position = Vector2(0.0, _camera_target_local_y)
	_camera_panning = false
