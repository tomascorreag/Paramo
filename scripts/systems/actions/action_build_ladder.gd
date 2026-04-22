class_name ActionBuildLadder
extends TileAction

# Enter ladder build mode with the clicked floor cell as the origin. Second
# click (handled by TraversalPlacementController) picks the top-landing floor
# on the other side of a NE or NW camera-facing wall.


const _ICON_PATH: String = "res://assets/sprites/UX/icons.png"


func _init() -> void:
	id = &"build_ladder"
	icon = load(_ICON_PATH)
	# Ladder glyph (authored at col 0, row 4 of icons.png).
	icon_region = Rect2(0, 64, 16, 16)
	group = &"build"


func is_available(ctx: ActionContext) -> bool:
	if ctx.tile == null or not ctx.tile.walkable:
		return false
	if ctx.traversal == null:
		return false
	# Origin must be a flat — ladders can't anchor on a ramp (parity with bridge).
	if ctx.tile.altitude_low != ctx.tile.altitude_high:
		return false
	if ctx.tile_interaction != null and ctx.tile_interaction.planted_cells().has(ctx.cell):
		return false
	if ctx.traversal.find_traversal_at(ctx.cell) != null:
		return false
	return true


func execute(ctx: ActionContext) -> void:
	ctx.tile_interaction.begin_traversal(ctx.cell, &"ladder")
