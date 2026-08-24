extends GutTest

# Guards the last link in the water chain: the balance the ledger holds is what the
# supplies row on the journal's RIGHT page actually prints. (It printed on the left
# page as `Inventory` until the calendar's day stats took that page over.)
#
# The failure modes this exists for, all of which look fine in a still:
#   * a journal instanced mid-run shows the authored stub instead of the balance
#   * the page never repaints when the balance moves
#   * the float balance is ROUNDED, promising a douse the player can't pay for
#
# Two of those used to be live risks because the old Inventory CACHED the number
# into a Label and depended on being primed and connected. JournalResources reads
# the ledger inside its own draw instead, so "never primed" is now structurally
# impossible — but the repaint connection is not, and that is asserted below.

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


func _resources() -> JournalResources:
	return journal.get_node(
		"Book/BookArt/Pages/PageRight/SubViewport/Content/Resources") as JournalResources


# The column index the water glyph prints in — asserted rather than assumed, since
# everything below reads that column.
func _water_column() -> int:
	var ids := _resources().resource_ids
	var i: int = Array(ids).find(String(WATER))
	assert_gte(i, 0, "the supplies row must carry a water column")
	return i


func _printed_water() -> int:
	return _resources().amount(_water_column())


func test_prints_the_balance_it_was_born_into() -> void:
	ResourceLedger.set_amount(WATER, 7.0)
	_open_journal()
	assert_eq(_printed_water(), 7,
		"a journal opened mid-run must show the CURRENT balance, not the authored stub")


func test_follows_the_balance_as_it_changes() -> void:
	ResourceLedger.set_amount(WATER, 4.0)
	_open_journal()

	ResourceLedger.add(WATER, 3.0, &"rainfall")
	assert_eq(_printed_water(), 7, "accrual must reach the page")

	ResourceLedger.try_spend(WATER, 5.0, &"extinguish_fire")
	assert_eq(_printed_water(), 2, "spending must reach the page too")


func test_a_change_repaints_the_page() -> void:
	# The number is read at DRAW time, so a missed connection does not show a stale
	# value in a test — it shows a stale value on screen until something else
	# happens to repaint. Only the connection itself can catch that.
	_open_journal()
	assert_true(
		ResourceLedger.resource_changed.is_connected(_resources()._on_resource_changed),
		"the supplies row must repaint when the ledger moves")


func test_fractional_water_floors() -> void:
	# Firefighting costs 1 per cell, so the printed number has to mean "cells I
	# can still douse". 2.9 water buys two douses, not three.
	ResourceLedger.set_amount(WATER, 2.9)
	_open_journal()
	assert_eq(_printed_water(), 2, "floor, never round — the page must not overpromise")


func test_an_empty_reserve_prints_zero() -> void:
	ResourceLedger.set_amount(WATER, 0.0)
	_open_journal()
	assert_eq(_printed_water(), 0)
