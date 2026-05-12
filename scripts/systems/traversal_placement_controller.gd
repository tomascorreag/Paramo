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
@export var ladder_scene: PackedScene
## When true, prints a one-line diagnostic on every left-click during
## placement: the resolved cell, hover cell, preview-valid state, and the
## specific Ladder/Bridge validate Result for the click target. Cheap but
## spammy — leave off in normal play.
@export var debug_logging: bool = false


var _mode: Mode = Mode.IDLE
var _origin_cell: Vector2i
var _traversal_kind: StringName = &""
var _placer: StructurePlacer
var _preview_placer: StructurePlacer
var _preview_cells: Array[Dictionary] = []
var _preview_hover_cell: Vector2i = Pathfinder.NO_CELL
var _preview_valid: bool = false
var _blocked_cells: Dictionary = {}
var _tile_interaction: TileInteractionController
var _player: Player

# Kinds that count as "occupied" for new placement validation. Order doesn't
# matter — _gather_blocked_cells unions them all into the blocked dict.
const _BLOCKING_KINDS: Array[StringName] = [
	&"frailejon", &"bridge_deck", &"ladder", &"rock"
]


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
	if ladder_scene == null:
		ladder_scene = load("res://scenes/traversals/ladder.tscn")
	_tile_interaction = get_tree().get_first_node_in_group(
		TileInteractionController.GROUP_NAME
	) as TileInteractionController
	_player = get_tree().get_first_node_in_group(&"player") as Player


# ----------------------------------------------------------------------------
# Public API
# ----------------------------------------------------------------------------

func begin(origin: Vector2i, kind: StringName) -> void:
	if pathfinder == null or structure_layer_manager == null:
		push_error("TraversalPlacementController.begin(): dependencies not wired.")
		return
	var grid := _require_grid()
	if grid == null:
		return
	_origin_cell = origin
	_traversal_kind = kind
	_mode = Mode.AWAITING_ENDPOINT
	_preview_hover_cell = Pathfinder.NO_CELL
	_blocked_cells = _gather_blocked_cells()
	if ux_overlay:
		var candidates: Array[Vector2i] = []
		var is_valid_endpoint := Callable()
		var pcell: Vector2i = _player.current_cell if _player != null else Pathfinder.NO_CELL
		match kind:
			&"bridge":
				candidates = Bridge.find_candidates(
					origin, grid, Bridge.MAX_LENGTH, _blocked_cells, pcell
				)
				var blocked := _blocked_cells
				is_valid_endpoint = func(cell: Vector2i) -> bool:
					var g := _require_grid()
					return g != null and Bridge.validate(
						origin, cell, g, blocked, Bridge.MAX_LENGTH, pcell
					) == Bridge.Result.OK
			&"ladder":
				candidates = Ladder.find_candidates(
					origin, grid, Ladder.MAX_HEIGHT_CUBES, _blocked_cells
				)
				var blocked_l := _blocked_cells
				is_valid_endpoint = func(cell: Vector2i) -> bool:
					var g := _require_grid()
					return g != null and Ladder.validate(
						origin, cell, g, blocked_l
					) == Ladder.Result.OK
		ux_overlay.enter_placement_mode(origin, candidates, is_valid_endpoint)


# Returns the current Pathfinder grid, or null (with a single warning per
# session) when it isn't built. Every callsite that dereferences the grid
# (get_tile, resolve_click) routes through here instead of calling
# pathfinder.grid() directly, so a late / failed rebuild doesn't crash the
# placement UI.
func _require_grid() -> TileGrid:
	if pathfinder == null:
		return null
	var g := pathfinder.grid()
	if g == null:
		push_warning("TraversalPlacementController: pathfinder grid is null — cannot proceed.")
	return g


# Snapshot the cells claimed by all known occupant kinds. Snapshot is fine
# because input is gated during placement: the player can't start a new
# movement and can't plant during a build.
#
# Reads from the unified occupant registry on TileGrid: frailejones,
# bridges, ladders, and rocks all register their cells, so a single pass
# over `occupants_of_kind` per blocking kind covers every claim. This is
# broader than is_walkable's check (frailejones don't block movement but DO
# block placement of new structures on their cell).
#
# The player's own cell is NOT included here — build validators treat the
# player's cell separately via `player_cell`, which blocks INTERIOR-only
# crossings for bridges and is ignored for ladders (where it may be an
# endpoint). This lets the player attach a traversal to the cell they stand
# on without stranding themselves.
func _gather_blocked_cells() -> Dictionary:
	var blocked: Dictionary = {}
	var grid := _require_grid()
	if grid == null:
		return blocked
	for kind in _BLOCKING_KINDS:
		for cell in grid.occupants_of_kind(kind).keys():
			blocked[cell] = true
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
		ux_overlay.exit_placement_mode()


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
	var hover := _resolve_preview_hover_cell()
	if hover == _preview_hover_cell:
		return
	_preview_hover_cell = hover
	_refresh_preview(hover)


