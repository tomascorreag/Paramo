extends Node
## Autoload registered as "ResourceLedger" in project.godot.
## Cannot use class_name — Godot disallows class_name matching an autoload name.

## The single accountant for every spendable resource. All generation and spend
## flows through add()/try_spend() so nothing mutates a resource behind the
## ledger's back. The slice ships with one resource (&"water"); the Dictionary
## shape supports funding and community-support later with no structural change.
##
## Every mutation carries a `source: StringName` tag (&"plant_frailejon",
## &"frailejon_yield", &"laguna_seep", ...). The ledger keeps a cumulative
## per-source tally so the end-screen can name where water came from and went
## without any system having to be retrofitted — the data is captured as it
## happens, not reconstructed.
##
## Why a single accountant (design compass): continuous, UNTRACKED trickles
## invite per-second optimization and erode the "slow, asymmetric" rhetoric.
## Routing everything here keeps generation auditable.
##
## The original stance was that generation must also be season-QUANTIZED. That
## has been relaxed for water: WaterCycle accrues continuously, scaled by live
## rain intensity, because watching the reserve fill while it rains is the whole
## point of the mechanic and a lump sum at the season boundary cannot deliver it.
## The optimization worry doesn't apply to this source — the player has no lever
## on the weather, so there is nothing to optimize against beyond waiting, and
## waiting is what the season clock already charges for. A source that the player
## CAN steer (frailejon yield, laguna seep) should still be season-quantized.

## Emitted on every balance change. delta is signed (negative = spend).
signal resource_changed(id: StringName, value: float, delta: float)

## Emitted the moment a resource crosses to <= 0 (was > 0 before). Loss
## conditions (e.g. water collapse) can listen here instead of polling.
signal resource_depleted(id: StringName)

# id -> current amount
var _amounts: Dictionary = {}
# id -> { source -> cumulative_added } (spends recorded as negative under source)
var _by_source: Dictionary = {}


## Wipe all balances. Call at run start (RunController) so a restart begins
## clean — autoloads persist across scene reloads, so this is mandatory.
func reset() -> void:
	_amounts.clear()
	_by_source.clear()


## Current balance, 0.0 if the resource was never seeded.
func get_amount(id: StringName) -> float:
	return _amounts.get(id, 0.0)


## True if at least `amount` is available. Use to gate actions before spending.
func has(id: StringName, amount: float) -> bool:
	return get_amount(id) >= amount


## Set an absolute starting balance (run setup). Tagged so the end-screen can
## attribute the initial pool distinctly from in-run generation.
func set_amount(id: StringName, value: float, source: StringName = &"initial") -> void:
	var before: float = get_amount(id)
	_amounts[id] = value
	_record_source(id, source, value - before)
	resource_changed.emit(id, value, value - before)
	_check_depleted(id, before, value)


## Add (generation, refunds). amount may be negative, but prefer try_spend()
## for spends so the caller gets the can-I-afford check.
func add(id: StringName, amount: float, source: StringName) -> void:
	var before: float = get_amount(id)
	var after: float = before + amount
	_amounts[id] = after
	_record_source(id, source, amount)
	resource_changed.emit(id, after, amount)
	_check_depleted(id, before, after)


## Atomic spend. Returns false and changes nothing if unaffordable, so callers
## can branch without a separate has() check racing the mutation.
func try_spend(id: StringName, amount: float, source: StringName) -> bool:
	if amount < 0.0:
		push_warning("ResourceLedger.try_spend got negative amount; use add()")
		return false
	if get_amount(id) < amount:
		return false
	add(id, -amount, source)
	return true


## Cumulative net contribution of one source to one resource (spends negative).
## Read by the end-screen tally.
func source_total(id: StringName, source: StringName) -> float:
	var by: Dictionary = _by_source.get(id, {})
	return by.get(source, 0.0)


## All sources that ever touched a resource, source -> net total. For the
## end-screen "where the water went" breakdown.
func source_breakdown(id: StringName) -> Dictionary:
	return (_by_source.get(id, {}) as Dictionary).duplicate()


func _record_source(id: StringName, source: StringName, delta: float) -> void:
	if not _by_source.has(id):
		_by_source[id] = {}
	var by: Dictionary = _by_source[id]
	by[source] = by.get(source, 0.0) + delta


func _check_depleted(id: StringName, before: float, after: float) -> void:
	if before > 0.0 and after <= 0.0:
		resource_depleted.emit(id)
