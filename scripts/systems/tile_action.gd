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


## Final availability gate. Combines the shared proximity rule with the
## subclass predicate — so every action is gated by the same structure over the
## four inputs: proximity (`_within_range`), and tile type / occupants /
## inventory (`_applies`, reading ctx.tile, ctx.pathfinder.grid().occupant_at,
## ctx.player). Side-effect free: the controller calls this once per right-click
## across every registered action. Subclasses override `_applies` (and, rarely,
## `_within_range`), not this method.
func is_available(ctx: ActionContext) -> bool:
	if ctx == null:
		return false
	return _within_range(ctx) and _applies(ctx)


## Proximity rule. Default: the target must be one of the 8 cells adjacent to
## the player (Chebyshev distance == 1), excluding the player's own tile.
## Override for own-tile actions (distance 0) or longer reach.
func _within_range(ctx: ActionContext) -> bool:
	var d: Vector2i = ctx.cell - ctx.player_cell
	return maxi(abs(d.x), abs(d.y)) == 1


## Subclass predicate: does this action apply to `ctx.cell` given tile type,
## occupants, and inventory? Proximity is already handled by `_within_range`.
## Side-effect free.
func _applies(_ctx: ActionContext) -> bool:
	return false


## Called once when the player selects the action from the radial menu.
func execute(_ctx: ActionContext) -> void:
	pass
