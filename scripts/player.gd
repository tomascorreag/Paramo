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

# Frames of the walk cycle where a foot contacts the ground, authored in the
# sprite sheet. Footstep SFX fire on these, so the sound lands with the visible
# footfall instead of on a clock of its own. At WALK_FPS these two are evenly
# spaced (3 frames apart), giving a footfall every 0.375 s while walking.
const WALK_CONTACT_FRAMES: Array[int] = [2, 5]

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
## takes 6×. Also used flat (×1) for ramp side-steps — stepping onto/off a
## ramp from the side costs the same as a 1-cube ladder climb.
@export var climb_duration_multiplier: float = 2
## Per-cube multiplier applied to step_duration when the step is a no-ladder
## SCRAMBLE up/down a small ledge. At 4.0 a full-cube scramble takes 4× a
## normal step — 2× the cost of climbing the same cube on a ladder — and a
## half-step ledge takes 2×. Scales with height (no clamp), unlike ladders.
@export var scramble_duration_multiplier: float = 4
@export var debug_logging: bool = false

@export_group("Lantern")
## Time of day [0..1] when lantern turns on (e.g., 0.75 = dusk).
@export var lantern_activate_time: float = 0.75
## Time of day [0..1] when lantern turns off (e.g., 0.28 = dawn).
@export var lantern_deactivate_time: float = 0.28

# --- Held item -------------------------------------------------------------
#
# The player holds at most one object, DERIVED from time of day rather than
# stored: the lantern at night, nothing during the day. There's no manual
# "equip" UI. _update_lantern reads this each frame to drive the light.

## Identifiers returned by held_item(). Empty = nothing in hand.
const ITEM_NONE: StringName = &""
const ITEM_LANTERN: StringName = &"lantern"

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _shadow: Sprite2D = $Shadow
@onready var _camera: Camera2D = $Camera2D
@onready var _light: PlayerLightController = $PlayerLight
@onready var _footsteps: FootstepAudio = $FootstepAudio

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
# "No clip" sentinel pinned just past the shadow's current visual extent
# (recomputed each tick from the live shadow_length, which DayNightController
# drives over the day cycle). Caching it once at _ready was wrong: when the
# day-night system grew the shadow past the cached extent, cutoff_x stayed
# below the actual shadow body and the shader cut off the tail even with
# no real altitude difference.
var _shadow_cutoff_current: float = 1000.0
var _shadow_cutoff_target: float = 1000.0

var _pathfinder: Pathfinder
var _time_manager: Node # TimeManager autoload

var current_cell: Vector2i = Vector2i.ZERO

# True once the player has been successfully placed at its starting cell.
# Guards _snap_to_starting_cell against running twice (e.g. a stray re-call),
# which would re-trigger the opening camera pan. A FAILED attempt (non-walkable
# grid) leaves this false so a later attempt can still succeed.
var _started: bool = false

# True when a world generator (ProceduralWorld) owns initial placement, set via
# defer_to_external_placement() before generation. Suppresses the player's own
# deferred self-placement so the generator's spawn pick is authoritative on
# procedural maps. See _maybe_self_place / snap_to_start.
var _external_placement: bool = false

# Current facing (0..3). The sprite frame is _facing * WALK_FRAMES_PER_DIR +
# walk_frame. Shadow uses a 4-frame base sheet, so its frame == _facing.
var _facing: int = FACING_SE

# Continuous walk-cycle clock. Advances while moving, resets when idle. Keeps
# the cycle at WALK_FPS regardless of step_duration, so cadence stays natural
# even when steps are faster or slower than one cycle.
var _walk_time: float = 0.0

# Running count of foot contacts the walk cycle has passed since the last idle.
# Compared each tick to fire footstep SFX; counting (rather than testing
# "is the current frame a contact frame?") means a frame hitch that skips past
# a contact still produces exactly one footfall, never zero and never a burst.
var _contacts_passed: int = 0

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
# When the TitleIntro shows a "click to begin" gate, the camera is armed at the
# pan-start pose (_camera_panning true, suppressing the per-frame visual lift)
# but the pan CLOCK is held until the click releases it via start_opening_pan().
var _pan_running: bool = true

