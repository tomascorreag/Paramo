class_name UXOverlay
extends Node2D

## In-world isometric UX overlay. Tracks the mouse-hovered cell and renders
## three layered indicators on top of tiles:
##
##   - BaseX: 6-frame rotating X (16x16) follows the cursor on walkable cells.
##   - Circle: static circle (32x16) overlays BaseX when the cursor cell is
##     right-clickable (Chebyshev-adjacent to the player, walkable, unplanted).
##   - LockedSquare + LockedX: static square (32x16) + frame-0 X anchored at a
##     committed cell while the radial menu is open or a multi-click build mode
##     is active.
##
## During bridge build mode an extra pool of rotating Xs marks the closest
## valid orthogonal endpoints; hovering one hides the others.
##
## Setup:
##   1. Add a UXOverlay node to the scene (alongside Pathfinder).
##   2. Wire or auto-find Pathfinder + TileInteractionController.
##   3. UXOverlay expects child nodes: BaseX, Circle, LockedX, LockedSquare,
##      Candidates (Node2D container).
##
## Other systems can read `hovered_cell` or connect to `hovered_cell_changed`
## to react to hover (e.g. tooltip, tile info panel).

const GROUP_NAME: StringName = &"ux_overlay"

const _ROW_SQUARE := Rect2(0, 0, 32, 16)
const _ROW_CIRCLE := Rect2(0, 16, 32, 16)
const _ROW_CIRCLE_DIM := Rect2(32, 16, 32, 16)
const _X_FRAME_W := 16.0
const _X_FRAME_H := 16.0
const _X_ROW_Y := 32.0
const _X_FRAME_COUNT := 6
const _X_FPS := 8.0

enum State { HOVER, LOCKED, BRIDGE }


@export var pathfinder: Pathfinder
@export var tile_interaction_controller: TileInteractionController

@export var reticle_fade_duration: float = 0.1

## Emitted when the hovered cell changes. new_cell is Pathfinder.NO_CELL when
## the cursor leaves all walkable tiles.
signal hovered_cell_changed(new_cell: Vector2i, old_cell: Vector2i)

var hovered_cell: Vector2i = Pathfinder.NO_CELL

@onready var _base_x: Sprite2D = $BaseX
@onready var _circle: Sprite2D = $Circle
@onready var _locked_x: Sprite2D = $LockedX
@onready var _locked_square: Sprite2D = $LockedSquare
@onready var _candidates_root: Node2D = $Candidates

var _state: State = State.HOVER
var _locked_cell: Vector2i = Pathfinder.NO_CELL
var _candidate_cells: Array[Vector2i] = []
var _candidate_sprites: Array[Sprite2D] = []
var _is_valid_endpoint: Callable = Callable()

var _x_frame: int = 0
var _x_frame_timer: float = 0.0

var _base_x_tween: Tween
var _denied_tween: Tween


func _enter_tree() -> void:
	add_to_group(GROUP_NAME)


func _ready() -> void:
	if pathfinder == null:
		pathfinder = get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	if pathfinder == null:
		push_error("UXOverlay: no Pathfinder wired and none found in group '%s'." % Pathfinder.GROUP_NAME)
	if tile_interaction_controller == null:
		tile_interaction_controller = get_tree().get_first_node_in_group(
			TileInteractionController.GROUP_NAME
		) as TileInteractionController

	_locked_x.region_enabled = true
	_locked_x.region_rect = _x_frame_rect(0)
	_locked_square.region_enabled = true
	_locked_square.region_rect = _ROW_SQUARE
	_circle.region_enabled = true
	_circle.region_rect = _ROW_CIRCLE
	_base_x.region_enabled = true
	_base_x.region_rect = _x_frame_rect(0)

	_apply_state_visibility()


func _process(delta: float) -> void:
	_advance_x_animation(delta)

	match _state:
		State.LOCKED:
			# Mouse moves freely (to pick menu items) but no in-world cursor.
			if hovered_cell != Pathfinder.NO_CELL:
				var old := hovered_cell
				hovered_cell = Pathfinder.NO_CELL
				hovered_cell_changed.emit(hovered_cell, old)
		State.HOVER, State.BRIDGE:
			_update_cursor_cell()
			if _state == State.BRIDGE:
				_update_candidate_visibility()


