class_name ActionRegistry
extends RefCounted

# ============================================================================
# ActionRegistry
# ============================================================================
#
# Holds every registered TileAction and filters them per click via
# `available_for(ctx)`. Owned by TileInteractionController; not an autoload
# because there's only one consumer today. Promote to an autoload when a
# second system (tutorials, keyboard shortcuts) needs to iterate actions.
#
# ============================================================================


var _actions: Array[TileAction] = []


func register(action: TileAction) -> void:
	_actions.append(action)


## Returns all actions whose `is_available(ctx)` returns true, in registration
## order. Callers group by `action.group` to build submenus.
func available_for(ctx: ActionContext) -> Array[TileAction]:
	var out: Array[TileAction] = []
	for a in _actions:
		if a.is_available(ctx):
			out.append(a)
	return out


## Find by id, for dispatch from RadialMenu.item_selected(id). Returns null
## when no action matches — caller should ignore unknown ids.
func find(id: StringName) -> TileAction:
	for a in _actions:
		if a.id == id:
			return a
	return null