# Cell the opening pan CENTERS on at the start (the summit lake), pushed by
# ProceduralWorld before placement. -1 = no lake known → fall back to the old
# start-above-player pose. The pan then moves straight DOWN from this cell's X;
# the horizontal jump to the player is hidden by snap_camera_over_player() once
# the curtain is solid, so all visible camera motion is purely vertical.
var _opening_pan_start_cell: Vector2i = Vector2i(-1, -1)


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
		var seed_no_clip := _shadow_no_clip()
		_shadow_cutoff_current = seed_no_clip
		_shadow_cutoff_target = seed_no_clip
		shadow_mat.set_shader_parameter(&"cutoff_x", seed_no_clip)
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
	call_deferred("_maybe_self_place")


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


# Current altitude in half-steps (matches `meta/altitude` on ground layers).
# Continuously interpolated during stepping; readers polling this each frame
# (e.g. AltitudeFogController) get a smooth signal across stairs and ladders.
func current_altitude() -> float:
	return _altitude


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
		# Fully idle: snap back to the planted-foot pose and rewind the walk
		# cycle, so the next walk starts from frame 0 and its first footfall
		# lands on that cycle's first contact frame.
		_walk_time = 0.0
		_contacts_passed = 0
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
	# Step timing & visual depend on the kind of move (see TileGrid.classify_step).
	# Only a LADDER step uses the L-shaped visual path (the sprite climbs a wall);
	# scrambles and ramp side-steps animate as a normal straight lerp, just slower.
	var kind: int = _pathfinder.classify_step(current_cell, next_cell)
	_step_is_climb = (kind == TileGrid.StepKind.LADDER)
	_step_climb_turned = false
	var alt_delta: float = absf(_step_to_alt - _step_from_alt)
	match kind:
		TileGrid.StepKind.LADDER:
			# Ladder height (in full cubes) = |altitude delta| / 2. Ladders are
			# validated to integer-cube heights, so this divides evenly; floats
			# are used only to tolerate any future sub-cube edges without
			# collapsing to zero. Clamp to >=1 so a degenerate 0-delta edge
			# still takes one climb step's worth of time.
			var cubes: float = maxf(alt_delta / 2.0, 1.0)
			_step_duration_effective = step_duration * climb_duration_multiplier * cubes
		TileGrid.StepKind.SCRAMBLE:
			# No-ladder ledge climb: scales with height, no clamp, so a half-step
			# ledge → 0.5 cube → 2× a step and a full cube → 4×. Double the cost
			# of climbing the same height on a ladder.
			_step_duration_effective = step_duration * scramble_duration_multiplier * (alt_delta / 2.0)
		TileGrid.StepKind.RAMP_SIDE:
			# Stepping onto/off a ramp from the side: flat 2× (same as a 1-cube
			# ladder), regardless of the sub-step change to the ramp center.
			_step_duration_effective = step_duration * climb_duration_multiplier
		_:
			_step_duration_effective = step_duration

	# Footstep SFX. Keyed on the DESTINATION cell — the surface being stepped
	# onto. FootstepAudio runs its own free-running footfall clock (a pace is
	# shorter than a tile), so this only refreshes the surface/interval; the
	# rhythm is not restarted per cell.
	if _footsteps != null:
		_footsteps.step_started(_pathfinder, next_cell, kind)

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
	var abs_frame: int = int(_walk_time * WALK_FPS)
	var walk_frame: int = abs_frame % WALK_FRAMES_PER_DIR
	_sprite.frame = _facing * WALK_FRAMES_PER_DIR + walk_frame
	_tick_footfalls(abs_frame)


# Fire a footstep for every foot contact the walk cycle has passed since the
# last call. `abs_frame` is the cycle-absolute frame index (not wrapped), so
# _contacts_total is monotonic while walking and a plain > comparison is enough
# — no edge-detection state to get wrong at cycle wrap or on a repeated call
# with the same _walk_time (_begin_next_step and _physics_process can both land
# on one).
func _tick_footfalls(abs_frame: int) -> void:
	if _footsteps == null:
		return
	var total := _contacts_total(abs_frame)
	if total <= _contacts_passed:
		return
	_contacts_passed = total
	_footsteps.footfall()


