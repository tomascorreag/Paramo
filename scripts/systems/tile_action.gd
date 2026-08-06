class_name TileAction
extends RefCounted

# ============================================================================
# TileAction
# ============================================================================
#
# Base class for every right-click tile action. Concrete subclasses override
# `is_available()` and `execute()`. The registry filters available actions
# per right-click; the controller groups them into submenus by `group`.
#
# Design notes:
#   - RefCounted (not Resource). Actions are code-only per the agreed design;
#     no .tres authoring needed. Moving to Resources later is a clean swap.
#   - No state held on the action instance itself — all per-click data flows
#     through ActionContext. Registry owns one instance per action; contexts
#     are throwaway per click.
#
# ============================================================================


var id: StringName = &""
var icon: Texture2D

## Empty = top-level wheel entry. Non-empty = groups with sibling actions
## under a submenu identified by this StringName.
var group: StringName = &""

## Marks a dev affordance rather than real gameplay. Such actions still open the
## menu, but are excluded from TileInteractionController.has_meaningful_action,
## so they don't promote a tile from "movable" to "actionable" in the hover
## reticle. Without this a debug action that applies broadly (e.g. "ignite any
## grass") would light up the reticle on half the map.
var debug_only: bool = false


## "Can I act on this cell from where I stand RIGHT NOW?" gate. Combines the
## proximity rule with the subclass predicate. Unchanged contract: the controller
## uses it for the instant-execute path (player already adjacent) and the
## on-arrival re-check after a walk. Menu offering is a separate, reachability-
## aware gate — see `is_offerable`. Subclasses override `_applies` (and, rarely,
## `_range_ok`), not this method.
func is_available(ctx: ActionContext) -> bool:
	if ctx == null:
		return false
	return _within_range(ctx) and _applies(ctx)


## "Should this action appear in the menu for this cell?" — the reachability-aware
## gate. True iff the action applies to the tile AND at least one cell it could be
## performed from (`standing_cells`) is reachable by the player (`ctx.reachable`,
## the BFS set the controller injects). This is what lets you right-click a far
## tile and still be offered the action: the player will walk to a reachable
## neighbour and act on arrival. `_applies` is evaluated ONCE (on the target),
## not per neighbour. Side-effect free.
func is_offerable(ctx: ActionContext) -> bool:
	if ctx == null or ctx.pathfinder == null:
		return false
	if not _applies(ctx):
		return false
	for s in standing_cells(ctx):
		if ctx.reachable.has(s):
			return true
	return false


## "Can the player currently PAY for this action?" — deliberately separate from
## `_applies`, which asks whether the action makes sense on this cell at all.
## The split is what lets an unaffordable action be SHOWN DIMMED in the radial
## menu instead of silently vanishing: a fire with no extinguish entry reads as a
## bug, a greyed extinguish entry reads as "you are out of water".
##
## Default true — most actions are free. Override in actions with a resource
## cost. Side-effect free; called both when the wheel is built and again on
## selection, since a walk-then-act can span a change in the balance.
func is_enabled(_ctx: ActionContext) -> bool:
	return true


## Cells from which this action can be performed on `ctx.cell`: walkable cells
## satisfying the action's range rule. Scans the 3×3 block around the target
## (including the origin, so a future distance-0 action's `_range_ok` override
## works without changing this) and filters by `_range_ok` + walkability.
func standing_cells(ctx: ActionContext) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if ctx == null or ctx.pathfinder == null:
		return out
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var s: Vector2i = ctx.cell + Vector2i(dx, dy)
			if _range_ok(ctx.cell, s) and ctx.pathfinder.is_walkable(s):
				out.append(s)
	return out


## Proximity rule against the player's current cell. Kept for `is_available` and
## the "act now vs walk" decision. Delegates to `_range_ok` so range logic has a
## single source of truth.
func _within_range(ctx: ActionContext) -> bool:
	return _range_ok(ctx.cell, ctx.player_cell)


## Range predicate between a target cell and a hypothetical standing cell.
## Default: `standing` must be one of the 8 cells adjacent to `target` (Chebyshev
## distance == 1), excluding the target itself. Override for own-tile actions
## (distance 0) or longer reach.
func _range_ok(target: Vector2i, standing: Vector2i) -> bool:
	var d: Vector2i = target - standing
	return maxi(abs(d.x), abs(d.y)) == 1


## Subclass predicate: does this action apply to `ctx.cell` given tile type,
## occupants, and inventory? Proximity is already handled by `_within_range`.
## Side-effect free.
func _applies(_ctx: ActionContext) -> bool:
	return false


## Called once when the player selects the action from the radial menu.
func execute(_ctx: ActionContext) -> void:
	pass
