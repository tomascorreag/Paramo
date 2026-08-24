class_name TileInteractionController
extends Node

## Handles right-click tile interactions via a radial icon menu driven by an
## ActionRegistry: every right-click builds an ActionContext, asks the
## registry which TileActions are available for that cell, groups them by
## `action.group` into submenus, and shows only the resulting entries.
## Empty availability -> no menu, UXOverlay flashes denied.

const GROUP_NAME: StringName = &"tile_interaction_controller"

# Prefix for submenu-group pseudo-ids. Keeps the group id namespace disjoint
# from TileAction.id so `_on_item_selected` can't mistake a stale submenu-
# parent click for a missing action (even if an action is ever registered
# with id == &"build").
const _GROUP_ID_PREFIX: String = "group:"

# Action scripts — preloaded so Godot's class_name global cache is populated
# before _ready(). Listing them explicitly here also makes the set of
# registered actions easy to audit in one place.
const _ACTION_INSPECT: GDScript = preload("res://scripts/systems/actions/action_inspect.gd")
const _ACTION_PLANT_FRAILEJON: GDScript = preload("res://scripts/systems/actions/action_plant_frailejon.gd")
const _ACTION_REMOVE_FRAILEJON: GDScript = preload("res://scripts/systems/actions/action_remove_frailejon.gd")
const _ACTION_BUILD_BRIDGE: GDScript = preload("res://scripts/systems/actions/action_build_bridge.gd")
const _ACTION_REMOVE_BRIDGE: GDScript = preload("res://scripts/systems/actions/action_remove_bridge.gd")
const _ACTION_BUILD_LADDER: GDScript = preload("res://scripts/systems/actions/action_build_ladder.gd")
const _ACTION_REMOVE_LADDER: GDScript = preload("res://scripts/systems/actions/action_remove_ladder.gd")
const _ACTION_BUILD_FENCE: GDScript = preload("res://scripts/systems/actions/action_build_fence.gd")
const _ACTION_REMOVE_FENCE: GDScript = preload("res://scripts/systems/actions/action_remove_fence.gd")
const _ACTION_REMOVE_ROCK: GDScript = preload("res://scripts/systems/actions/action_remove_rock.gd")
const _ACTION_EXTINGUISH_FIRE: GDScript = preload("res://scripts/systems/actions/action_extinguish_fire.gd")
const _ACTION_IGNITE_FIRE: GDScript = preload("res://scripts/systems/actions/action_ignite_fire.gd")

# Visuals for submenu group nodes — rendered as parent items on the wheel
# whose submenu children are the individual TileActions in that group.
const _GROUP_ICONS: Dictionary = {
	&"plant": preload("res://assets/sprites/UX/icons/group_plant.tres"),
	&"build": preload("res://assets/sprites/UX/icons/group_build.tres"),
}

const _CENTER_ICON: Texture2D = preload("res://assets/sprites/UX/icons/center.tres")


@export var pathfinder: Pathfinder
@export var player: Player
@export var world: Node2D
@export var traversal_placement_controller: TraversalPlacementController

var _pending_cell: Vector2i

# Walk-then-act state. When an action is selected on a tile the player can't
# reach from where it stands, the player walks to a reachable neighbour and the
# action fires on arrival. `_pending_action` != null means a walk is in flight;
# `_process` watches player.is_moving() drop to false to detect arrival.
var _pending_action: TileAction
var _pending_target: Vector2i

var _menu: Control  # RadialMenu instance
var _menu_layer: CanvasLayer
var _radial_menu_script: GDScript
var _registry: ActionRegistry
var _interaction_accept: Callable

var _ux_overlay: Node2D  # UXOverlay
var _frailejon_scene: PackedScene

# --- Debug toast (used by ActionInspect) -----------------------------------
var _toast_layer: CanvasLayer
var _toast_label: Label
var _toast_tween: Tween


func _enter_tree() -> void:
	add_to_group(GROUP_NAME)


