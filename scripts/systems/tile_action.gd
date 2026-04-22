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


## Returns true when this action applies to `ctx.cell` given current world
## state. Overrides should be side-effect free — the controller calls this
## once per right-click across every registered action.
func is_available(_ctx: ActionContext) -> bool:
	return false


## Called once when the player selects the action from the radial menu.
func execute(_ctx: ActionContext) -> void:
	pass
