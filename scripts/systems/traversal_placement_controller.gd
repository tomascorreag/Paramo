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


## The second click opened: `kind` is awaiting its endpoint.
signal placement_began(kind: StringName)
## The second click closed. `built` separates a finished structure from an
## abandoned one, which nothing else can: `cancel()` is the single teardown for
## success, cancellation and rejection alike, so a listener watching it alone
## would see a completed ladder and a right-click escape as the same event.
signal placement_ended(kind: StringName, built: bool)


enum Mode { IDLE, AWAITING_ENDPOINT }


@export var pathfinder: Pathfinder
@export var structure_layer_manager: StructureLayerManager
@export var world: Node2D
@export var ux_overlay: Node2D
@export var bridge_scene: PackedScene
@export var ladder_scene: PackedScene
@export var fence_scene: PackedScene
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
## Whether the open placement got as far as being charged for. Read by cancel()
## to tell a finished structure from an abandoned one.
var _paid_this_placement: bool = false
var _blocked_cells: Dictionary = {}
var _tile_interaction: TileInteractionController
var _player: Player

# Kinds that count as "occupied" for new placement validation. Order doesn't
# matter — _gather_blocked_cells unions them all into the blocked dict. The
# grasses (calamagrostis, chusquea, cortaderia) are deliberately absent: they
# are `displaceable` ground cover, and TileGrid.set_occupant evicts them when
# a structure claims the cell.
const _BLOCKING_KINDS: Array[StringName] = [
	&"frailejon", &"espeletia_barclayana", &"espeletia_hartwegiana",
	&"hypericum", &"arcytophyllum",
	&"bridge_deck", &"ladder", &"rock", &"fence"
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
	if fence_scene == null:
		fence_scene = load("res://scenes/traversals/fence.tscn")
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
	_paid_this_placement = false
	_preview_hover_cell = Pathfinder.NO_CELL
	_blocked_cells = _gather_blocked_cells()
	placement_began.emit(kind)
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
			&"fence":
				candidates = Fence.find_candidates(
					origin, grid, Fence.MAX_CELLS, _blocked_cells, pcell
				)
				var blocked_f := _blocked_cells
				is_valid_endpoint = func(cell: Vector2i) -> bool:
					var g := _require_grid()
					return g != null and Fence.validate(
						origin, cell, g, blocked_f, Fence.MAX_CELLS, pcell
					) == Fence.Result.OK
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
	# cancel() is also the success teardown and is called defensively from paths
	# that were never placing, so the signal is raised only for a placement that
	# was actually open, and carries whether it got built.
	var was_placing: bool = _mode == Mode.AWAITING_ENDPOINT
	var ended_kind: StringName = _traversal_kind
	var was_paid: bool = _paid_this_placement
	_clear_preview()
	if structure_layer_manager != null:
		structure_layer_manager.reset_preview_tint()
	_mode = Mode.IDLE
	_traversal_kind = &""
	_preview_hover_cell = Pathfinder.NO_CELL
	_preview_valid = false
	_blocked_cells = {}
	_paid_this_placement = false
	if ux_overlay:
		ux_overlay.exit_placement_mode()
	if was_placing:
		placement_ended.emit(ended_kind, was_paid)


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
		&"fence":
			_paint_fence_preview(hover)


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
	# Affordability is part of "can this be built", so the ghost carries it.
	# A bridge is priced by span but cannot be TRUNCATED to fit the balance the
	# way a fence run can — a walkway that stops in the gap is not a cheaper
	# bridge — so here the answer is a red ghost, not a shorter one.
	_preview_valid = result == Bridge.Result.OK \
			and _can_afford(&"bridge", plan.size())
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
	# Same as the bridge: a ladder has one fixed footprint, so there is nothing
	# to truncate and being too poor shows as a red ghost.
	_preview_valid = result == Ladder.Result.OK \
			and _can_afford(&"ladder", Ladder.OCCUPIED_CELLS)
	if _preview_valid:
		structure_layer_manager.set_preview_valid()
	else:
		structure_layer_manager.set_preview_invalid()


func _paint_fence_preview(hover: Vector2i) -> void:
	var placer := _ensure_preview_placer()
	if placer == null:
		return
	var grid := _require_grid()
	if grid == null:
		return
	var cells := _affordable_fence_cells(hover)
	if cells.is_empty():
		return  # true diagonal, or not one tile's worth of tokens — no ghost
	var origin_tile := grid.get_tile(_origin_cell)
	var alt: int = origin_tile.altitude_low if origin_tile != null else 0

	# Every cell of the run counts as a fence for the others' orientation, so the
	# ghost shows the line it will actually become rather than a row of
	# unconnected posts. Fence.kind_at ages these as the youngest of all, so an
	# existing fence still wins the tie at a junction — which is exactly what
	# will happen when the run commits.
	var pending: Dictionary = {}
	for c in cells:
		pending[c] = true

	for c in cells:
		var kind := Fence.kind_at(c, grid, pending)
		if placer.paint(c, kind, alt):
			_preview_cells.append({"cell": c, "kind": kind, "altitude": alt})

	# Validate the CLAMPED run, not the hovered one: the ghost that is on screen
	# is what the click will build, so a cell the player cannot afford must not
	# turn the affordable part red.
	var pcell: Vector2i = _player.current_cell if _player != null else Pathfinder.NO_CELL
	var result := Fence.validate(
		_origin_cell, cells[cells.size() - 1], grid, _blocked_cells,
		Fence.MAX_CELLS, pcell
	)
	_preview_valid = result == Fence.Result.OK
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
		&"fence":
			_place_fence(far_cell)
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

	# Charge at commit — after validate, so a rejected aim costs nothing. Priced
	# by SPAN (every cell the bridge paints, both stair ends included), so
	# reaching further costs more.
	#
	# Unlike the fence this REFUSES rather than truncating to what is affordable:
	# a fence stopping short is still a wall, a bridge stopping short is a walkway
	# into the gap it was meant to cross.
	var span: int = Bridge.plan_tiles(_origin_cell, far_cell, 0).size()
	if not _pay_placements(&"bridge", span):
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
		# needed. Refund: the player paid for a bridge that does not exist.
		_refund_placements(&"bridge", span)
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

	# Charge at commit — parity with bridge. A ladder's SPAN is the two cells it
	# claims (foot and landing), whatever its height: the tile footprint is what
	# is priced, and a ladder's height buys it no extra ground. Price by
	# `Ladder.MAX_HEIGHT_CUBES`-style rise instead if a tall climb should cost
	# more than a short one — that is a balance call, not a correctness one.
	var span: int = Ladder.OCCUPIED_CELLS
	if not _pay_placements(&"ladder", span):
		cancel()
		return

	var inst: Ladder = ladder_scene.instantiate()
	world.add_child(inst)
	Ladder.configure(inst, lower_cell, upper_cell, base_alt, _placer, pathfinder)
	if not inst.build():
		# Successful builds self-register; only failures need cleanup + refund.
		_refund_placements(&"ladder", span)
		inst.queue_free()

	cancel()


# A fence run lays N INDEPENDENT one-cell fences rather than one object spanning
# N cells — that is what makes the trash action take out exactly the tile you
# pointed at. `far_cell == _origin_cell` is the single-fence case and needs no
# special handling: plan_cells returns one cell.
func _place_fence(far_cell: Vector2i) -> void:
	var grid := _require_grid()
	if grid == null:
		cancel()
		return
	# Re-gather just before placing (parity with bridge/ladder).
	_blocked_cells = _gather_blocked_cells()

	# Same clamp the preview drew, so the click builds exactly the ghost that was
	# on screen — including the case where the player aimed past what they can
	# pay for and the line stopped short.
	var cells := _affordable_fence_cells(far_cell)
	if cells.is_empty():
		cancel()
		return
	var paid_far: Vector2i = cells[cells.size() - 1]

	var pcell: Vector2i = _player.current_cell if _player != null else Pathfinder.NO_CELL
	var result: int = Fence.validate(
		_origin_cell, paid_far, grid, _blocked_cells, Fence.MAX_CELLS, pcell
	)
	if result != Fence.Result.OK:
		push_warning(
			"Fence placement rejected: %s (origin=%s, far=%s)."
			% [Fence.result_name(result), _origin_cell, paid_far]
		)
		cancel()
		return

	# Every cell is charged for, and the whole run is charged AT ONCE: paying per
	# fence as they go down could run the balance out midway and leave half a
	# wall, which the player did not ask for and cannot undo for free.
	if not _pay_placements(&"fence", cells.size()):
		cancel()
		return

	if _placer == null:
		_placer = StructurePlacer.new(structure_layer_manager)

	var origin_tile := grid.get_tile(_origin_cell)
	var alt: int = origin_tile.altitude_low if origin_tile != null else 0

	# In order, so build_index increases along the run. That is what makes a
	# later crossing run lose the tie at the junction and the first line read as
	# continuous.
	var built: int = 0
	for c in cells:
		var inst: Fence = fence_scene.instantiate()
		world.add_child(inst)
		Fence.configure(inst, c, alt, _placer, pathfinder)
		if inst.build():
			built += 1
		else:
			inst.queue_free()
	# Refund only what failed. A partial run is still a fence the player owns, so
	# tearing the successful ones back down would be worse than keeping them.
	if built < cells.size():
		_refund_placements(&"fence", cells.size() - built)

	cancel()


# ----------------------------------------------------------------------------
# Placement cost
# ----------------------------------------------------------------------------

# The scene's UnlockState, resolved lazily by group. Null (bare test scenes,
# tools) means placement is free — the token economy only exists where the
# node does.
var _unlocks: Node = null


## Charge for `count` TILES at once, all or nothing — every placement here is
## priced by span, so this is the only charging path (a fence run of N, a bridge
## of N, a ladder's 2).
func _pay_placements(type: StringName, count: int) -> bool:
	if _unlocks == null or not is_instance_valid(_unlocks):
		_unlocks = get_tree().get_first_node_in_group(&"unlocks")
	if _unlocks != null and _unlocks.has_method(&"try_pay_placements"):
		_paid_this_placement = bool(_unlocks.call(&"try_pay_placements", type, count))
		return _paid_this_placement
	# No UnlockState (bare test scenes, tools): free, and still a build.
	_paid_this_placement = true
	return true


## "Could this be paid for right now?" — asked by the PREVIEW, so a build the
## player cannot fund reads as a red ghost instead of a click that silently does
## nothing. Never charges. No UnlockState (bare test scenes, tools) means free.
func _can_afford(type: StringName, count: int) -> bool:
	if _unlocks == null or not is_instance_valid(_unlocks):
		_unlocks = get_tree().get_first_node_in_group(&"unlocks")
	if _unlocks == null or not _unlocks.has_method(&"can_afford_placement"):
		return true
	return bool(_unlocks.call(&"can_afford_placement", type, count))


## Undo of _pay_placements for the build()-failed path.
func _refund_placements(type: StringName, count: int) -> void:
	if _unlocks != null and _unlocks.has_method(&"refund_placements"):
		_unlocks.call(&"refund_placements", type, count)


## The cells a fence run from `_origin_cell` to `hover` would occupy, TRUNCATED
## to what the player can pay for at `placement_cost_per_tile` each.
##
## Truncating rather than invalidating is the whole point: the run is a line the
## player is dragging out, so the useful feedback is "it stops here", not "this
## is red". Empty means either a true diagonal (no run exists) or not one tile's
## worth of tokens.
##
## No UnlockState in the scene (bare test scenes, tools) means placement is free
## and nothing is clamped.
func _affordable_fence_cells(hover: Vector2i) -> Array[Vector2i]:
	var cells := Fence.plan_cells(_origin_cell, hover)
	if cells.is_empty():
		return cells
	if _unlocks == null or not is_instance_valid(_unlocks):
		_unlocks = get_tree().get_first_node_in_group(&"unlocks")
	if _unlocks == null or not _unlocks.has_method(&"max_affordable_tiles"):
		return cells
	var budget: int = int(_unlocks.call(&"max_affordable_tiles", cells.size()))
	if budget >= cells.size():
		return cells
	return cells.slice(0, budget)


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


## Erase a traversal's tiles, free its node, and tell pathfinding.
## Traversal.despawn clears its own occupant claims before freeing.
##
## Only a traversal whose tiles are real TERRAIN needs the grid re-ingested (see
## Traversal.changes_terrain). A fence or a ladder paints into
## TileGrid._DECORATIVE and does its work through an occupant claim or a
## traversal edge, both already applied to the live grid — so removing one now
## costs an announcement instead of an 18.7 ms rebuild, which is what building
## one always cost. The asymmetry was the bug: identical state changes, two
## orders of magnitude apart.
func remove_traversal(t: Traversal) -> void:
	if t == null or not is_instance_valid(t):
		return
	if _placer == null:
		_placer = StructurePlacer.new(structure_layer_manager)
	var was_terrain: bool = t.changes_terrain()
	t.despawn(_placer)
	if pathfinder:
		if was_terrain:
			pathfinder.rebuild()
		else:
			pathfinder.notify_graph_changed()


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
		&"fence":
			if far_cell == Pathfinder.NO_CELL:
				reason = "NO_CELL (click off grid)"
			else:
				# Report the run that would actually be BUILT. Validating the raw
				# click instead would print a verdict on cells the clamp already
				# dropped, which is the opposite of useful in a diagnostic.
				var affordable := _affordable_fence_cells(far_cell)
				if affordable.is_empty():
					reason = "UNAFFORDABLE (no tokens for even one tile)"
				else:
					var paid: Vector2i = affordable[affordable.size() - 1]
					reason = "%s (paid_far=%s, %d/%d cells)" % [
						Fence.result_name(Fence.validate(
							_origin_cell, paid, grid, _blocked_cells,
							Fence.MAX_CELLS, pcell)),
						paid, affordable.size(),
						Fence.plan_cells(_origin_cell, far_cell).size(),
					]

	print("[TPC] kind=%s origin=%s base_alt=%d click_cell=%s target_alt=%s hover_cell=%s preview_valid=%s -> %s" % [
		_traversal_kind, _origin_cell, base_alt, far_cell,
		target_alt_str, hover_alt_cell, _preview_valid, reason,
	])
