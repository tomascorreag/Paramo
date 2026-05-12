class_name ActionPlantFrailejon
extends TileAction

# Plant a frailejon on an empty walkable tile. Grouped under "plant".


func _init() -> void:
	id = &"plant_frailejon"
	icon = preload("res://assets/sprites/UX/icons/frailejon.tres")
	group = &"plant"


func is_available(ctx: ActionContext) -> bool:
	if ctx.tile == null or not ctx.tile.walkable:
		return false
	if ctx.tile_interaction == null:
		return false
	# No stacking — any registered occupant (frailejon, bridge_deck, ladder,
	# rock) blocks planting. Single registry query instead of separate
	# planted_cells / find_traversal_at calls.
	if ctx.pathfinder != null:
		var grid := ctx.pathfinder.grid()
		if grid != null and grid.occupant_at(ctx.cell) != null:
			return false
	return true


func execute(ctx: ActionContext) -> void:
	ctx.tile_interaction.plant_frailejon(ctx.cell)
