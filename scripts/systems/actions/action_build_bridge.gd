class_name ActionBuildBridge
extends TileAction

# Enter bridge build mode with the clicked cell as the origin endpoint.
# Second click (handled by TraversalPlacementController) picks the far end.


func _init() -> void:
	id = &"build_bridge"
	icon = preload("res://assets/sprites/UX/icons/bridge.tres")
	group = &"build"


func is_available(ctx: ActionContext) -> bool:
	if ctx.tile == null or not ctx.tile.walkable:
		return false
	if ctx.traversal == null:
		return false
	# Origin must be a flat (ramps can't anchor a bridge endpoint — validate
	# enforces this too, but suppressing the option keeps the menu honest).
	if ctx.tile.altitude_low != ctx.tile.altitude_high:
		return false
	# Don't offer bridge on occupied cells.
	if ctx.tile_interaction != null and ctx.tile_interaction.planted_cells().has(ctx.cell):
		return false
	if ctx.traversal.find_traversal_at(ctx.cell) != null:
		return false
	return true


func execute(ctx: ActionContext) -> void:
	ctx.tile_interaction.begin_traversal(ctx.cell, &"bridge")
