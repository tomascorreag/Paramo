class_name TraversalPlacementController
extends Node

# ============================================================================
# TraversalPlacementController
# ============================================================================
#
# Second-click placement mode for traversal structures. Invoked by
# TileInteractionController once the player picks a traversal kind from the
# radial menu. Enters AWAITING_ENDPOINT; the next left-click resolves the far
# endpoint, validates, and (on success) instantiates & builds the traversal.
# Right-click or Escape cancels.
#
# This node should sit BEFORE TileInteractionController in the scene tree so
# its `_unhandled_input` runs first while placement mode is active.
#
# ============================================================================


const GROUP_NAME: StringName = &"traversal_placement_controller"


enum Mode { IDLE, AWAITING_ENDPOINT }


@export var pathfinder: Pathfinder
@export var structure_layer_manager: StructureLayerManager
@export var world: Node2D
@export var ux_overlay: Node2D
@export var bridge_scene: PackedScene


var _mode: Mode = Mode.IDLE
var _origin_cell: Vector2i
var _traversal_kind: StringName = &""
var _placer: StructurePlacer
var _preview_placer: StructurePlacer
var _preview_cells: Array[Dictionary] = []
var _preview_hover_cell: Vector2i = Pathfinder.NO_CELL
var _preview_valid: bool = false
var _blocked_cells: Dictionary = {}
var _traversals: Array[Traversal] = []


func _enter_tree() -> void:
	add_to_group(GROUP_NAME)


func _ready() -> void:
	if pathfinder == null:
		pathfinder = get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	if structure_layer_manager == null:
		structure_layer_manager = get_tree().get_first_node_in_group(
			StructureLayerManager.GROUP_NAME
		) as StructureLayerManager
	if bridge_scene == null:
		bridge_scene = load("res://scenes/traversals/bridge.tscn")


# ----------------------------------------------------------------------------
# Public API
# ----------------------------------------------------------------------------

func begin(origin: Vector2i, kind: StringName) -> void:
	if pathfinder == null or structure_layer_manager == null:
		push_error("TraversalPlacementController.begin(): dependencies not wired.")
		return
	_origin_cell = origin
	_traversal_kind = kind
	_mode = Mode.AWAITING_ENDPOINT
	_preview_hover_cell = Pathfinder.NO_CELL
	_blocked_cells = _gather_blocked_cells()
	if ux_overlay:
		var candidates: Array[Vector2i] = []
		var is_valid_endpoint := Callable()
		match kind:
			&"bridge":
				candidates = Bridge.find_candidates(
					origin, pathfinder.grid(), 20, _blocked_cells
				)
				var blocked := _blocked_cells
				is_valid_endpoint = func(cell: Vector2i) -> bool:
					return Bridge.validate(
						origin, cell, pathfinder.grid(), blocked
					) == Bridge.Result.OK
		ux_overlay.enter_bridge_mode(origin, candidates, is_valid_endpoint)


# Snapshot the cells occupied by the player and any planted objects. Snapshot
# is fine because input is gated during placement: the player can't start a
# new movement and can't plant during a build.
func _gather_blocked_cells() -> Dictionary:
	var blocked: Dictionary = {}
	var tic := get_tree().get_first_node_in_group(
		TileInteractionController.GROUP_NAME
	) as TileInteractionController
	if tic != null:
		for cell in tic.planted_cells().keys():
			blocked[cell] = true
	var p := get_tree().get_first_node_in_group(&"player") as Player
	if p != null:
		blocked[p.current_cell] = true
	return blocked


func cancel() -> void:
	_clear_preview()
	if structure_layer_manager != null:
		structure_layer_manager.reset_preview_tint()
	_mode = Mode.IDLE
	_traversal_kind = &""
	_preview_hover_cell = Pathfinder.NO_CELL
	_preview_valid = false
	_blocked_cells = {}
	if ux_overlay:
		ux_overlay.exit_bridge_mode()


func is_placing() -> bool:
	return _mode == Mode.AWAITING_ENDPOINT


# ----------------------------------------------------------------------------
# Preview (ghost bridge following the cursor between first and second click)
# ----------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if _mode != Mode.AWAITING_ENDPOINT:
		return
	if pathfinder == null:
		return
	var hover := _resolve_hover_at_origin_altitude()
	if hover == _preview_hover_cell:
		return
	_preview_hover_cell = hover
	_refresh_preview(hover)


# Project the cursor onto the origin cell's altitude plane. Unlike
# `pathfinder.resolve_click`, this returns a cell coordinate regardless of
# walkability — so the preview can show (in red) over water, voids, or any
# other invalid endpoint the player might aim at.
func _resolve_hover_at_origin_altitude() -> Vector2i:
	var origin_tile := pathfinder.grid().get_tile(_origin_cell)
	var alt: int = origin_tile.altitude_low if origin_tile != null else 0
	var adjusted := _mouse_global_position() + Vector2(0.0, alt * Pathfinder.HALF_STEP_PX)
	return pathfinder.world_to_cell(adjusted)


