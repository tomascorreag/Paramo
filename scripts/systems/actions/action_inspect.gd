class_name ActionInspect
extends TileAction

# Inspect: print CellData fields to the debug label. Proves the action
# abstraction handles non-placement actions and is a cheap first-class
# debugging aid during development.


const _DISPLAY_DURATION: float = 2.5


func _init() -> void:
	id = &"inspect"
	icon = preload("res://assets/sprites/UX/icons/magnifying_glass.tres")
	group = &""


func is_available(ctx: ActionContext) -> bool:
	return ctx.tile != null and ctx.tile.walkable


func execute(ctx: ActionContext) -> void:
	if ctx.tile_interaction == null:
		return
	var t := ctx.tile
	var text := "cell %s  kind=%s  alt=%s..%s  walk=%s" % [
		ctx.cell, t.tile_kind, t.altitude_low, t.altitude_high, t.walkable,
	]
	ctx.tile_interaction.show_debug_toast(text, _DISPLAY_DURATION)
