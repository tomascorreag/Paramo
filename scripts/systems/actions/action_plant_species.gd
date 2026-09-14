class_name ActionPlantSpecies
extends TileAction

# Plant one species on a walkable tile. One instance per plantable species,
# constructed by TileInteractionController with the species id and its icon;
# `id` is `plant_<species>` and `unlock_id` is the species itself, so the
# shop entry, the unlock price and this action all key on the same name.
# Grouped under "plant" — the radial fans the group out from however many
# species the run's ecosystem sells.


var species: StringName = &"frailejon"


func _init(kind: StringName = &"frailejon", icon_tex: Texture2D = null) -> void:
	species = kind
	id = StringName("plant_" + String(kind))
	icon = icon_tex
	group = &"plant"
	unlock_id = kind


func _applies(ctx: ActionContext) -> bool:
	if ctx.tile == null or not ctx.tile.walkable:
		return false
	if ctx.tile_interaction == null:
		return false
	# No stacking — a registered occupant (plant, bridge_deck, ladder, rock)
	# blocks planting, UNLESS it is natural ground cover that yields to a
	# placement (a tussock, a bamboo clump: `is_displaceable`). Without that
	# exception the procgen scatter would lock the player out of a third of
	# the map. Single registry query instead of separate planted_cells /
	# find_traversal_at calls.
	if ctx.pathfinder != null:
		var grid := ctx.pathfinder.grid()
		if grid != null:
			var occ: Node2D = grid.occupant_at(ctx.cell)
			if occ != null and not (
					occ.has_method(&"is_displaceable") and bool(occ.call(&"is_displaceable"))):
				return false
	return true


func execute(ctx: ActionContext) -> void:
	ctx.tile_interaction.plant_species(ctx.cell, species)
