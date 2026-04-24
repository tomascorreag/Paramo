class_name ActionRemoveLadder
extends TileAction

# Trash: remove an existing ladder. Suppressed when the player is currently
# standing on the ladder's origin or top cell (would strand them).


func _init() -> void:
	id = &"remove_ladder"
	# Shares trash.tres with ActionRemoveBridge.
	icon = preload("res://assets/sprites/UX/icons/trash.tres")
	group = &""  # top-level


func is_available(ctx: ActionContext) -> bool:
	if ctx.traversal == null or ctx.tile_interaction == null:
		return false
	var t := ctx.traversal.find_traversal_at(ctx.cell)
	if t == null or not (t is Ladder):
		return false
	return not ctx.tile_interaction.is_player_on_traversal(t)


func execute(ctx: ActionContext) -> void:
	ctx.tile_interaction.remove_traversal_at(ctx.cell)