func _ready() -> void:
	if pathfinder == null:
		pathfinder = get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	if player == null:
		player = get_tree().get_first_node_in_group(&"player") as Player

	_ux_overlay = get_tree().get_first_node_in_group(UXOverlay.GROUP_NAME)
	if traversal_placement_controller == null:
		traversal_placement_controller = get_tree().get_first_node_in_group(
			TraversalPlacementController.GROUP_NAME
		) as TraversalPlacementController
	_radial_menu_script = load("res://scripts/ui/radial_menu.gd")
	_frailejon_scene = load("res://scenes/tools/frailejon.tscn")

	_menu_layer = CanvasLayer.new()
	_menu_layer.layer = UILayers.RADIAL_MENU
	add_child(_menu_layer)

	_registry = ActionRegistry.new()
	_registry.register(_ACTION_INSPECT.new())
	_registry.register(_ACTION_PLANT_FRAILEJON.new())
	_registry.register(_ACTION_REMOVE_FRAILEJON.new())
	_registry.register(_ACTION_BUILD_BRIDGE.new())
	_registry.register(_ACTION_BUILD_LADDER.new())
	_registry.register(_ACTION_BUILD_FENCE.new())
	_registry.register(_ACTION_REMOVE_BRIDGE.new())
	_registry.register(_ACTION_REMOVE_LADDER.new())
	_registry.register(_ACTION_REMOVE_FENCE.new())
	_registry.register(_ACTION_REMOVE_ROCK.new())
	_registry.register(_ACTION_EXTINGUISH_FIRE.new())
	# Debug-only (self-gates on Debug.enabled); registered unconditionally so the
	# F3 toggle works live rather than being baked in at _ready.
	_registry.register(_ACTION_IGNITE_FIRE.new())

	# General interaction-target rule, shared by the right-click handler and
	# UXOverlay hover: resolve the topmost cell that is walkable OR has an
	# available action. No tile-type special-casing.
	_interaction_accept = func(c: Vector2i) -> bool:
		return pathfinder.is_terrain_walkable(c) or has_any_action(c)

	# Cancel any in-flight walk-then-act when the player is redirected by a
	# left-click. Our own approach walks call player.follow_path directly (not
	# through ClickToMoveController), so path_dispatched fires only for genuine
	# user clicks — no self-cancel.
	var c2m := get_tree().get_first_node_in_group(
		ClickToMoveController.GROUP_NAME
	) as ClickToMoveController
	if c2m:
		c2m.path_dispatched.connect(_on_user_path_dispatched)


func _unhandled_input(event: InputEvent) -> void:
	if pathfinder == null or player == null:
		return
	if traversal_placement_controller and traversal_placement_controller.is_placing():
		return
	if not (event is InputEventMouseButton):
		return

	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_RIGHT or not mb.pressed:
		return

	# Right-click while the player is moving = brake: stop where it is and drop
	# any in-flight walk-then-act, WITHOUT opening a menu. The pending action
	# must be cancelled before the movement ends so the arrival poll (_process)
	# doesn't fire it. A second right-click, now that the player is static,
	# brings up the action menu normally (handled below).
	if player.is_moving():
		player.stop()
		_cancel_pending()
		get_viewport().set_input_as_handled()
		return

	# The action menu is the door to every placement, so gating it here is the
	# whole of "no building before the FTUE's build step". Below the brake above
	# on purpose: stopping a walk is part of the movement the FTUE has already
	# taught by then. Not consumed, for the same reason as click-to-move.
	if not TutorialGate.allows(TutorialGate.Action.BUILD):
		return

	var global_pos := _event_global_position(mb)
	# Resolve the cell under the cursor with the general interaction rule: the
	# topmost cell that is walkable OR has an available action — so water /
	# burning tiles resolve with no tile-type special-casing here.
	var cell := pathfinder.resolve_click(global_pos, _interaction_accept)
	if cell == Pathfinder.NO_CELL:
		return

	var ctx := _build_context(cell)
	var actions := _registry.available_for(ctx)
	if actions.is_empty():
		# Resolved a tile (e.g. one you can move to) but no action applies —
		# flash so the player knows the click registered.
		if _ux_overlay and _ux_overlay.has_method(&"flash_denied"):
			_ux_overlay.flash_denied(cell)
		get_viewport().set_input_as_handled()
		return

	var items := _assemble_menu_items(actions, ctx)

	_pending_cell = cell
	var world_pos := pathfinder.cell_to_world(cell)
	var alt := pathfinder.altitude_center(cell)
	var tile_world := world_pos + Vector2(0.0, -alt * Pathfinder.HALF_STEP_PX)
	var tile_screen := get_viewport().get_canvas_transform() * tile_world
	_show_action_menu(tile_screen, items)
	get_viewport().set_input_as_handled()


