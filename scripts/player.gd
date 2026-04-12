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


const FRAME_SW: int = 0
const FRAME_SE: int = 1
const FRAME_NE: int = 2
const FRAME_NW: int = 3

# Grid-axis step direction -> sprite frame. Keys cover the 4 legal path
# transitions. Any other direction is a bug in the pathfinder.
const DIR_TO_FRAME: Dictionary = {
	Vector2i( 0,  1): FRAME_SW,  # step toward SW (down-left on screen)
	Vector2i( 1,  0): FRAME_SE,  # step toward SE (down-right on screen)
	Vector2i( 0, -1): FRAME_NE,  # step toward NE (up-right on screen)
	Vector2i(-1,  0): FRAME_NW,  # step toward NW (up-left on screen)
}


@export var step_duration: float = 0.3
@export var debug_logging: bool = false


@onready var _sprite: Sprite2D = $Sprite2D
@onready var _shadow: Sprite2D = $Shadow
@onready var _camera: Camera2D = $Camera2D

# Base sprite offset from the scene (feet-to-center). Altitude lift is added
# on top of this so the visual shifts up while global_position stays at
# ground level for Y-sort.
var _base_sprite_offset_y: float

var _pathfinder: Pathfinder

var current_cell: Vector2i = Vector2i.ZERO

# Step state. _stepping == true iff we're mid-lerp between two cells.
var _stepping: bool = false
var _step_from_cell: Vector2i
var _step_to_cell: Vector2i
var _step_from_alt: float = 0.0
var _step_to_alt: float = 0.0
var _step_t: float = 0.0

# Queued future destinations (excluding the step currently in progress).
var _path: Array[Vector2i] = []

# Current altitude in half-steps (float so half ramps render smoothly).
var _altitude: float = 0.0


func _enter_tree() -> void:
	add_to_group(&"player")


func _exit_tree() -> void:
	if is_instance_valid(_shadow):
		_shadow.queue_free()


func _ready() -> void:
	_base_sprite_offset_y = _sprite.offset.y

	# Reparent shadow to world level so it y-sorts independently against tiles.
	remove_child(_shadow)
	get_parent().add_child.call_deferred(_shadow)

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
	if _pathfinder == null:
		return

	if _stepping:
		_step_t += delta / step_duration
		if _step_t >= 1.0:
			_finish_step()
		else:
			_apply_step_interp(_step_t)
		return

	if not _path.is_empty():
		_begin_next_step()


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

	# Commit the "logical" cell now: future pathfinds will plan from
	# _step_to_cell, not from the cell we're leaving. This lets reclicks
	# mid-step produce paths from the cell the player is committed to
	# reaching, which is the only sensible anchor point.
	current_cell = next_cell

	_set_facing(dir)
	_apply_step_interp(0.0)


func _finish_step() -> void:
	_stepping = false
	_altitude = _step_to_alt
	_apply_position(_step_to_cell, _altitude)


func _apply_step_interp(t: float) -> void:
	var clamped := clampf(t, 0.0, 1.0)
	var from_world := _pathfinder.cell_to_world(_step_from_cell)
	var to_world := _pathfinder.cell_to_world(_step_to_cell)
	var pos := from_world.lerp(to_world, clamped)
	var alt: float = lerpf(_step_from_alt, _step_to_alt, clamped)
	_altitude = alt
	# Snap sort-Y to the southernmost (max Y) of origin/destination so the
	# player stays in front of both tiles throughout the step.
	var snap_y := maxf(from_world.y, to_world.y)
	global_position = Vector2(pos.x, snap_y) + Pathfinder.VISUAL_SURFACE_OFFSET + Vector2(0.0, _SORT_OFFSET)
	# Compensate the Y snap on sprite/camera so movement looks smooth.
	_apply_visual_lift(alt, pos.y - snap_y)


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
const _SORT_OFFSET: float = -15.0  # tile_y_sort_origin(-16) + 1


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
	_shadow.material.set_shader_parameter(&"visual_y_offset", lift + 1.0)
	_camera.position.y = lift


func _set_facing(dir: Vector2i) -> void:
	if not DIR_TO_FRAME.has(dir):
		return
	var f: int = DIR_TO_FRAME[dir]
	_sprite.frame = f
	_shadow.frame = f


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
			+ "Move the player node in the editor to a walkable cell."
		)
		return

	current_cell = start
	_altitude = _pathfinder.altitude_center(start)
	_apply_position(current_cell, _altitude)
	if debug_logging:
		print("Player: snapped to cell %s at altitude %s" % [current_cell, _altitude])