# Number of foot contacts at or before `abs_frame`. Counts whole cycles, then
# the contacts reached within the partial cycle. Reads WALK_CONTACT_FRAMES
# rather than assuming the contacts are evenly spaced, so re-authoring the
# sheet's contact frames is a one-line change with no other edits.
static func _contacts_total(abs_frame: int) -> int:
	if abs_frame < 0:
		return 0
	var total: int = (abs_frame / WALK_FRAMES_PER_DIR) * WALK_CONTACT_FRAMES.size()
	var within: int = abs_frame % WALK_FRAMES_PER_DIR
	for c: int in WALK_CONTACT_FRAMES:
		if c <= within:
			total += 1
	return total


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
	# Match the defensive nullcheck pattern used in `_ready` and
	# `_tick_shadow_cutoff` — a derived/test scene that wires a shadow without
	# a ShaderMaterial would otherwise crash here per-frame.
	var shadow_mat: ShaderMaterial = _shadow.material as ShaderMaterial
	if shadow_mat != null:
		shadow_mat.set_shader_parameter(&"visual_y_offset", _base_visual_y_offset + lift + 1.0)
	# Always cache the local target Y so the opening-pan _process loop can
	# read an up-to-date rest position even while we're not writing to the
	# camera (pan owns the camera transform during top_level mode).
	_camera_target_local_y = lift + _CAMERA_TARGET_OFFSET_Y
	if not _camera_panning:
		_camera.position.y = _camera_target_local_y
	_light.position.y = _base_sprite_offset_y + lift


func _push_shadow_cell_state() -> void:
	# Push per-cell roughness on cell-change. The cutoff target is recomputed
	# every tick in _tick_shadow_cutoff, so it doesn't belong here — leaving
	# it out keeps it from going stale when shadow_length drifts mid-cell.
	if _pathfinder == null or _shadow == null:
		return
	var mat := _shadow.material as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter(&"roughness", _pathfinder.roughness_at(current_cell))


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
	return _shadow_no_clip()


# Pixel extent the shadow currently reaches along its taper. Read live from
# the shader uniform every call because DayNightController drives
# shadow_length over the day cycle — caching at _ready would let cutoff_x
# fall behind as the shadow grows past the cached value.
func _shadow_no_clip() -> float:
	var mat := _shadow.material as ShaderMaterial if _shadow else null
	if mat == null:
		return 1000.0
	var slen_v: Variant = mat.get_shader_parameter(&"shadow_length")
	var capw_v: Variant = mat.get_shader_parameter(&"cap_width")
	var slen: float = absf(float(slen_v)) if slen_v != null else 0.0
	var capw: float = float(capw_v) if capw_v != null else 0.0
	return slen + capw + 1.0


# Slide _shadow_cutoff_current toward _shadow_cutoff_target at iso step speed
# and push the result. Called every physics frame from _physics_process so the
# shadow extends/retracts at the same pace as the player walks.
func _tick_shadow_cutoff(delta: float) -> void:
	if _shadow == null:
		return
	var mat := _shadow.material as ShaderMaterial
	if mat == null:
		return
	# Recompute the target every tick: shadow_length is animated by
	# DayNightController, so both the direction (sign) and the no-clip
	# extent change continuously. A one-shot push at step boundaries would
	# leave the target stale.
	var slen_v: Variant = mat.get_shader_parameter(&"shadow_length")
	var dir_sign: int = 1
	if (typeof(slen_v) == TYPE_FLOAT or typeof(slen_v) == TYPE_INT) and float(slen_v) < 0.0:
		dir_sign = -1
	if _pathfinder != null:
		var deltas: Vector3 = _pathfinder.shadow_altitude_deltas(current_cell, dir_sign)
		_shadow_cutoff_target = _cutoff_from_deltas(deltas)
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