# ---------------------------------------------------------------------------
# Public API — state transitions
# ---------------------------------------------------------------------------

func lock_at(cell: Vector2i) -> void:
	_locked_cell = cell
	_state = State.LOCKED
	_apply_state_visibility()


## Release LOCKED state. No-op while in BRIDGE so the radial menu's deferred
## `closed` signal can't interrupt a build mode that just started.
func unlock() -> void:
	if _state != State.LOCKED:
		return
	_state = State.HOVER
	_locked_cell = Pathfinder.NO_CELL
	_apply_state_visibility()


## `is_valid_endpoint` is a `Callable(Vector2i) -> bool` used to decide whether
## the hovered cell is a placeable endpoint. When hovering a valid endpoint,
## the cursor X shows there alone and all candidate hints hide; when hovering
## an invalid cell, the cursor X is hidden and all candidate hints stay visible.
func enter_bridge_mode(
	origin: Vector2i, candidates: Array[Vector2i], is_valid_endpoint: Callable = Callable()
) -> void:
	_locked_cell = origin
	_candidate_cells = candidates.duplicate()
	_is_valid_endpoint = is_valid_endpoint
	_state = State.BRIDGE
	_rebuild_candidate_sprites()
	_apply_state_visibility()


## Brief red flash on `cell` to signal a right-click had no applicable action.
## Uses the LockedX reticle so it visually matches the normal lock UX without
## actually entering LOCKED state. Ignored while already in LOCKED or BRIDGE.
func flash_denied(cell: Vector2i) -> void:
	if _state != State.HOVER:
		return
	if cell == Pathfinder.NO_CELL:
		return
	if _denied_tween and _denied_tween.is_valid():
		_denied_tween.kill()
	_locked_x.region_rect = _x_frame_rect(0)
	_locked_x.global_position = cell_visual_center(cell)
	_locked_x.modulate = Color(1.0, 0.3, 0.3, 1.0)
	_locked_x.visible = true
	_denied_tween = create_tween()
	_denied_tween.tween_property(_locked_x, "modulate:a", 0.0, 0.25)
	_denied_tween.tween_callback(func() -> void:
		_locked_x.visible = false
		_locked_x.modulate = Color.WHITE
	)


func exit_bridge_mode() -> void:
	if _state != State.BRIDGE:
		return
	_state = State.HOVER
	_locked_cell = Pathfinder.NO_CELL
	_candidate_cells.clear()
	_is_valid_endpoint = Callable()
	_clear_candidate_sprites()
	_apply_state_visibility()


# ---------------------------------------------------------------------------
# Cursor / hover
# ---------------------------------------------------------------------------

func _update_cursor_cell() -> void:
	var cell := _resolve_hovered_cell()
	if cell != hovered_cell:
		var old := hovered_cell
		hovered_cell = cell
		hovered_cell_changed.emit(cell, old)
		_refresh_base_x(old)
		_refresh_circle()


func _resolve_hovered_cell() -> Vector2i:
	if pathfinder == null:
		return Pathfinder.NO_CELL
	return pathfinder.resolve_click(_mouse_global_position())


func _refresh_base_x(_old_cell: Vector2i) -> void:
	_kill_base_x_tween()
	if hovered_cell == Pathfinder.NO_CELL:
		_base_x.modulate.a = 0.0
		return
	# In BRIDGE state, the cursor X only shows on cells that are valid bridge
	# endpoints. Invalid hovers stay blank so the cursor itself signals "no
	# placement here" without competing with the candidate hints.
	if _state == State.BRIDGE and not _is_hovered_endpoint_valid():
		_base_x.modulate.a = 0.0
		return
	_base_x.global_position = cell_visual_center(hovered_cell)
	_base_x.modulate.a = 0.0
	_base_x_tween = create_tween()
	_base_x_tween.tween_property(_base_x, "modulate:a", 1.0, reticle_fade_duration)


