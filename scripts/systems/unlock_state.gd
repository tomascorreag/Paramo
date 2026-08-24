class_name UnlockState
extends Node

## Which placeable types (bridge, ladder, fence, frailejon) the player has bought
## this run, and the prices. Everything starts LOCKED: a per-type price (see
## `unlock_costs`) unlocks it for the rest of the run (bought in the journal's
## shop pages, which print each entry's own price), and every
## placement is then charged BY THE TILE — 1 token per cell the thing spans,
## charged at commit by the placement controllers and refunded if the build
## fails.
##
## ONE rate, applied to every type. The alternative (a flat per-OBJECT price for
## bridge/ladder/frailejon, per-tile only for the fence) made length free: a
## 12-cell bridge and a single frailejon cost the same, and the cheapest way to
## cross anything was to aim as far as the validator allowed. Per-tile prices the
## span itself, so a long bridge costs what the ladders it replaces would.
##
## PLANTING also costs WATER (`water_cost_types`), 1 per tile. That is the only
## price not paid in tokens: a frailejon is the cheapest thing on the page and
## the only one competing with firefighting for the reserve, so its real cost is
## the douse it takes away. Both currencies move in ONE transaction — a placement
## never takes the tokens and then refuses for want of water.
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
const WATER: StringName = &"water"

## One-time price per type, cheapest verb first. The ladder is the entry-level
## move (one cell, fixes one wall), the bridge spans, and the fence is the
## crowd-control tool a player only wants once they understand visitors — so the
## price ladder doubles as a soft ordering of the verbs.
##
## The frailejon is priced WITH the ladder rather than above it because it is the
## only build that needs no terrain feature to be legal (a ladder needs an
## altitude step, a bridge a gap): at the run's opening balance it has to be
## affordable, or a player whose starting cell has no wall nearby cannot build
## anything at all.
@export var unlock_costs: Dictionary[StringName, float] = {
	&"ladder": 10.0,
	&"frailejon": 10.0,
	&"bridge": 20.0,
	&"fence": 30.0,
}

## Price for a type with no `unlock_costs` entry. A new placeable is priced by
## being listed above; this is what it costs until someone does.
@export var unlock_cost: float = 20.0
## Tokens per TILE a placement spans. The only placement rate there is.
@export var placement_cost_per_tile: float = 1.0
## Water per TILE, charged only for the types in `water_cost_types`.
@export var placement_water_cost_per_tile: float = 1.0
## Types whose placement also costs water. Data, not a class check, so a future
## planted thing joins by being listed rather than by touching this file.
@export var water_cost_types: Array[StringName] = [&"frailejon"]

signal unlock_changed(type: StringName)
## A placement was actually PAID FOR — every build funnels through
## try_pay_placements, so this is the one place that sees "the player built
## something" regardless of which controller did it (frailejon goes through
## TileInteractionController, the traversals through
## TraversalPlacementController). Emitted at charge time, before the thing is
## instanced; a build that then fails is followed by refund_placements, which
## does NOT emit. The FTUE's build step listens here.
signal placement_paid(type: StringName, count: int)

var _unlocked: Dictionary = {}


func _ready() -> void:
	add_to_group(GROUP)
	SeasonManager.season_started.connect(_on_season_started)


func is_unlocked(type: StringName) -> bool:
	return _unlocked.has(type)


## What `type` costs to unlock. The fallback covers anything unpriced.
func unlock_cost_for(type: StringName) -> float:
	return float(unlock_costs.get(type, unlock_cost))


## Prices differ per type, so this asks about ONE of them. The no-argument form
## answers for the fallback price, which is only meaningful to a caller that has
## no type in hand.
func can_afford_unlock(type: StringName = &"") -> bool:
	return ResourceLedger.has(TOKENS, unlock_cost_for(type))


