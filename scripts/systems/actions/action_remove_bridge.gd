class_name ActionRemoveBridge
extends TileAction

# Trash: remove an existing bridge. Suppressed when the player is currently
# standing anywhere on that bridge (would strand them).


func _init() -> void:
	id = &"remove_bridge"
	icon = preload("res://assets/sprites/UX/icons/trash.tres")
	group = &""  # top-level


func is_available(ctx: ActionContext) -> bool:
	if ctx.traversal == null or ctx.tile_interaction == null:
		return false
	var t := ctx.traversal.find_traversal_at(ctx.cell)
	if t == null or not (t is Bridge):
		return false
	return not ctx.tile_interaction.is_player_on_traversal(t)


func execute(ctx: ActionContext) -> void:
	ctx.tile_interaction.remove_bridge(ctx.cell)