# Preview hover cell, chosen per traversal kind:
#   bridge — project cursor onto origin's altitude plane. Returns a cell
#     regardless of walkability so the preview can turn red over water /
#     voids / non-walkable endpoints.
#   ladder — use `pathfinder.resolve_click`, the same resolver the commit
#     click path uses, so preview target == click target. Ladder endpoints
#     live on a different altitude than the origin, so the origin-plane
#     projection used by bridges would resolve to the wrong cell.
func _resolve_preview_hover_cell() -> Vector2i:
	match _traversal_kind:
		&"ladder":
			return pathfinder.resolve_click(_mouse_global_position())
		_:
			return _resolve_hover_at_origin_altitude()


func _resolve_hover_at_origin_altitude() -> Vector2i:
	var grid := _require_grid()
	var origin_tile: CellData = null
	if grid != null:
		origin_tile = grid.get_tile(_origin_cell)
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
		&"ladder":
			_paint_ladder_preview(hover)


func _paint_bridge_preview(hover: Vector2i) -> void:
	var placer := _ensure_preview_placer()
	if placer == null:
		return
	var grid := _require_grid()
	if grid == null:
		return
	var origin_tile := grid.get_tile(_origin_cell)
	var base_alt: int = origin_tile.altitude_low if origin_tile != null else 0
	var plan := Bridge.plan_tiles(_origin_cell, hover, base_alt)
	if plan.is_empty():
		return  # non-orthogonal or same cell — show no ghost at all
	for entry in plan:
		if placer.paint(entry["cell"], entry["kind"], entry["altitude"]):
			_preview_cells.append(entry)
	var pcell: Vector2i = _player.current_cell if _player != null else Pathfinder.NO_CELL
	var result := Bridge.validate(
		_origin_cell, hover, grid, _blocked_cells, Bridge.MAX_LENGTH, pcell
	)
	_preview_valid = result == Bridge.Result.OK
	if _preview_valid:
		structure_layer_manager.set_preview_valid()
	else:
		structure_layer_manager.set_preview_invalid()


func _paint_ladder_preview(hover: Vector2i) -> void:
	var placer := _ensure_preview_placer()
	if placer == null:
		return
	var grid := _require_grid()
	if grid == null:
		return
	var origin_tile := grid.get_tile(_origin_cell)
	var base_alt: int = origin_tile.altitude_low if origin_tile != null else 0
	var top_tile := grid.get_tile(hover)
	# Without a resolvable top tile we can't decide an altitude — skip ghost.
	if top_tile == null:
		return
	var top_alt: int = top_tile.altitude_low
	var plan := Ladder.plan_tiles(_origin_cell, hover, base_alt, top_alt)
	if plan.is_empty():
		return
	for entry in plan:
		if placer.paint(entry["cell"], entry["kind"], entry["altitude"]):
			_preview_cells.append(entry)
	var result := Ladder.validate(_origin_cell, hover, grid, _blocked_cells)
	_preview_valid = result == Ladder.Result.OK
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

	if debug_logging:
		_log_click_diagnostic(far_cell)

	# Invalid click (unresolved cell or a painted-but-invalid preview): flash
	# the preview red and stay in placement mode so the player can re-aim.
	if far_cell == Pathfinder.NO_CELL or not _preview_valid:
		if not _preview_cells.is_empty():
			structure_layer_manager.flash_invalid()
		return

	match _traversal_kind:
		&"bridge":
			_place_bridge(far_cell)
		&"ladder":
			_place_ladder(far_cell)
		_:
			push_warning("Traversal placement: unknown kind '%s'." % _traversal_kind)
			cancel()


# ----------------------------------------------------------------------------
# Kind-specific placement
# ----------------------------------------------------------------------------

func _place_bridge(far_cell: Vector2i) -> void:
	var grid := _require_grid()
	if grid == null:
		cancel()
		return
	# Re-gather just before placing so a player who slid into a deck cell
	# during the brief preview window still blocks placement.
	_blocked_cells = _gather_blocked_cells()
	var pcell: Vector2i = _player.current_cell if _player != null else Pathfinder.NO_CELL
	var result: int = Bridge.validate(
		_origin_cell, far_cell, grid, _blocked_cells, Bridge.MAX_LENGTH, pcell
	)
	if result != Bridge.Result.OK:
		push_warning(
			"Bridge placement rejected: %s (origin=%s, far=%s)."
			% [Bridge.result_name(result), _origin_cell, far_cell]
		)
		cancel()
		return

	if _placer == null:
		_placer = StructurePlacer.new(structure_layer_manager)

	var origin_tile := grid.get_tile(_origin_cell)
	var base_alt: int = origin_tile.altitude_low if origin_tile != null else 0

	var inst: Bridge = bridge_scene.instantiate()
	world.add_child(inst)
	Bridge.configure(inst, _origin_cell, far_cell, base_alt, _placer, pathfinder)
	if not inst.build():
		# build() rolls back its own paint state and leaves no traversal edge;
		# just drop the node so we don't accumulate orphans. Successful builds
		# self-register on the occupant registry — no controller-side tracking
		# needed.
		inst.queue_free()

	cancel()


