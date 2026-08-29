class_name FloraCodex
extends Node

## Which species the player has IDENTIFIED this run, by walking up to a plant and
## inspecting it (ActionInspect). The journal's "known flora" section draws only
## what is in here, so the page fills in as the mountain is walked rather than
## arriving printed.
##
## Every plant in ObjectPainter's registry can be identified, grasses included —
## the codex is the record of what the player has SEEN. What the journal shows is
## a narrower question (it has room for the plantable species and no more), and
## that filtering belongs to the page, not here: a discovery this page cannot
## print is still a discovery, and the day the section grows a second row it wants
## the grasses already recorded rather than retro-fitted.
##
## DISCOVERY GATES THE SHOP, which is the mechanical consequence worth stating.
## The known-flora section IS the plant shop surface (JournalKnownSet doubles as
## one), so a species that has never been identified cannot be bought and
## therefore cannot be sown. Restoration follows the survey, which is also how a
## field crew works.
##
## Scene-scoped (gameplay_base.tscn, group "flora_codex"), exactly like
## UnlockState and for the same reason: run state that must die with the scene.
## The journal opening never reloads the scene, so discoveries survive it; a run
## restart reloads it. The season_started(0) clear covers a restart that reuses
## the scene (debug regeneration).
##
## Absent from a scene (preview tools, layout tests, bare action tests) means
## "no discovery system", and every consumer treats that as everything known —
## the same null-means-unrestricted rule ActionContext.unlocks follows.

const GROUP: StringName = &"flora_codex"

## One species just became known. Not emitted for a re-inspection of something
## already recorded — the journal has nothing to redraw for that.
signal discovered(species: StringName)

# Insertion-ordered, so known_ids() reports discovery order. The journal draws in
# AUTHORED order regardless (its cell sizes are index-aligned), but a reader that
# wants "what did I find, in what order" has it without a second structure.
var _known: Dictionary[StringName, bool] = {}


func _ready() -> void:
	add_to_group(GROUP)
	SeasonManager.season_started.connect(_on_season_started)


func is_known(species: StringName) -> bool:
	return _known.has(species)


## Record `species`. True only when this was the FIRST time — the caller uses
## that to tell "added to the journal" from "read it again".
func discover(species: StringName) -> bool:
	if species == &"" or _known.has(species):
		return false
	_known[species] = true
	discovered.emit(species)
	return true


## Every known species, in discovery order.
func known_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for id: StringName in _known:
		out.append(String(id))
	return out


func _on_season_started(index: int, _profile: SeasonProfile) -> void:
	if index == 0:
		_known.clear()
