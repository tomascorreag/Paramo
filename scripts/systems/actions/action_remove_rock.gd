class_name ActionRemoveRock
extends TileAction

# Pickaxe: remove a Rock occupant from the clicked cell. The cell is
# unwalkable while a rock sits on it (Rock.blocks_movement = true), but the
# underlying terrain is walkable, so resolution lands on it and this action —
# gated only on the occupant being a Rock — is the one that applies there.


func _init() -> void:
	id = &"remove_rock"
	icon = preload("res://assets/sprites/UX/icons/pickaxe.tres")
	group = &""  # top-level


func _applies(ctx: ActionContext) -> bool:
	if ctx.tile_interaction == null or ctx.pathfinder == null:
		return false
	var grid := ctx.pathfinder.grid()
	if grid == null:
		return false
	return grid.occupant_at(ctx.cell) is Rock


func execute(ctx: ActionContext) -> void:
	ctx.tile_interaction.remove_rock(ctx.cell)