# Pure night-window test. activate > deactivate means the active window wraps
# past midnight (e.g. dusk 0.75 → dawn 0.28). Static so it can be unit-tested
# without a Player instance (see tests/test_lantern_logic.gd).
static func is_night(t: float, activate: float, deactivate: float) -> bool:
	if activate > deactivate:
		return t >= activate or t < deactivate
	return t >= activate and t < deactivate


## The object currently in the player's hand (derived; see the held-item note).
## The lantern at night, nothing by day.
func held_item() -> StringName:
	var night := false
	if _time_manager != null:
		night = is_night(_time_manager.time_of_day, lantern_activate_time, lantern_deactivate_time)
	return ITEM_LANTERN if night else ITEM_NONE


# The lantern is lit iff it's the currently held item — i.e. it's night.
# Driven every physics frame.
func _update_lantern() -> void:
	if held_item() == ITEM_LANTERN:
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

# Called by ProceduralWorld AFTER it has positioned the player on its chosen
# spawn cell. The generator is the sole placement authority on procedural maps
# (it picks a grass-plateau center, not the authored node position), so this is
# what establishes current_cell, the altitude lift, the sort-Y, and the opening
# camera pan against the cell the generator actually moved the player to.
#
# Without this — or if the player's own self-placement (see _maybe_self_place)
# were allowed to win — global_position and current_cell would describe two
# DIFFERENT cells: the visual sits at the spawn while the logic thinks it's at
# the authored cell, giving a wrong altitude lift (renders behind tiles) and
# pathing from the wrong cell (can't move).
func snap_to_start() -> void:
	_snap_to_starting_cell()


## Point the opening camera pan's START at a grid cell (the summit lake). Called
## by the world generator (ProceduralWorld) before snap_to_start. The camera
## centers here and then pans straight down to the player.
func set_opening_pan_start_cell(cell: Vector2i) -> void:
	_opening_pan_start_cell = cell


# Deferred from _ready as the FALLBACK placement for non-procedural maps (test
# scenes, handcrafted levels) where the player's authored position is its spawn
# and no generator will call snap_to_start. On procedural maps ProceduralWorld
# calls defer_to_external_placement() before generating, which suppresses this
# so the generator's spawn pick is the only placement. The flag is read here at
# DEFERRED (idle) time, so it doesn't matter whether Player._ready or
# ProceduralWorld._ready ran first — the generator's claim always lands before
# this executes.
func _maybe_self_place() -> void:
	if _external_placement:
		return
	_snap_to_starting_cell()


## Claim placement authority. ProceduralWorld calls this before generating so
## the player's deferred self-placement stands down and waits for snap_to_start.
func defer_to_external_placement() -> void:
	_external_placement = true


func _snap_to_starting_cell() -> void:
	# Guard re-entrancy: once placed, ignore further calls so the camera pan
	# isn't set up twice.
	if _started:
		return
	if _pathfinder == null:
		return

	var start := _pathfinder.world_to_cell(global_position)
	if not _pathfinder.is_walkable(start):
		# Don't set _started — the grid may simply not be painted yet (async
		# startup). Leaving it false lets the ProceduralWorld-driven retry place
		# the player once the terrain exists.
		push_warning(
			"Player: starting position %s resolves to non-walkable cell %s. "
			% [global_position, start]
			+"Move the player node in the editor to a walkable cell."
		)
		return

	_started = true
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
	#
	# Pan parameters live on TitleIntro so designers tune them alongside the
	# intro timing. The lookup relies on Godot's deferred ordering: TitleIntro
	# adds itself to the group in _ready (sync) before any deferred free, and
	# this method is itself deferred from Player._ready, so the group entry is
	# always live when we read it. If TitleIntro is absent (test scenes), we
	# skip the pan entirely rather than guess a duration that drifts from the
	# intro's actual length.
	var intro := get_tree().get_first_node_in_group(&"title_intro") as TitleIntro
	if intro == null:
		_camera_panning = false
	else:
		var rest_world := _camera_pan_target_world()
		# Pan START pose: centered on the summit lake when the generator told us
		# where it is, else the old pose just above the player. From here the pan
		# only ever moves straight DOWN (X is held; the horizontal correction to
		# the player is hidden later by snap_camera_over_player()).
		var start_world: Vector2
		if _opening_pan_start_cell.x >= 0:
			start_world = _cell_camera_world(_opening_pan_start_cell)
		else:
			start_world = Vector2(rest_world.x, rest_world.y - intro.pan_offset_px)
		_camera_panning = true
		_pan_elapsed = 0.0
		_pan_duration = intro.get_pan_duration()
		_pan_eased_prev = 0.0
		_camera.position_smoothing_enabled = false
		_camera.top_level = true
		_camera.position = start_world
		# Hold the pan clock while the click-to-begin gate is up; TitleIntro
		# releases it via start_opening_pan() on the first click.
		_pan_running = not intro.is_awaiting_click()

	if debug_logging:
		print("Player: snapped to cell %s at altitude %s" % [current_cell, _altitude])