## Read-only view of the cells currently occupied by planted frailejones,
## keyed by cell (values are the Node2D instances). Backed by the unified
## occupant registry on TileGrid — frailejones self-register in _ready and
## clear in _exit_tree, so this method is a thin facade kept for backwards
## compatibility with callers that ask "what cells have plants?".
func planted_cells() -> Dictionary:
	if pathfinder == null:
		return {}
	var grid := pathfinder.grid()
	if grid == null:
		return {}
	return grid.occupants_of_kind(&"frailejon")


## Callable(cell) -> bool used to resolve right-click / hover targets. A cell is
## a valid interaction target if it's walkable terrain (movable, plantable, …)
## OR at least one action is available on it (water to fill, fire to put out, …).
## The single general rule — no tile-type branches. Exposed so UXOverlay resolves
## hover cells by the exact same rule the right-click handler uses.
func interaction_accept() -> Callable:
	return _interaction_accept


## True iff at least one registered action is available on `cell`. This is the
## gate: any available action makes the tile interactable (opens the menu / shows
## a reticle). Availability is each action's own call over the four inputs
## (proximity, occupants, tile type, inventory).
func has_any_action(cell: Vector2i) -> bool:
	if _registry == null:
		return false
	return not _registry.available_for(_build_context(cell)).is_empty()


## True iff right-clicking `cell` would offer at least one non-debug action
## (plant, build, remove, extinguish, …). Inspect is excluded — it's a
## dev-only readout and shouldn't promote a tile from "movable" to "actionable"
## in the UX. Used by UXOverlay to choose between the solid and dim circle rows.
## Proximity is enforced by each action, so far cells return false naturally.
func has_meaningful_action(cell: Vector2i) -> bool:
	if _registry == null:
		return false
	for action in _registry.available_for(_build_context(cell)):
		if action.id != &"inspect" and not action.debug_only:
			return true
	return false


# ---------------------------------------------------------------------------
# Registry-driven menu assembly
# ---------------------------------------------------------------------------

func _build_context(cell: Vector2i) -> ActionContext:
	var ctx := ActionContext.new()
	ctx.cell = cell
	ctx.tile = pathfinder.get_tile(cell)
	ctx.player_cell = player.current_cell
	ctx.player = player
	ctx.tile_interaction = self
	ctx.traversal = traversal_placement_controller
	ctx.pathfinder = pathfinder
	ctx.unlocks = _unlocks_node()
	# Cached BFS from the player's cell — lets is_offerable answer "can the player
	# reach a cell to act from?" without a per-action flood fill.
	ctx.reachable = pathfinder.reachable_from(player.current_cell)
	return ctx


# The scene's UnlockState, resolved lazily by group (it sits beside this
# controller in gameplay_base but _ready order is not guaranteed). Null in
# scenes without the token economy — actions treat that as all-unlocked.
var _unlocks: Node = null

func _unlocks_node() -> Node:
	if _unlocks == null or not is_instance_valid(_unlocks):
		_unlocks = get_tree().get_first_node_in_group(&"unlocks")
	return _unlocks