func _is_hovered_endpoint_valid() -> bool:
	if hovered_cell == Pathfinder.NO_CELL:
		return false
	if not _is_valid_endpoint.is_valid():
		return false
	return bool(_is_valid_endpoint.call(hovered_cell))


func _refresh_circle() -> void:
	if _state != State.HOVER or hovered_cell == Pathfinder.NO_CELL:
		_circle.visible = false
		return
	# Walkable + right-clickable → solid circle. Walkable but not right-clickable
	# → dim circle (signals "you can move here" without claiming interactivity).
	var interactable := (
		tile_interaction_controller != null
		and tile_interaction_controller.is_interactable(hovered_cell)
	)
	_circle.region_rect = _ROW_CIRCLE if interactable else _ROW_CIRCLE_DIM
	_circle.global_position = cell_visual_center(hovered_cell)
	_circle.visible = true


# ---------------------------------------------------------------------------
# Bridge candidate hints
# ---------------------------------------------------------------------------

func _rebuild_candidate_sprites() -> void:
	_clear_candidate_sprites()
	for cell in _candidate_cells:
		var s := Sprite2D.new()
		s.texture = _base_x.texture
		s.region_enabled = true
		s.region_rect = _x_frame_rect(_x_frame)
		_candidates_root.add_child(s)
		# global_position must be set AFTER add_child — otherwise Godot stores
		# the value as local (no parent transform yet) and the sprite ends up
		# offset by the parent chain once it's reparented.
		s.global_position = cell_visual_center(cell)
		_candidate_sprites.append(s)


func _clear_candidate_sprites() -> void:
	for s in _candidate_sprites:
		if is_instance_valid(s):
			s.queue_free()
	_candidate_sprites.clear()


## When the cursor is on any valid bridge endpoint (a 4-direction hint cell or
## any other valid endpoint reachable from origin), hide all candidate hints —
## the cursor X already marks the live target. Hints reappear only when the
## cursor is over an invalid cell (or off the grid).
func _update_candidate_visibility() -> void:
	var hide_all := _is_hovered_endpoint_valid()
	for s in _candidate_sprites:
		s.visible = not hide_all


# ---------------------------------------------------------------------------
# Animation
# ---------------------------------------------------------------------------

func _advance_x_animation(delta: float) -> void:
	_x_frame_timer += delta
	var interval := 1.0 / _X_FPS
	var advanced := false
	while _x_frame_timer >= interval:
		_x_frame_timer -= interval
		_x_frame = (_x_frame + 1) % _X_FRAME_COUNT
		advanced = true
	if not advanced:
		return
	var rect := _x_frame_rect(_x_frame)
	_base_x.region_rect = rect
	for s in _candidate_sprites:
		s.region_rect = rect


func _x_frame_rect(frame: int) -> Rect2:
	return Rect2(frame * _X_FRAME_W, _X_ROW_Y, _X_FRAME_W, _X_FRAME_H)


# ---------------------------------------------------------------------------
# Visibility application
# ---------------------------------------------------------------------------

func _apply_state_visibility() -> void:
	match _state:
		State.HOVER:
			_locked_x.visible = false
			_locked_square.visible = false
			_base_x.visible = true
			_refresh_circle()
		State.LOCKED:
			_anchor_locked(_locked_cell)
			_locked_x.visible = true
			_locked_square.visible = true
			_base_x.visible = false
			_circle.visible = false
			_kill_base_x_tween()
			_base_x.modulate.a = 0.0
		State.BRIDGE:
			_anchor_locked(_locked_cell)
			_locked_x.visible = true
			_locked_square.visible = true
			_base_x.visible = true
			_circle.visible = false


func _anchor_locked(cell: Vector2i) -> void:
	if cell == Pathfinder.NO_CELL:
		return
	var pos := cell_visual_center(cell)
	_locked_x.global_position = pos
	_locked_square.global_position = pos


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


func _kill_base_x_tween() -> void:
	if _base_x_tween != null and _base_x_tween.is_valid():
		_base_x_tween.kill()
		_base_x_tween = null
