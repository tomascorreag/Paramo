extends GutTest

# Guards the last link in the water chain: the balance the ledger holds is what
# the supplies list on the journal's left page actually prints.
#
# The three failure modes this exists for, all of which look fine in a still:
#   * the journal never connects, so the page shows a frozen authored number
#   * it connects but is never primed, so a journal instanced mid-run shows 0
#     until the next accrual tick
#   * the float balance is ROUNDED, promising a douse the player can't pay for

const JOURNAL_SCENE: PackedScene = preload("res://scenes/ui/field_journal.tscn")
const WATER: StringName = &"water"

var journal: CanvasLayer


func after_each() -> void:
	ResourceLedger.reset()


# Instantiating AFTER seeding the ledger is the point of several of these: it
# reproduces a journal that enters the tree partway through a run.
func _open_journal() -> void:
	journal = JOURNAL_SCENE.instantiate()
	add_child_autofree(journal)


func _printed_water() -> String:
	var label := journal.get_node(
		"Book/BookArt/Pages/PageLeft/SubViewport/Content/Inventory/water/Count") as Label
	return label.text


func test_prints_the_balance_it_was_born_into() -> void:
	ResourceLedger.set_amount(WATER, 7.0)
	_open_journal()
	assert_eq(_printed_water(), "7",
		"a journal opened mid-run must show the CURRENT balance, not the authored stub")


func test_follows_the_balance_as_it_changes() -> void:
	ResourceLedger.set_amount(WATER, 4.0)
	_open_journal()

	ResourceLedger.add(WATER, 3.0, &"rainfall")
	assert_eq(_printed_water(), "7", "accrual must reach the page")

	ResourceLedger.try_spend(WATER, 5.0, &"extinguish_fire")
	assert_eq(_printed_water(), "2", "spending must reach the page too")


func test_fractional_water_floors() -> void:
	# Firefighting costs 1 per cell, so the printed number has to mean "cells I
	# can still douse". 2.9 water buys two douses, not three.
	ResourceLedger.set_amount(WATER, 2.9)
	_open_journal()
	assert_eq(_printed_water(), "2", "floor, never round — the page must not overpromise")


func test_an_empty_reserve_prints_zero() -> void:
	ResourceLedger.set_amount(WATER, 0.0)
	_open_journal()
	assert_eq(_printed_water(), "0")
