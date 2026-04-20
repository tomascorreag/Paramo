class_name ActionPlantFrailejon
extends TileAction

# Plant a frailejon on an empty walkable tile. Grouped under "plant".


const _ICON_PATH: String = "res://assets/sprites/objects/ISO_Plants.png"


func _init() -> void:
	id = &"plant_frailejon"
	icon = load(_ICON_PATH)
	icon_region = Rect2(96, 0, 32, 32)
	group = &"plant"


func is_available(ctx: ActionContext) -> bool:
	if ctx.tile == null or not ctx.tile.walkable:
		return false
	# No stacking — occupied cells only offer removal.
	if ctx.tile_interaction == null:
		return false
	if ctx.tile_interaction.planted_cells().has(ctx.cell):
		return false
	if ctx.traversal != null and ctx.traversal.find_traversal_at(ctx.cell) != null:
		return false
	return true


func execute(ctx: ActionContext) -> void:
	ctx.tile_interaction.plant_frailejon(ctx.cell)
