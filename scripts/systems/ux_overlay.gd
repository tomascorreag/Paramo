class_name UXOverlay
extends Node2D

## In-world isometric UX overlay. Tracks the mouse-hovered cell and manages
## visual UX elements (reticle, path preview, placement indicators, etc.).
##
## Setup:
##   1. Add a UXOverlay node to the scene (alongside Pathfinder).
##   2. Wire or auto-find the Pathfinder (group "pathfinder").
##   3. Add UX element children (Reticle Sprite2D is the first).
##
## Other systems can read `hovered_cell` or connect to `hovered_cell_changed`
## to react to hover (e.g. tooltip, tile info panel).

const GROUP_NAME: StringName = &"ux_overlay"

@export var pathfinder: Pathfinder

## Emitted when the hovered cell changes. new_cell is Pathfinder.NO_CELL when
## the cursor leaves all walkable tiles.
signal hovered_cell_changed(new_cell: Vector2i, old_cell: Vector2i)

var hovered_cell: Vector2i = Pathfinder.NO_CELL
var suspended: bool = false

@export var reticle_fade_duration: float = 0.1

@onready var _reticle: Sprite2D = $Reticle
var _reticle_tween: Tween

const _RETICLE_FPS: float = 4.0
const _RETICLE_FRAME_SIZE := Vector2(32.0, 16.0)
var _reticle_frame: int = 0
var _reticle_frame_timer: float = 0.0


func _enter_tree() -> void:
	add_to_group(GROUP_NAME)


func _ready() -> void:
	if pathfinder == null:
		pathfinder = get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	if pathfinder == null:
		push_error("UXOverlay: no Pathfinder wired and none found in group '%s'." % Pathfinder.GROUP_NAME)
	_reticle.modulate.a = 0.0
	_reticle.visible = true


func _process(_delta: float) -> void:
	if suspended:
		if hovered_cell != Pathfinder.NO_CELL:
			var old := hovered_cell
			hovered_cell = Pathfinder.NO_CELL
			hovered_cell_changed.emit(hovered_cell, old)
			_update_reticle(old)
		return

	var cell := _resolve_hovered_cell()
	if cell != hovered_cell:
		var old := hovered_cell
		hovered_cell = cell
		hovered_cell_changed.emit(cell, old)
		_update_reticle(old)

	_animate_reticle(_delta)


# ---------------------------------------------------------------------------
# Hover resolution
# ---------------------------------------------------------------------------

func _resolve_hovered_cell() -> Vector2i:
	if pathfinder == null:
		return Pathfinder.NO_CELL
	return pathfinder.resolve_click(_mouse_global_position())


# ---------------------------------------------------------------------------
# Reticle
# ---------------------------------------------------------------------------

func _update_reticle(old_cell: Vector2i) -> void:
	_kill_reticle_tween()

	if hovered_cell == Pathfinder.NO_CELL:
		_reticle.modulate.a = 0.0
		return

	_reticle.global_position = cell_visual_center(hovered_cell)
	_reticle.modulate.a = 0.0
	_reticle_tween = create_tween()
	_reticle_tween.tween_property(_reticle, "modulate:a", 1.0, reticle_fade_duration)


func _animate_reticle(delta: float) -> void:
	_reticle_frame_timer += delta
	var interval := 1.0 / _RETICLE_FPS
	if _reticle_frame_timer >= interval:
		_reticle_frame_timer -= interval
		_reticle_frame = (_reticle_frame + 1) % 6
		_reticle.region_rect = Rect2(
			_reticle_frame * _RETICLE_FRAME_SIZE.x, _RETICLE_FRAME_SIZE.y,
			_RETICLE_FRAME_SIZE.x, _RETICLE_FRAME_SIZE.y
		)


func _kill_reticle_tween() -> void:
	if _reticle_tween != null and _reticle_tween.is_valid():
		_reticle_tween.kill()
		_reticle_tween = null


# ---------------------------------------------------------------------------
# Shared utilities — use these for future UX elements
# ---------------------------------------------------------------------------

## Global position of a cell's visual surface center, accounting for altitude.
func cell_visual_center(cell: Vector2i) -> Vector2:
	var world_pos := pathfinder.cell_to_world(cell)
	var alt := pathfinder.altitude_center(cell)
	return world_pos + Vector2(0.0, -alt * Pathfinder.HALF_STEP_PX)


func _mouse_global_position() -> Vector2:
	var viewport := get_viewport()
	var canvas_xform := viewport.get_canvas_transform()
	return canvas_xform.affine_inverse() * viewport.get_mouse_position()