# Partitions actions into top-level entries (group == &"") and submenu-wrapped
# groups (group != &""). Group order follows registration order; within a
# group, actions also keep registration order.
#
# Each entry carries "enabled" (from TileAction.is_enabled) so the wheel can dim
# an action the player can't currently pay for rather than hiding it. A group
# wrapper is enabled if ANY child is — dimming a submenu whose contents are
# usable would hide working actions behind a dead-looking icon.
func _assemble_menu_items(actions: Array[TileAction], ctx: ActionContext) -> Array[Dictionary]:
	var top: Array[Dictionary] = []
	var groups: Dictionary = {}            # StringName -> Array[Dictionary]
	var group_order: Array[StringName] = []
	for a in actions:
		var entry := {
			"id": String(a.id),
			"icon": a.icon,
			"enabled": a.is_enabled(ctx),
		}
		if a.group == &"":
			top.append(entry)
		else:
			if not groups.has(a.group):
				groups[a.group] = []
				group_order.append(a.group)
			groups[a.group].append(entry)

	for group_id in group_order:
		var submenu: Array = groups[group_id]
		var any_enabled: bool = false
		for entry: Dictionary in submenu:
			if entry.get("enabled", true):
				any_enabled = true
				break
		top.append({
			"id": _GROUP_ID_PREFIX + String(group_id),
			"icon": _GROUP_ICONS.get(group_id),
			"enabled": any_enabled,
			"submenu": submenu,
		})
	return top


func _show_action_menu(screen_pos: Vector2, items: Array[Dictionary]) -> void:
	_close_menu()

	_menu = _radial_menu_script.new()
	_menu.center_icon_texture = _CENTER_ICON
	_menu_layer.add_child(_menu)
	_menu.item_selected.connect(_on_item_selected)
	_menu.closed.connect(_on_menu_closed)
	_menu.open(screen_pos, items)
	if _ux_overlay:
		_ux_overlay.lock_at(_pending_cell)


func _close_menu() -> void:
	if _menu and is_instance_valid(_menu):
		_menu.item_selected.disconnect(_on_item_selected)
		_menu.closed.disconnect(_on_menu_closed)
		_menu.queue_free()
		_menu = null
		# Keep the lock while a walk-then-act is pending — the marker rides the
		# target tile until the player arrives (or the walk is cancelled).
		if _ux_overlay and _pending_action == null:
			_ux_overlay.unlock()


func _on_item_selected(id: String) -> void:
	# Submenu-parent pseudo-ids should never reach here (RadialMenu only emits
	# item_selected for leaves), but guard in case the contract changes.
	if id.begins_with(_GROUP_ID_PREFIX):
		return
	var action := _registry.find(StringName(id))
	if action == null:
		return
	var ctx := _build_context(_pending_cell)
	# State may have shifted between menu open and item click (player moved,
	# a structure got removed externally, etc.). Re-check reachability-aware
	# offerability against fresh context before doing anything.
	if not action.is_offerable(ctx):
		_deny(_pending_cell)
		return
	# Affordability is re-checked separately: the wheel dims an unaffordable
	# action, but that snapshot is taken when the menu opens, and the balance can
	# move before the click lands.
	if not action.is_enabled(ctx):
		_deny(_pending_cell)
		return
	# Already standing next to the target -> act immediately (unchanged UX).
	if action.is_available(ctx):
		action.execute(ctx)
		if _ux_overlay:
			_ux_overlay.unlock()
		return
	# Otherwise walk to the nearest reachable standing cell and act on arrival.
	var approach := _best_approach_path(action, ctx)
	if approach.size() < 2:
		_deny(_pending_cell)
		return
	approach.remove_at(0)  # drop the start cell; player already stands there
	_pending_action = action
	_pending_target = _pending_cell
	player.follow_path(approach)
	# Keep a marker on the target tile for the duration of the walk. The menu's
	# `closed` signal won't tear it down (guarded by _pending_action above).
	if _ux_overlay:
		_ux_overlay.lock_at(_pending_target)


