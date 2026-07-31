extends GutTest

# Guards the world-lifetime rules of FireManager — which events are allowed to
# put fires out. The regression these exist for: Pathfinder.rebuild() runs on
# every structure placement (bridge, ladder, rock removal), so treating its
# graph_changed as "a new world arrived" extinguished every fire on the map the
# instant the player built anything.
#
# White-box: FireManager is an autoload that needs a Pathfinder, a TileGrid and
# a painted map to run for real. These inject the minimum stubs and call the
# handlers directly, as the signals would.

const MANAGER_SCRIPT: String = "res://scripts/systems/fire_manager.gd"


# Stands in for TileGrid: answers get_tile for a fixed set of cells, null
# elsewhere (that null is exactly what marks a burning cell stale after a
# rebuild shrinks the playable bounds).
class GridStub:
	extends RefCounted

	var cells: Dictionary = {}

	func get_tile(cell: Vector2i) -> Variant:
		return cells.get(cell)


# The slice of CellData FireManager reads while a fire is live: the flat/altitude
# fields its spread rule tests. A flat tile with no painted neighbours means the
# manager's real _process can run over these fixtures without erroring.
class TileStub:
	extends RefCounted

	var rise_dir: Vector2i = Vector2i.ZERO
	var altitude_low: int = 0
	var altitude_high: int = 0
	var layer: TileMapLayer = null
	var occupant: Node2D = null
	var tile_kind: StringName = &"FLAT"


class PathfinderStub:
	extends Node

	var stub_grid: GridStub = null

	func grid() -> Variant:
		return stub_grid


var _manager: Node = null
var _layer: TileMapLayer = null
var _grid: GridStub = null


func before_each() -> void:
	_manager = load(MANAGER_SCRIPT).new()
	add_child_autofree(_manager)
	_layer = TileMapLayer.new()
	add_child_autofree(_layer)
	_grid = GridStub.new()


# A burning entry as _ignite writes it, minus the VFX node (whose _ready needs a
# real tileset). Every consumer guards it with is_instance_valid, so null is a
# legal value here.
func _add_burning(cell: Vector2i) -> void:
	var tile := TileStub.new()
	tile.layer = _layer
	_grid.cells[cell] = tile
	_manager._grid = _grid
	_manager._burning[cell] = {
		"vfx": null,
		"age": 1.0,
		"fuel": 0.5,
		"fuel_max": 1.0,
		"max_intensity": 1.0,
		"frailejon": null,
		"grass_coord": Vector2i(0, 0),
		"grass_layer": _layer,
	}


func test_graph_changed_does_not_put_fires_out() -> void:
	# The build path: place a structure -> Pathfinder.rebuild() -> graph_changed.
	var cell := Vector2i(4, 7)
	_add_burning(cell)

	var pf := PathfinderStub.new()
	pf.stub_grid = _grid
	add_child_autofree(pf)
	_manager._pathfinder = pf

	_manager._on_graph_changed()
	# The handler defers its grid refresh (Pathfinder emits from inside
	# rebuild()), so let the idle callback land before asserting.
	await get_tree().process_frame
	await get_tree().process_frame

	assert_true(_manager.is_burning(cell),
		"a graph rebuild is not a new world — the fire must keep burning")


func test_graph_changed_drops_cells_the_new_grid_no_longer_has() -> void:
	# The legitimate half of the old wipe: a rebuild whose grid no longer
	# describes the cell (e.g. bounds_clip shrank the playable area).
	var cell := Vector2i(4, 7)
	_add_burning(cell)
	_grid.cells.erase(cell)

	_manager._prune_stale_burns()

	assert_false(_manager.is_burning(cell),
		"a cell the rebuilt grid has no tile for must be dropped")


func test_prune_drops_cells_whose_layer_left_the_tree() -> void:
	var cell := Vector2i(4, 7)
	_add_burning(cell)
	_layer.get_parent().remove_child(_layer)

	_manager._prune_stale_burns()

	assert_false(_manager.is_burning(cell),
		"a fire whose TileMapLayer is gone can no longer be repainted — drop it")


func test_attaching_to_a_different_pathfinder_wipes() -> void:
	# Scene reload: the autoload survives, the world doesn't.
	var cell := Vector2i(4, 7)
	_add_burning(cell)
	var first := PathfinderStub.new()
	add_child_autofree(first)
	_manager._pathfinder = first

	var second := PathfinderStub.new()
	second.stub_grid = _grid
	add_child_autofree(second)
	_manager._attach_to_pathfinder(second)

	assert_false(_manager.is_burning(cell),
		"a different Pathfinder means a different world — fires go with it")


func test_wipe_clears_every_fire() -> void:
	_add_burning(Vector2i(1, 1))
	_add_burning(Vector2i(2, 2))

	_manager._wipe_all_fires()

	assert_eq(_manager._burning.size(), 0, "a wipe must leave no burning cells")
