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
#
# The coordinator SAYS the name rather than the screen labelling it ("¡Un
# chusque!", "Esto es un frailejón."), which is what makes identifying a plant
# read as a person recognising it instead of a tooltip firing. Two registers,
# picked from `_LINES_NEW` / `_LINES_KNOWN` by whether this was the first
# sighting, and never the same phrasing twice running.

const _DISPLAY_DURATION: float = 2.5

# What the coordinator says. Two registers, because naming a plant for the first
# time and re-reading a note you already wrote are different moments, and the
# codex already tells us which one this is (`discover` returns true only once).
#
# Every line takes the species as `{0}` — not the bare name but a NOUN PHRASE,
# article included, because Spanish articles agree with the noun and "esto es un
# cortadera" is wrong. Which article a line wants is part of the line: "esto es
# {0}" needs an indefinite ("un chusque"), "otra mirada {0}" a definite one
# contracted with its preposition ("al chusque"). Hence the pairing below.
#
# Clauses carry NO terminal punctuation — `_STATEMENT` / `_EXCLAMATION` wrap
# that on, which is what lets a first sighting land as either and keeps the
# Spanish opening ¡ attached to the right one.
#
# Keys are quoted literals so tests/test_localization.gd's script scan finds
# them; a computed key would ship a missing string as the key itself.
enum _Article {
	INDEFINITE,  ## "a chusque" / "un chusque"
	AT_THE,      ## the slot after "look at": "the chusque" / "al chusque"
}

const _LINES_NEW: Array[Dictionary] = [
	{&"key": &"NARRATIVE_INSPECT_NEW_1", &"article": _Article.INDEFINITE},
	{&"key": &"NARRATIVE_INSPECT_NEW_2", &"article": _Article.INDEFINITE},
	{&"key": &"NARRATIVE_INSPECT_NEW_3", &"article": _Article.INDEFINITE},
	{&"key": &"NARRATIVE_INSPECT_NEW_4", &"article": _Article.INDEFINITE},
]
const _LINES_KNOWN: Array[Dictionary] = [
	{&"key": &"NARRATIVE_INSPECT_KNOWN_1", &"article": _Article.INDEFINITE},
	{&"key": &"NARRATIVE_INSPECT_KNOWN_2", &"article": _Article.INDEFINITE},
	{&"key": &"NARRATIVE_INSPECT_KNOWN_3", &"article": _Article.AT_THE},
]

# [article][gender] -> the CSV key holding that word. Indexed by
# WorldObjectData.NameGender, so the rows must stay in that enum's order.
const _ARTICLE_KEYS: Array[Array] = [
	[&"GRAMMAR_ARTICLE_INDEFINITE_M", &"GRAMMAR_ARTICLE_INDEFINITE_F"],
	[&"GRAMMAR_ARTICLE_AT_THE_M", &"GRAMMAR_ARTICLE_AT_THE_F"],
]

# A first sighting is worth an exclamation about half the time; re-reading a
# note you already wrote is not, and always takes the full stop.
const _STATEMENT: StringName = &"GRAMMAR_STATEMENT"
const _EXCLAMATION: StringName = &"GRAMMAR_EXCLAMATION"

# Index of the last line used, so the same phrasing never lands twice running.
# ActionRegistry holds one instance for the run, so this persists across
# inspections; -1 until the first one.
var _last_line: int = -1

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
	# No codex = no discovery system, so nothing is ever "new" — the same rule
	# icon_for follows, and it keeps preview tools off the first-sighting lines.
	var first_sighting := false
	if ctx.flora_codex != null and ctx.flora_codex.has_method(&"discover"):
		first_sighting = bool(ctx.flora_codex.call(&"discover", species))
	var data: WorldObjectData = ObjectPainter.data_for(species)
	if ctx.tile_interaction == null or data == null or data.name_key == &"":
		return
	ctx.tile_interaction.show_message(
		line_for(data, first_sighting), _DISPLAY_DURATION)


## The sentence the coordinator says on identifying `data`. Public so tests can
## read it without a TileInteractionController in the tree.
func line_for(data: WorldObjectData, first_sighting: bool) -> String:
	var line := _next_line(_LINES_NEW if first_sighting else _LINES_KNOWN)
	var phrase := noun_phrase(data, line[&"article"] as int)
	var clause := tr(line[&"key"] as StringName).format([phrase])
	# Only a discovery gets to be excited, and only about half the time.
	var punctuation: StringName = _STATEMENT
	if first_sighting and randi() % 2 == 0:
		punctuation = _EXCLAMATION
	return _sentence_case(tr(punctuation).format([clause]))


## "un chusque" / "una cortadera" / "al chusque", per `article` and the species'
## authored gender. Public because it is the piece worth testing directly.
func noun_phrase(data: WorldObjectData, article: int) -> String:
	var gender: int = clampi(int(data.name_gender), 0, 1)
	return "%s %s" % [tr(_ARTICLE_KEYS[article][gender]), tr(String(data.name_key))]


# Uniform over the OTHER lines, so consecutive inspections never repeat. With
# one line authored it degenerates to that line rather than looping forever.
func _next_line(lines: Array[Dictionary]) -> Dictionary:
	if lines.size() <= 1:
		return lines[0]
	var i := randi() % lines.size()
	if i == _last_line:
		i = (i + 1) % lines.size()
	_last_line = i
	return lines[i]


# Upper-case the first LETTER, which is not always the first character: Spanish
# opens a question or an exclamation with ¿ / ¡. Templates can then put the
# species first ("¡{0}!") without the article arriving lower-case mid-sentence,
# and a template that already starts capitalised is returned untouched.
func _sentence_case(s: String) -> String:
	for i in s.length():
		var c := s[i]
		if c.to_upper() != c:
			return s.substr(0, i) + c.to_upper() + s.substr(i + 1)
		if c.to_lower() != c:
			return s
	return s


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
