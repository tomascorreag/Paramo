class_name ActionInspect
extends TileAction

# Identify the plant on this cell: name it on screen and write it into the run's
# FloraCodex, which is what the journal's "known flora" section prints. It is the
# only way that page fills in.
#
# It used to dump CellData to a debug toast, and that use is gone: a verb that
# means "read the grid" on every walkable tile and "identify this plant" on some
# of them is two verbs sharing an icon, and only one of them is a game.
#
# Offered on a plant whether or not it is already known — the toast names it
# again, which is the whole content of re-reading a field note. The state that
# changes is the ICON: gold while the species is unrecorded (icon_for), plain
# once it is in the book.

const _DISPLAY_DURATION: float = 2.5

# Same glyph, gold glass — assets/sprites/UX/icons.png, painted from palette2
# entry 12 (Palette.ACCENT, the gold this project already uses for "look here").
const _ICON_KNOWN: Texture2D = preload("res://assets/sprites/UX/icons/magnifying_glass.tres")
const _ICON_NEW: Texture2D = preload("res://assets/sprites/UX/icons/magnifying_glass_new.tres")


func _init() -> void:
	id = &"inspect"
	icon = _ICON_KNOWN
	group = &""


func _applies(ctx: ActionContext) -> bool:
	return species_at(ctx) != &""


# Distance 0 as well as 1: plants don't block movement, so the player can be
# standing ON the tussock they want named. The default rule (Chebyshev == 1)
# would refuse exactly there, which reads as the verb breaking when you get
# closest to the thing.
func _range_ok(target: Vector2i, standing: Vector2i) -> bool:
	var d: Vector2i = target - standing
	return maxi(absi(d.x), absi(d.y)) <= 1


func icon_for(ctx: ActionContext) -> Texture2D:
	return _ICON_KNOWN if _is_known(ctx, species_at(ctx)) else _ICON_NEW


func execute(ctx: ActionContext) -> void:
	var species := species_at(ctx)
	if species == &"":
		return
	if ctx.flora_codex != null and ctx.flora_codex.has_method(&"discover"):
		ctx.flora_codex.call(&"discover", species)
	var data: WorldObjectData = ObjectPainter.data_for(species)
	if ctx.tile_interaction == null or data == null or data.name_key == &"":
		return
	ctx.tile_interaction.show_toast(data.name_key, _DISPLAY_DURATION)


## The plant species occupying `ctx.cell`, or &"" when there is nothing to
## identify. Public so tests can ask the same question the menu does.
##
## Plants only: the occupant registry also holds rocks and structure decks, and
## a magnifier over a rock promises a journal entry that does not exist. The
## check is on the DATA (`is PlantObjectData`) rather than on the node's class,
## because every species — grasses included — is the same `Frailejon` scene with
## a different .tres.
func species_at(ctx: ActionContext) -> StringName:
	if ctx == null or ctx.pathfinder == null:
		return &""
	var grid := ctx.pathfinder.grid()
	if grid == null:
		return &""
	var occ: Node2D = grid.occupant_at(ctx.cell)
	if occ == null or not occ.has_method(&"occupant_kind"):
		return &""
	var kind: StringName = occ.call(&"occupant_kind")
	return kind if ObjectPainter.data_for(kind) is PlantObjectData else &""


# No codex in the scene = no discovery system = everything known, so the plain
# glyph is the honest one there (preview tools, bare action tests).
func _is_known(ctx: ActionContext, species: StringName) -> bool:
	if species == &"" or ctx.flora_codex == null \
			or not ctx.flora_codex.has_method(&"is_known"):
		return true
	return bool(ctx.flora_codex.call(&"is_known", species))
