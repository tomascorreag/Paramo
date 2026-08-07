extends GutTest

# Guards the price of firefighting: 1 water per burning cell actually doused,
# spent nearest-the-clicked-cell first, never charging for a cell that stayed
# alight.
#
# White-box against the REAL FireManager and ResourceLedger autoloads, because
# ActionExtinguishFire reaches for both by their global names — a fresh
# FireManager instance (the shape test_fire_manager.gd uses) wouldn't be the one
# the action talks to. Fires are injected straight into _burning rather than
# ignited, since a real ignition needs a painted tileset and a VFX node.

const WATER: StringName = &"water"

var _action: ActionExtinguishFire
var _layer: TileMapLayer


class GridStub:
	extends RefCounted

	var cells: Dictionary = {}

	func get_tile(cell: Vector2i) -> Variant:
		return cells.get(cell)


class TileStub:
	extends RefCounted

	var rise_dir: Vector2i = Vector2i.ZERO
	var altitude_low: int = 0
	var altitude_high: int = 0
	var layer: TileMapLayer = null
	var occupant: Node2D = null
	var tile_kind: StringName = &"FLAT"


var _grid: GridStub


func before_each() -> void:
	_action = ActionExtinguishFire.new()
	_layer = TileMapLayer.new()
	add_child_autofree(_layer)
	_grid = GridStub.new()
	FireManager._grid = _grid
	FireManager._burning.clear()
	ResourceLedger.reset()


func after_each() -> void:
	# The autoloads outlive the test; leaving fires or a balance behind would
	# leak into whatever runs next.
	FireManager._burning.clear()
	FireManager._grid = null
	ResourceLedger.reset()


# A burning entry as _ignite writes it, minus the VFX node (every consumer
# guards it with is_instance_valid, so null is legal). Mirrors
# test_fire_manager.gd's helper.
func _add_burning(cell: Vector2i) -> void:
	var tile := TileStub.new()
	tile.layer = _layer
	_grid.cells[cell] = tile
	FireManager._burning[cell] = {
		"vfx": null,
		"age": 1.0,
		"fuel": 0.5,
		"fuel_max": 1.0,
		"max_intensity": 1.0,
		"frailejon": null,
		"grass_coord": Vector2i(0, 0),
		"grass_layer": _layer,
	}


func _ctx(cell: Vector2i) -> ActionContext:
	var ctx := ActionContext.new()
	ctx.cell = cell
	return ctx


# --- pricing ---------------------------------------------------------------

func test_full_douse_costs_one_per_cell() -> void:
	var center := Vector2i(5, 5)
	_add_burning(center)
	_add_burning(center + Vector2i(1, 0))
	_add_burning(center + Vector2i(0, 1))
	ResourceLedger.set_amount(WATER, 3.0)

	_action.execute(_ctx(center))

	assert_eq(ResourceLedger.get_amount(WATER), 0.0, "3 cells doused must cost 3")
	assert_false(FireManager.is_burning(center))
	assert_false(FireManager.is_burning(center + Vector2i(1, 0)))
	assert_false(FireManager.is_burning(center + Vector2i(0, 1)))


func test_spend_is_tagged_to_the_action() -> void:
	var center := Vector2i(5, 5)
	_add_burning(center)
	_add_burning(center + Vector2i(1, 1))
	ResourceLedger.set_amount(WATER, 5.0)

	_action.execute(_ctx(center))

	assert_eq(ResourceLedger.source_total(WATER, &"extinguish_fire"), -2.0,
		"the end-screen tally must see exactly what firefighting cost")


func test_douses_nothing_and_spends_nothing_with_no_water() -> void:
	var center := Vector2i(5, 5)
	_add_burning(center)
	ResourceLedger.set_amount(WATER, 0.0)

	_action.execute(_ctx(center))

	assert_true(FireManager.is_burning(center), "no water, no douse")
	assert_eq(ResourceLedger.get_amount(WATER), 0.0)


# --- partial douse ---------------------------------------------------------

func test_partial_douse_spends_everything_it_has() -> void:
	var center := Vector2i(5, 5)
	_add_burning(center)
	_add_burning(center + Vector2i(1, 0))
	_add_burning(center + Vector2i(-1, -1))
	ResourceLedger.set_amount(WATER, 2.0)

	_action.execute(_ctx(center))

	assert_eq(ResourceLedger.get_amount(WATER), 0.0, "a partial douse spends the lot")
	assert_eq(FireManager._burning.size(), 1, "exactly one fire survives 2 water")


func test_partial_douse_leaves_the_furthest_fire_burning() -> void:
	# The ordering rule: run out of water and the fires left standing are the
	# ones furthest from where the player clicked, not an arbitrary subset.
	var center := Vector2i(5, 5)
	var far := center + Vector2i(1, 1)      # Chebyshev ring 1
	_add_burning(center)                     # ring 0 — doused first
	_add_burning(far)
	ResourceLedger.set_amount(WATER, 1.0)

	_action.execute(_ctx(center))

	assert_false(FireManager.is_burning(center), "the clicked cell is served first")
	assert_true(FireManager.is_burning(far), "the outer ring is what goes unserved")


func test_clicking_beside_a_fire_still_douses_it() -> void:
	# The action's whole footprint conceit: you can douse by clicking the tile
	# next to the fire, so ring-0 being empty must not stop the loop.
	var fire := Vector2i(5, 5)
	_add_burning(fire)
	ResourceLedger.set_amount(WATER, 1.0)

	_action.execute(_ctx(fire + Vector2i(1, 0)))

	assert_false(FireManager.is_burning(fire))
	assert_eq(ResourceLedger.get_amount(WATER), 0.0)


# --- the dimmed-in-the-wheel gate ------------------------------------------

func test_is_enabled_tracks_one_cell_of_water() -> void:
	var ctx := _ctx(Vector2i(5, 5))

	ResourceLedger.set_amount(WATER, 1.0)
	assert_true(_action.is_enabled(ctx), "one cell's worth is a usable action")

	ResourceLedger.set_amount(WATER, 0.5)
	assert_false(_action.is_enabled(ctx), "below one cell the wheel entry dims")


func test_applies_ignores_the_balance() -> void:
	# _applies answers "is anything on fire", is_enabled answers "can I pay".
	# Merging them would make the action VANISH when broke instead of dimming.
	var center := Vector2i(5, 5)
	_add_burning(center)
	ResourceLedger.set_amount(WATER, 0.0)

	assert_true(_action._applies(_ctx(center)),
		"a broke player must still be OFFERED the action, greyed")
