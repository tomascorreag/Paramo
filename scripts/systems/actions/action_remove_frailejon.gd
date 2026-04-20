class_name ActionRemoveFrailejon
extends TileAction

# Trowel: remove a planted frailejon from the clicked cell.


const _ICON_PATH: String = "res://assets/sprites/UX/icons.png"


func _init() -> void:
	id = &"remove_frailejon"
	icon = load(_ICON_PATH)
	icon_region = Rect2(48, 32, 16, 16)
	group = &""  # top-level


func is_available(ctx: ActionContext) -> bool:
	if ctx.tile_interaction == null:
		return false
	return ctx.tile_interaction.planted_cells().has(ctx.cell)


func execute(ctx: ActionContext) -> void:
	ctx.tile_interaction.remove_frailejon(ctx.cell)