func _place_ladder(target_cell: Vector2i) -> void:
	var grid := _require_grid()
	if grid == null:
		cancel()
		return
	# Re-gather occupancy just before commit (parity with bridge).
	_blocked_cells = _gather_blocked_cells()
	var result: int = Ladder.validate(_origin_cell, target_cell, grid, _blocked_cells)
	if result != Ladder.Result.OK:
		push_warning(
			"Ladder placement rejected: %s (origin=%s, target=%s)."
			% [Ladder.result_name(result), _origin_cell, target_cell]
		)
		cancel()
		return

	if _placer == null:
		_placer = StructurePlacer.new(structure_layer_manager)

	# Canonicalize to Ladder's internal contract: origin_cell = lower floor,
	# top_cell = upper floor. The first-click (`_origin_cell`) may be either
	# end — top-down builds clicked the upper floor first.
	var a_tile := grid.get_tile(_origin_cell)
	var b_tile := grid.get_tile(target_cell)
	var lower_cell: Vector2i = _origin_cell
	var upper_cell: Vector2i = target_cell
	var base_alt: int = a_tile.altitude_low
	if b_tile.altitude_low < a_tile.altitude_low:
		lower_cell = target_cell
		upper_cell = _origin_cell
		base_alt = b_tile.altitude_low

	var inst: Ladder = ladder_scene.instantiate()
	world.add_child(inst)
	Ladder.configure(inst, lower_cell, upper_cell, base_alt, _placer, pathfinder)
	if not inst.build():
		# Successful builds self-register; only failures need cleanup.
		inst.queue_free()

	cancel()


# ----------------------------------------------------------------------------
# Removal
# ----------------------------------------------------------------------------

## Returns the Traversal whose claimed cells cover `cell`, or null. Single
## dict lookup against the unified occupant registry — Bridge claims every
## painted cell, Ladder claims origin and top.
func find_traversal_at(cell: Vector2i) -> Traversal:
	var grid := _require_grid()
	if grid == null:
		return null
	var occ := grid.occupant_at(cell)
	if occ is Traversal:
		return occ as Traversal
	return null


## Erase a traversal's tiles, free its node, and rebuild pathfinding.
## Traversal.despawn clears its own occupant claims before freeing.
func remove_traversal(t: Traversal) -> void:
	if t == null or not is_instance_valid(t):
		return
	if _placer == null:
		_placer = StructurePlacer.new(structure_layer_manager)
	t.despawn(_placer)
	if pathfinder:
		pathfinder.rebuild()


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

func _event_global_position(mb: InputEventMouseButton) -> Vector2:
	var viewport := get_viewport()
	var canvas_xform := viewport.get_canvas_transform()
	return canvas_xform.affine_inverse() * mb.position


# Print why a second-click would fail. Called from _unhandled_input before the
# preview-valid gate, so the user sees a specific rejection reason rather than
# just a red flash.
func _log_click_diagnostic(far_cell: Vector2i) -> void:
	var hover_alt_cell := _resolve_hover_at_origin_altitude()
	var grid := _require_grid()
	if grid == null:
		return
	var origin_tile := grid.get_tile(_origin_cell)
	var base_alt: int = origin_tile.altitude_low if origin_tile != null else 0
	var target_tile := grid.get_tile(far_cell) if far_cell != Pathfinder.NO_CELL else null
	var target_alt_str: String = "-"
	if target_tile != null:
		target_alt_str = "%d..%d" % [target_tile.altitude_low, target_tile.altitude_high]

	var reason := "n/a"
	var pcell: Vector2i = _player.current_cell if _player != null else Pathfinder.NO_CELL
	match _traversal_kind:
		&"bridge":
			if far_cell == Pathfinder.NO_CELL:
				reason = "NO_CELL (click off grid)"
			else:
				reason = Bridge.result_name(Bridge.validate(
					_origin_cell, far_cell, grid, _blocked_cells, Bridge.MAX_LENGTH, pcell))
		&"ladder":
			if far_cell == Pathfinder.NO_CELL:
				reason = "NO_CELL (click off grid)"
			else:
				reason = Ladder.result_name(Ladder.validate(
					_origin_cell, far_cell, grid, _blocked_cells))

	print("[TPC] kind=%s origin=%s base_alt=%d click_cell=%s target_alt=%s hover_cell=%s preview_valid=%s -> %s" % [
		_traversal_kind, _origin_cell, base_alt, far_cell,
		target_alt_str, hover_alt_cell, _preview_valid, reason,
	])
