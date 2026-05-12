class_name ActionBuildLadder
extends TileAction

# Enter ladder build mode with the clicked floor cell as the origin. Second
# click (handled by TraversalPlacementController) picks the top-landing floor
# on the other side of a NE or NW camera-facing wall.


func _init() -> void:
	id = &"build_ladder"
	icon = preload("res://assets/sprites/UX/icons/ladder.tres")
	group = &"build"


func is_available(ctx: ActionContext) -> bool:
	if ctx.tile == null or not ctx.tile.walkable:
		return false
	if ctx.traversal == null:
		return false
	# Origin must be a flat — ladders can't anchor on a ramp (parity with bridge).
	if ctx.tile.altitude_low != ctx.tile.altitude_high:
		return false
	# Single registry query — same pattern as the bridge action.
	if ctx.pathfinder != null:
		var grid := ctx.pathfinder.grid()
		if grid != null and grid.occupant_at(ctx.cell) != null:
			return false
	return true


func execute(ctx: ActionContext) -> void:
	ctx.tile_interaction.begin_traversal(ctx.cell, &"ladder")
