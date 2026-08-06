class_name UnlockState
extends Node

## Which placeable types (bridge, ladder, frailejon) the player has bought this
## run, and the token prices. Everything starts LOCKED: 10 tokens unlocks a
## type for the rest of the run (bought in the journal's shop pages), and each
## placement then costs 5 more (charged at commit by the placement
## controllers, refunded if the build fails).
##
## Scene-scoped (gameplay_base.tscn, group "unlocks") — run state that must
## die with the scene. The journal opening/closing never reloads the scene, so
## purchases survive it; a run restart reloads the scene and resets naturally.
## The season_started(0) clear is belt-and-braces for a restart that reuses
## the scene (debug regeneration).
##
## Consumers reach it loosely: TileInteractionController injects it into
## ActionContext.unlocks; a null there (bare test scenes, tools) means
## "everything unlocked and free", so existing action tests stay green.

const GROUP: StringName = &"unlocks"
const TOKENS: StringName = &"tokens"

## One-time price to unlock a type. 2 visitors' worth.
@export var unlock_cost: float = 10.0
## Price of each placement of an unlocked type. 1 visitor's worth.
@export var placement_cost: float = 5.0

signal unlock_changed(type: StringName)

var _unlocked: Dictionary = {}


func _ready() -> void:
	add_to_group(GROUP)
	SeasonManager.season_started.connect(_on_season_started)


func is_unlocked(type: StringName) -> bool:
	return _unlocked.has(type)


func can_afford_unlock() -> bool:
	return ResourceLedger.has(TOKENS, unlock_cost)


func can_afford_placement() -> bool:
	return ResourceLedger.has(TOKENS, placement_cost)


## One-time purchase. False without spending when already owned (a double
## click on the shop entry must not charge twice) or when unaffordable.
func try_unlock(type: StringName) -> bool:
	if is_unlocked(type):
		return false
	if not ResourceLedger.try_spend(TOKENS, unlock_cost,
			StringName("unlock_" + String(type))):
		return false
	_unlocked[type] = true
	unlock_changed.emit(type)
	return true


## Charged by the placement controllers at COMMIT (after validation passes),
## never at menu click — a cancelled build mode must cost nothing.
func try_pay_placement(type: StringName) -> bool:
	return ResourceLedger.try_spend(TOKENS, placement_cost,
			StringName("place_" + String(type)))


## Undo of try_pay_placement for the build()-failed path. Books under the same
## source so the end-screen tally nets to what was actually built.
func refund_placement(type: StringName) -> void:
	ResourceLedger.add(TOKENS, placement_cost, StringName("place_" + String(type)))


func _on_season_started(index: int, _profile: SeasonProfile) -> void:
	if index == 0:
		_unlocked.clear()