func _on_menu_closed() -> void:
	_menu = null
	if _ux_overlay and _pending_action == null:
		_ux_overlay.unlock()


# ---------------------------------------------------------------------------
# Walk-then-act
# ---------------------------------------------------------------------------

# Watch for the pending walk to end. is_moving() stays true between steps and
# while a path is queued, so a single true->false transition means the player
# either arrived or the path aborted — either way, re-check and act (or deny).
func _process(_delta: float) -> void:
	if _pending_action == null:
		return
	if player == null or player.is_moving():
		return
	var action := _pending_action
	var target := _pending_target
	_pending_action = null  # clear first so unlock/close guards see no pending
	var ctx := _build_context(target)
	# is_enabled as well as is_available: the walk takes real time, and a costed
	# action the player could afford when they clicked may be unaffordable by the
	# time they arrive.
	if action.is_available(ctx) and action.is_enabled(ctx):
		action.execute(ctx)
		# unlock() is a no-op if execute entered placement mode (bridge/ladder);
		# for plant/remove it clears the walk marker.
		if _ux_overlay:
			_ux_overlay.unlock()
	else:
		_deny(target)


# Shortest reachable approach path to a cell this action can be performed from.
# Returns the full path (start included) or [] when no standing cell is reachable.
func _best_approach_path(action: TileAction, ctx: ActionContext) -> Array[Vector2i]:
	var best: Array[Vector2i] = []
	for s in action.standing_cells(ctx):
		if not ctx.reachable.has(s):
			continue
		var p := pathfinder.find_path(player.current_cell, s)
		if p.size() >= 2 and (best.is_empty() or p.size() < best.size()):
			best = p
	return best


func _cancel_pending() -> void:
	if _pending_action == null:
		return
	_pending_action = null
	if _ux_overlay:
		_ux_overlay.unlock()


func _on_user_path_dispatched(_cells: Array[Vector2i]) -> void:
	_cancel_pending()


# Clear any lock and flash a denied reticle on `cell`. flash_denied only renders
# in HOVER state, so unlock() must run first.
func _deny(cell: Vector2i) -> void:
	if _ux_overlay == null:
		return
	_ux_overlay.unlock()
	if _ux_overlay.has_method(&"flash_denied"):
		_ux_overlay.flash_denied(cell)


# ---------------------------------------------------------------------------
# Actions called via ActionContext (previously private)
# ---------------------------------------------------------------------------

func plant_frailejon(cell: Vector2i) -> void:
	# Charge at commit — 1 token AND 1 water, one cell (see UnlockState:
	# planting is the only placement that spends the reserve). Instancing never
	# fails after this point (no validate step — _applies already vetted the
	# cell), so no refund path is needed.
	var unlocks := _unlocks_node()
	if unlocks != null and unlocks.has_method(&"try_pay_placement"):
		if not bool(unlocks.call(&"try_pay_placement", &"frailejon")):
			return
	var frailejon: Frailejon = _frailejon_scene.instantiate()
	frailejon.cell = cell

	# Place the Node2D at the altitude-0 world point for the cell. The plant
	# itself lifts its sprite visually in _ready() so the sort key stays
	# altitude-independent (same pattern as Player). Frailejone registers
	# itself as TileGrid occupant in _ready — Pathfinder reads its
	# walk_penalty() during step-cost calc, so no explicit set_cell_penalty
	# call is needed here.
	world.add_child(frailejon)
	frailejon.global_position = pathfinder.cell_to_world(cell)


func remove_frailejon(cell: Vector2i) -> void:
	if pathfinder == null:
		return
	var grid := pathfinder.grid()
	if grid == null:
		return
	var node := grid.occupant_at(cell) as Frailejon
	if node == null:
		return
	# Frailejone clears its occupant claim in _exit_tree.
	node.queue_free()