func _refresh_preview(hover: Vector2i) -> void:
	_clear_preview()
	_preview_valid = false
	if hover == Pathfinder.NO_CELL:
		return
	match _traversal_kind:
		&"bridge":
			_paint_bridge_preview(hover)


func _paint_bridge_preview(hover: Vector2i) -> void:
	var placer := _ensure_preview_placer()
	if placer == null:
		return
	var origin_tile := pathfinder.grid().get_tile(_origin_cell)
	var base_alt: int = origin_tile.altitude_low if origin_tile != null else 0
	var plan := Bridge.plan_tiles(_origin_cell, hover, base_alt)
	if plan.is_empty():
		return  # non-orthogonal or same cell — show no ghost at all
	for entry in plan:
		if placer.paint(entry["cell"], entry["kind"], entry["altitude"]):
			_preview_cells.append(entry)
	var result := Bridge.validate(_origin_cell, hover, pathfinder.grid(), _blocked_cells)
	_preview_valid = result == Bridge.Result.OK
	if _preview_valid:
		structure_layer_manager.set_preview_valid()
	else:
		structure_layer_manager.set_preview_invalid()


func _clear_preview() -> void:
	if _preview_cells.is_empty():
		return
	var placer := _ensure_preview_placer()
	if placer == null:
		_preview_cells.clear()
		return
	for entry in _preview_cells:
		placer.erase(entry["cell"], entry["altitude"])
	_preview_cells.clear()


func _ensure_preview_placer() -> StructurePlacer:
	if _preview_placer == null and structure_layer_manager != null:
		_preview_placer = StructurePlacer.new(structure_layer_manager, true)
	return _preview_placer


func _mouse_global_position() -> Vector2:
	var viewport := get_viewport()
	var canvas_xform := viewport.get_canvas_transform()
	return canvas_xform.affine_inverse() * viewport.get_mouse_position()


# ----------------------------------------------------------------------------
# Input
# ----------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if _mode != Mode.AWAITING_ENDPOINT:
		return

	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and k.keycode == KEY_ESCAPE:
			cancel()
			get_viewport().set_input_as_handled()
		return

	if not (event is InputEventMouseButton):
		return

	var mb := event as InputEventMouseButton
	if not mb.pressed:
		return

	if mb.button_index == MOUSE_BUTTON_RIGHT:
		cancel()
		get_viewport().set_input_as_handled()
		return

	if mb.button_index != MOUSE_BUTTON_LEFT:
		return

	var global_pos := _event_global_position(mb)
	var far_cell := pathfinder.resolve_click(global_pos)
	get_viewport().set_input_as_handled()

	# Invalid click (unresolved cell or a painted-but-invalid preview): flash
	# the preview red and stay in placement mode so the player can re-aim.
	if far_cell == Pathfinder.NO_CELL or not _preview_valid:
		if not _preview_cells.is_empty():
			structure_layer_manager.flash_invalid()
		return

	match _traversal_kind:
		&"bridge":
			_place_bridge(far_cell)
		_:
			push_warning("Traversal placement: unknown kind '%s'." % _traversal_kind)
			cancel()


# ----------------------------------------------------------------------------
# Kind-specific placement
# ----------------------------------------------------------------------------

func _place_bridge(far_cell: Vector2i) -> void:
	# Re-gather just before placing so a player who slid into a deck cell
	# during the brief preview window still blocks placement.
	_blocked_cells = _gather_blocked_cells()
	var result: int = Bridge.validate(_origin_cell, far_cell, pathfinder.grid(), _blocked_cells)
	if result != Bridge.Result.OK:
		push_warning(
			"Bridge placement rejected: %s (origin=%s, far=%s)."
			% [Bridge.result_name(result), _origin_cell, far_cell]
		)
		cancel()
		return

	if _placer == null:
		_placer = StructurePlacer.new(structure_layer_manager)

	var origin_tile := pathfinder.grid().get_tile(_origin_cell)
	var base_alt: int = origin_tile.altitude_low if origin_tile != null else 0

	var inst: Bridge = bridge_scene.instantiate()
	world.add_child(inst)
	Bridge.configure(inst, _origin_cell, far_cell, base_alt, _placer, pathfinder)
	inst.build()
	_traversals.append(inst)

	cancel()


# ----------------------------------------------------------------------------
# Removal
# ----------------------------------------------------------------------------

## Returns the Traversal whose painted cells cover `cell`, or null.
func find_traversal_at(cell: Vector2i) -> Traversal:
	for t in _traversals:
		if not is_instance_valid(t):
			continue
		for entry in t.painted_cells():
			if entry["cell"] == cell:
				return t
	return null


## Erase a traversal's tiles, free its node, and rebuild pathfinding.
func remove_traversal(t: Traversal) -> void:
	if t == null or not is_instance_valid(t):
		return
	if _placer == null:
		_placer = StructurePlacer.new(structure_layer_manager)
	t.despawn(_placer)
	_traversals.erase(t)
	if pathfinder:
		pathfinder.rebuild()


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

func _event_global_position(mb: InputEventMouseButton) -> Vector2:
	var viewport := get_viewport()
	var canvas_xform := viewport.get_canvas_transform()
	return canvas_xform.affine_inverse() * mb.position
