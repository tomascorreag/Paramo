class_name ActionRemoveFrailejon
extends TileAction

# Trowel: remove a planted frailejon from the clicked cell.


func _init() -> void:
	id = &"remove_frailejon"
	icon = preload("res://assets/sprites/UX/icons/trowel.tres")
	group = &""  # top-level


func is_available(ctx: ActionContext) -> bool:
	if ctx.tile_interaction == null:
		return false
	return ctx.tile_interaction.planted_cells().has(ctx.cell)


func execute(ctx: ActionContext) -> void:
	ctx.tile_interaction.remove_frailejon(ctx.cell)
