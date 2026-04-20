class_name ActionRemoveBridge
extends TileAction

# Trash: remove an existing bridge. Suppressed when the player is currently
# standing anywhere on that bridge (would strand them).


const _ICON_PATH: String = "res://assets/sprites/UX/icons.png"


func _init() -> void:
	id = &"remove_bridge"
	icon = load(_ICON_PATH)
	icon_region = Rect2(32, 32, 16, 16)
	group = &""  # top-level


func is_available(ctx: ActionContext) -> bool:
	if ctx.traversal == null or ctx.tile_interaction == null:
		return false
	var t := ctx.traversal.find_traversal_at(ctx.cell)
	if t == null:
		return false
	return not ctx.tile_interaction.is_player_on_traversal(t)


func execute(ctx: ActionContext) -> void:
	ctx.tile_interaction.remove_bridge(ctx.cell)