# Player's current rest position in world space. Used as the pan's moving
# target — if the player walks during the pan, the camera homes in on them
# wherever they end up. Y uses the cached local target (which already
# includes y_visual_diff compensation) so mid-step tile snaps don't bleed
# through.
func _camera_pan_target_world() -> Vector2:
	return Vector2(global_position.x, global_position.y + _camera_target_local_y)


# World position to center the camera on a cell, including its altitude lift
# (cell_to_world returns the altitude-0 origin; the visual surface sits
# alt*HALF_STEP_PX higher on screen). Used to aim the opening pan at the lake.
func _cell_camera_world(cell: Vector2i) -> Vector2:
	var w := _pathfinder.cell_to_world(cell)
	w.y -= _pathfinder.altitude_center(cell) * Pathfinder.HALF_STEP_PX
	return w


func _process(delta: float) -> void:
	if not _camera_panning or not _pan_running:
		return
	_pan_elapsed += delta
	# Straight-down pan: ease only the camera's Y toward the player's rest Y.
	# X is left untouched — it starts at the lake's X and is snapped to the
	# player's X by snap_camera_over_player() while the curtain is solid, so the
	# horizontal correction is never visible. All seen motion stays vertical.
	var target_y: float = _camera_pan_target_world().y
	if _pan_elapsed >= _pan_duration:
		_camera.position.y = target_y
		_finish_opening_pan()
		return
	var t: float = _pan_elapsed / _pan_duration
	# Sine ease-in/out: -0.5 * (cos(PI*t) - 1) ∈ [0, 1].
	var eased: float = -0.5 * (cos(PI * t) - 1.0)
	# Remaining-progress lerp factor. Equivalent to a fixed sine curve when
	# the target is static, but tracks a moving target smoothly because k
	# applies to the *current* gap, not a stale start point.
	var k: float = (eased - _pan_eased_prev) / maxf(1.0 - _pan_eased_prev, 0.0001)
	_camera.position.y = lerpf(_camera.position.y, target_y, k)
	_pan_eased_prev = eased


# Snap the camera's X directly over the player. Called by TitleIntro the instant
# the curtain is fully opaque, hiding the lake→player horizontal jump. The pan
# keeps easing Y down afterward, so all visible motion stays vertical.
func snap_camera_over_player() -> void:
	if not _camera_panning:
		return
	_camera.position.x = _camera_pan_target_world().x


# Release the opening pan clock. Called by TitleIntro when the player clicks
# through the "click to begin" gate so the pan begins exactly as the cinematic
# starts. No-op when there's no gate (the pan was already running).
func start_opening_pan() -> void:
	_pan_running = true


# Snap the opening pan to its endpoint and hand the camera back to player
# follow. Called by TitleIntro when the player skips the title card so the
# pan doesn't keep drifting after the curtain clears. No-op if the pan is
# not active (already finished or never started).
func finish_opening_pan_now() -> void:
	if not _camera_panning:
		return
	_camera.position = _camera_pan_target_world()
	_finish_opening_pan()


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
