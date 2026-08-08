class_name ActionRemoveFence
extends TileAction

# Trash: take down the ONE fence on the clicked cell. A run is N independent
# one-cell Fences rather than a single object spanning them, so this leaves the
# rest of the line standing — and the two cells that were joined to this one
# re-derive their own orientation as it goes (Fence._refresh_neighbours).
#
# The player can never be standing on a fence (it blocks movement, so they
# could not have walked onto it), which makes the is_player_on_traversal guard
# dead weight here in practice. It stays for symmetry with the bridge/ladder
# actions and because it is the same guard remove_traversal_at applies anyway.


func _init() -> void:
	id = &"remove_fence"
	# Shares trash.tres with ActionRemoveBridge / ActionRemoveLadder.
	icon = preload("res://assets/sprites/UX/icons/trash.tres")
	group = &""  # top-level


func _applies(ctx: ActionContext) -> bool:
	if ctx.traversal == null or ctx.tile_interaction == null:
		return false
	var t := ctx.traversal.find_traversal_at(ctx.cell)
	if t == null or not (t is Fence):
		return false
	return not ctx.tile_interaction.is_player_on_traversal(t)


func execute(ctx: ActionContext) -> void:
	ctx.tile_interaction.remove_traversal_at(ctx.cell)