## "Could the player pay for `count` tiles of `type` right now?" — both
## currencies, so a plant with tokens but no water reads as unaffordable.
## `type` defaults to the token-only case, which is what a caller that has no
## particular type in hand (the radial menu's generic gate) is asking about.
func can_afford_placement(type: StringName = &"", count: int = 1) -> bool:
	if count <= 0:
		return true
	return ResourceLedger.has(TOKENS, placement_cost_per_tile * count) \
			and ResourceLedger.has(WATER, water_cost(type, count))


## Water due for `count` tiles of `type`; 0 for everything not planted.
func water_cost(type: StringName, count: int = 1) -> float:
	if count <= 0 or not water_cost_types.has(type):
		return 0.0
	return placement_water_cost_per_tile * count


## One-time purchase. False without spending when already owned (a double
## click on the shop entry must not charge twice) or when unaffordable.
func try_unlock(type: StringName) -> bool:
	if is_unlocked(type):
		return false
	if not ResourceLedger.try_spend(TOKENS, unlock_cost_for(type),
			StringName("unlock_" + String(type))):
		return false
	_unlocked[type] = true
	unlock_changed.emit(type)
	return true


## Charged by the placement controllers at COMMIT (after validation passes),
## never at menu click — a cancelled build mode must cost nothing. One tile;
## `try_pay_placements` is the same charge for a multi-cell build.
func try_pay_placement(type: StringName) -> bool:
	return try_pay_placements(type, 1)


## Charge for `count` TILES of `type` in ONE transaction, all or nothing.
##
## A fence run places N independent one-cell fences at once, and paying for them
## one at a time would let the money run out midway and leave half a wall — so
## the whole run has to be affordable before any of it goes down. Single ledger
## entry per currency, so the end-screen tally reads as one purchase rather
## than N.
##
## Both currencies are checked BEFORE either is spent. The rollback on the water
## leg is unreachable while nothing else can mutate the ledger between the two
## calls, and is kept because "unreachable" is a property of today's callers,
## not of the ledger.
func try_pay_placements(type: StringName, count: int) -> bool:
	if count <= 0:
		return true
	var tokens_due: float = placement_cost_per_tile * count
	var water_due: float = water_cost(type, count)
	if not ResourceLedger.has(TOKENS, tokens_due) \
			or not ResourceLedger.has(WATER, water_due):
		return false
	var source := StringName("place_" + String(type))
	if not ResourceLedger.try_spend(TOKENS, tokens_due, source):
		return false
	if water_due > 0.0 and not ResourceLedger.try_spend(WATER, water_due, source):
		ResourceLedger.add(TOKENS, tokens_due, source)
		return false
	placement_paid.emit(type, count)
	return true


## How many tiles of a placement the balance covers right now, capped at `want`.
## The placement preview clamps its run to this so the ghost stops where the
## money stops instead of turning red at the far end. Water-costed types are
## clamped by whichever currency runs out first.
func max_affordable_tiles(want: int, type: StringName = &"") -> int:
	if want <= 0:
		return 0
	var budget: int = want
	if placement_cost_per_tile > 0.0:
		budget = mini(budget, int(floorf(
				ResourceLedger.get_amount(TOKENS) / placement_cost_per_tile)))
	if water_cost_types.has(type) and placement_water_cost_per_tile > 0.0:
		budget = mini(budget, int(floorf(
				ResourceLedger.get_amount(WATER) / placement_water_cost_per_tile)))
	return clampi(budget, 0, want)


## Undo of try_pay_placement for the build()-failed path. Books under the same
## source so the end-screen tally nets to what was actually built.
func refund_placement(type: StringName) -> void:
	refund_placements(type, 1)


## Undo of try_pay_placements — every currency the charge took, or the tally the
## end screen reads stops netting to what was actually built.
func refund_placements(type: StringName, count: int) -> void:
	if count <= 0:
		return
	var source := StringName("place_" + String(type))
	ResourceLedger.add(TOKENS, placement_cost_per_tile * count, source)
	var water_due: float = water_cost(type, count)
	if water_due > 0.0:
		ResourceLedger.add(WATER, water_due, source)


func _on_season_started(index: int, _profile: SeasonProfile) -> void:
	if index == 0:
		_unlocked.clear()
