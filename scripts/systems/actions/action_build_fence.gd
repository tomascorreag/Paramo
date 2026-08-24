class_name ActionBuildFence
extends TileAction

# Enter fence build mode with the clicked cell as the near end of the run.
# Second click (handled by TraversalPlacementController) picks the far end.


func _init() -> void:
	id = &"build_fence"
	icon = preload("res://assets/sprites/UX/icons/fence.tres")
	group = &"build"
	unlock_id = &"fence"


func _applies(ctx: ActionContext) -> bool:
	if ctx.tile == null or not ctx.tile.walkable:
		return false
	if ctx.traversal == null:
		return false
	# Flats only — a post has no single altitude to stand on a ramp. Validate
	# enforces it for the whole run; suppressing the option here keeps the menu
	# honest about the cell you actually clicked.
	if ctx.tile.altitude_low != ctx.tile.altitude_high:
		return false
	# Never offer a fence on the cell the player is standing on: every cell of
	# the run becomes non-walkable, so this one would wall them in on the spot.
	# Bridge/ladder have no equivalent check because they stay walkable.
	if ctx.cell == ctx.player_cell:
		return false
	# Don't offer on cells already claimed by any occupant. Single registry
	# query covers frailejones, traversals, rocks, other fences.
	if ctx.pathfinder != null:
		var grid := ctx.pathfinder.grid()
		if grid != null and grid.occupant_at(ctx.cell) != null:
			return false
	return true


func execute(ctx: ActionContext) -> void:
	ctx.tile_interaction.begin_traversal(ctx.cell, &"fence")
