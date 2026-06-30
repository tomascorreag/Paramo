extends GutTest

# ResourceLedger has no class_name (autoload restriction). Load the script
# directly and test fresh instances — it has no autoload dependencies.
const ResourceLedgerScript: GDScript = preload("res://scripts/systems/resource_ledger.gd")

const WATER: StringName = &"water"

var ledger: Node


func before_each() -> void:
	ledger = ResourceLedgerScript.new()
	add_child_autofree(ledger)


# --- balances ---------------------------------------------------------------

func test_get_amount_unseeded_is_zero() -> void:
	assert_eq(ledger.get_amount(WATER), 0.0)


func test_set_amount_sets_balance() -> void:
	ledger.set_amount(WATER, 50.0)
	assert_eq(ledger.get_amount(WATER), 50.0)


func test_add_accumulates() -> void:
	ledger.set_amount(WATER, 10.0)
	ledger.add(WATER, 5.0, &"frailejon_yield")
	assert_eq(ledger.get_amount(WATER), 15.0)


func test_has_threshold() -> void:
	ledger.set_amount(WATER, 5.0)
	assert_true(ledger.has(WATER, 5.0))
	assert_false(ledger.has(WATER, 5.01))


# --- try_spend (atomic) -----------------------------------------------------

func test_try_spend_success_deducts_and_returns_true() -> void:
	ledger.set_amount(WATER, 10.0)
	var ok: bool = ledger.try_spend(WATER, 4.0, &"plant_frailejon")
	assert_true(ok)
	assert_eq(ledger.get_amount(WATER), 6.0)


func test_try_spend_insufficient_returns_false_and_no_change() -> void:
	ledger.set_amount(WATER, 3.0)
	var ok: bool = ledger.try_spend(WATER, 4.0, &"plant_frailejon")
	assert_false(ok)
	assert_eq(ledger.get_amount(WATER), 3.0)


func test_try_spend_exact_balance_succeeds() -> void:
	ledger.set_amount(WATER, 4.0)
	assert_true(ledger.try_spend(WATER, 4.0, &"plant_frailejon"))
	assert_eq(ledger.get_amount(WATER), 0.0)


func test_try_spend_negative_rejected() -> void:
	ledger.set_amount(WATER, 4.0)
	assert_false(ledger.try_spend(WATER, -1.0, &"bad"))
	assert_eq(ledger.get_amount(WATER), 4.0)


# --- signals ----------------------------------------------------------------

func test_add_emits_resource_changed() -> void:
	watch_signals(ledger)
	ledger.add(WATER, 5.0, &"seed")
	assert_signal_emitted_with_parameters(ledger, "resource_changed", [WATER, 5.0, 5.0])


func test_try_spend_emits_negative_delta() -> void:
	ledger.set_amount(WATER, 10.0)
	watch_signals(ledger)
	ledger.try_spend(WATER, 3.0, &"plant_frailejon")
	assert_signal_emitted_with_parameters(ledger, "resource_changed", [WATER, 7.0, -3.0])


func test_depleted_emitted_when_crossing_zero() -> void:
	ledger.set_amount(WATER, 3.0)
	watch_signals(ledger)
	ledger.try_spend(WATER, 3.0, &"plant_frailejon")
	assert_signal_emitted(ledger, "resource_depleted")


func test_depleted_not_emitted_when_staying_positive() -> void:
	ledger.set_amount(WATER, 5.0)
	watch_signals(ledger)
	ledger.try_spend(WATER, 1.0, &"plant_frailejon")
	assert_signal_not_emitted(ledger, "resource_depleted")


# --- source tally (end-screen attribution) ----------------------------------

func test_source_total_tracks_net_per_source() -> void:
	ledger.add(WATER, 10.0, &"laguna_seep")
	ledger.try_spend(WATER, 4.0, &"plant_frailejon")
	assert_eq(ledger.source_total(WATER, &"laguna_seep"), 10.0)
	assert_eq(ledger.source_total(WATER, &"plant_frailejon"), -4.0)


func test_source_breakdown_returns_all_sources() -> void:
	ledger.add(WATER, 10.0, &"laguna_seep")
	ledger.try_spend(WATER, 4.0, &"plant_frailejon")
	var breakdown: Dictionary = ledger.source_breakdown(WATER)
	assert_eq(breakdown.size(), 2)
	assert_has(breakdown, &"laguna_seep")
	assert_has(breakdown, &"plant_frailejon")


func test_reset_clears_everything() -> void:
	ledger.set_amount(WATER, 10.0)
	ledger.reset()
	assert_eq(ledger.get_amount(WATER), 0.0)
	assert_eq(ledger.source_breakdown(WATER).size(), 0)