## Free the rock at `cell` and rebuild pathfinding. Walkability flips back
## (rock.blocks_movement = true → cell was unwalkable; clearing the occupant
## reveals the underlying walkable tile), so reachability caches must be
## refreshed — same pattern as TraversalPlacementController.remove_traversal.
func remove_rock(cell: Vector2i) -> void:
	if pathfinder == null:
		return
	var grid := pathfinder.grid()
	if grid == null:
		return
	var node := grid.occupant_at(cell) as Rock
	if node == null:
		return
	# Rock clears its occupant claim in _exit_tree, and queue_free defers that to
	# the end of the frame — so clear it eagerly, or every query until then still
	# sees the rock.
	grid.clear_occupant(cell, node)
	node.queue_free()
	# ANNOUNCE, don't rebuild. A rock blocks purely through blocks_movement() on
	# its occupant claim; it paints no terrain, so there is nothing for a rebuild
	# to re-ingest and it would spend 18.7 ms reconstructing an identical grid.
	# clear_occupant already bumped TileGrid.structure_version, so the
	# pathfinder's resolved-edge cache drops itself; the emit is what refreshes
	# the reachability the action menu and UXOverlay read.
	pathfinder.notify_graph_changed()


func begin_traversal(origin: Vector2i, kind: StringName) -> void:
	if traversal_placement_controller == null:
		push_warning("TileInteractionController: no TraversalPlacementController wired.")
		return
	traversal_placement_controller.begin(origin, kind)


## Remove whatever Traversal (bridge, ladder, future kinds) covers `cell`.
## Refuses to remove while the player stands on the traversal — matches the
## ActionRemove* is_available() guards but also protects scripted callers.
func remove_traversal_at(cell: Vector2i) -> void:
	if traversal_placement_controller == null:
		return
	var t: Traversal = traversal_placement_controller.find_traversal_at(cell)
	if t == null:
		return
	if is_player_on_traversal(t):
		push_warning(
			"TileInteractionController: refusing to remove traversal at %s — player stands on it."
			% cell
		)
		return
	traversal_placement_controller.remove_traversal(t)


func is_player_on_traversal(t: Traversal) -> bool:
	if player == null or t == null:
		return false
	return t.occupies_cell(player.current_cell)


# ---------------------------------------------------------------------------
# Debug toast (used by ActionInspect)
# ---------------------------------------------------------------------------

## Shows `text` as a bottom-screen label for `duration` seconds, then fades.
## Cheap stand-in for a proper tile-info panel; tied to ActionInspect for now.
func show_debug_toast(text: String, duration: float) -> void:
	_ensure_toast()
	_toast_label.text = text
	_toast_label.modulate.a = 1.0
	_toast_label.visible = true
	if _toast_tween and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(duration)
	_toast_tween.tween_property(_toast_label, "modulate:a", 0.0, 0.35)
	_toast_tween.tween_callback(func() -> void: _toast_label.visible = false)
	# Also echo to stdout so the info is visible when UI is off.
	print("[inspect] ", text)


func _ensure_toast() -> void:
	if _toast_layer != null and is_instance_valid(_toast_layer):
		return
	_toast_layer = CanvasLayer.new()
	_toast_layer.layer = UILayers.TOAST
	add_child(_toast_layer)
	_toast_label = Label.new()
	_toast_label.add_theme_color_override(&"font_color", Palette.TEXT)
	_toast_label.add_theme_color_override(&"font_shadow_color", Palette.with_alpha(Palette.SHADOW, 0.85))
	_toast_label.add_theme_constant_override(&"shadow_offset_x", 1)
	_toast_label.add_theme_constant_override(&"shadow_offset_y", 1)
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_toast_label.offset_top = -28.0
	_toast_label.offset_bottom = -8.0
	_toast_label.visible = false
	_toast_layer.add_child(_toast_label)


func _event_global_position(mb: InputEventMouseButton) -> Vector2:
	var viewport := get_viewport()
	var canvas_xform := viewport.get_canvas_transform()
	return canvas_xform.affine_inverse() * mb.position
