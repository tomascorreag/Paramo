extends GutTest

# Guards the damage → regrowth arc over the single per-cell vegetation value:
# burnout hands the pre-burn grass coord to the manager (the payload D3 added to
# tile_burned — before it, the coord died with the burn entry and a burned cell
# was dirt FOREVER), feet wear the same value down a little per step, recovery
# adds it back daily scaled by rain, and the appeal factor VisitorFlow reads is
# the fraction of the mountain's grass still standing.
#
# White-box against the real FireManager autoload (burn entries injected, then
# _complete_burn called) because the manager subscribes to the real autoload's
# signal in _ready. day_completed is driven by calling the handler directly —
# emitting the real TimeManager signal would also advance SeasonManager.
#
# Most tests set recovery_rate_spread = 0. The per-cell multiplier exists so
# scars heal PATCHILY, which is a property of a population of cells; leaving it
# on would make every single-cell assertion below a coin flip. Its own test
# turns it back up.

var _regrowth: RegrowthManager
var _layer: TileMapLayer


class RainStub:
	extends Node

	var intensity: float = 0.0

	func _ready() -> void:
		add_to_group(&"day_night_controller")

	func get_rain_current_intensity() -> float:
		return intensity


# Stands in for TileGrid — the same shape test_fire_manager injects. Trampling
# reads a cell's layer and kind through FireManager.grid() to find out what it
# is walking on.
class GridStub:
	extends RefCounted

	var cells: Dictionary = {}

	# Trampling forwards a footfall to whatever is standing on the cell, so
	# the stub grid has to answer the same occupant query the real TileGrid
	# does. Empty in every test that is only about grass.
	var occupants: Dictionary = {}

	func get_tile(cell: Vector2i) -> Variant:
		return cells.get(cell)

	func occupant_at(cell: Vector2i) -> Object:
		return occupants.get(cell)

	func cell_count() -> int:
		return cells.size()

	# The colonisation pass walks the grid's bounds once to find every cell
	# generation painted dirt. Derived from the placed cells rather than fixed,
	# so the pass runs over exactly the fixture in front of it — including in
	# the tests below that place no dirt at all, which is the cheapest way to
	# keep proving that seeding leaves the damage path alone.
	func bounds() -> Rect2i:
		var r := Rect2i()
		var first: bool = true
		for cell: Vector2i in cells:
			if first:
				r = Rect2i(cell, Vector2i.ONE)
				first = false
			else:
				r = r.expand(cell).expand(cell + Vector2i.ONE)
		return r


# Stands in for a Frailejon: the manager only knows that an occupant may have
# a trample() method, so anything that does is a plant as far as it is
# concerned.
class PlantStub:
	extends Node2D

	var wear_taken: float = 0.0

	func trample(amount: float) -> void:
		wear_taken += amount


# An occupant that is NOT a plant — a fence, a bridge deck, a rock. Feet must
# not error on it.
class MuteOccupantStub:
	extends Node2D


class TileStub:
	extends RefCounted

	var layer: TileMapLayer = null
	var tile_kind: StringName = &"FLAT"
	# Only dirt the player can stand on colonises; underwater fill and cliff
	# backing are dirt too and must not sprout grass on a vertical face.
	var walkable: bool = true


# The longest rung of each shipped tone, so the ladder tests below start with
# the most to lose. Named rather than derived because the POINT of those tests is
# what the atlas authors — deriving them from GrassLadder would make them pass
# against any ladder at all, including an empty one.
const _TALL_WARM: Vector2i = Vector2i(0, 4)
const _TALL_COOL: Vector2i = Vector2i(1, 4)

var _rain: RainStub
var _grid: GridStub
var _grass_coord: Vector2i
var _phase_before: int
var _paused_before: bool
var _grid_before: Object


func before_each() -> void:
	_phase_before = SeasonManager.phase
	_paused_before = TimeManager.paused
	TimeManager.paused = true
	SeasonManager.phase = SeasonManager.Phase.ACTIVE
	FireManager._burning.clear()
	_grid_before = FireManager.grid()

	_rain = RainStub.new()
	add_child_autofree(_rain)
	_layer = TileMapLayer.new()
	# The REAL tileset, because trampling has to pick a dirt variant out of it
	# and a stub would only prove the stub works. It also supplies a grass coord
	# that genuinely exists, rather than one hardcoded here and silently wrong
	# after an atlas edit.
	_layer.tile_set = load("res://resources/tiles/base_tileset.tres")
	var grass_src := _layer.tile_set.get_source(RegrowthManager.SOURCE_GRASS) \
			as TileSetAtlasSource
	_grass_coord = grass_src.get_tile_id(0)
	add_child_autofree(_layer)
	_grid = GridStub.new()
	_regrowth = RegrowthManager.new()
	add_child_autofree(_regrowth)
	# Single-cell assertions want a single answer — see the header.
	_regrowth.recovery_rate_spread = 0.0


func after_each() -> void:
	SeasonManager.phase = _phase_before
	TimeManager.paused = _paused_before
	FireManager._burning.clear()
	FireManager._grid = _grid_before


# Advance the clock by `days` and let recovery catch up.
#
# Recovery is no longer a day-boundary event, so there is no handler to call:
# it is integrated inside tick() against a monotonic clock. Driving the real
# entry point is also the more honest test — it exercises the gates (paused, run
# phase) that the old direct call skipped.
#
# seconds_per_game_day is pinned to 1 so `days` reads as days, and sweep_seconds
# is dropped below the step so a single tick visits the WHOLE ledger. Cadence
# cannot change the amount recovered — that is the property the design rests on
# — so a test is free to choose the cadence that makes it deterministic.
func _advance_days(days: float = 1.0) -> void:
	var was_paused: bool = TimeManager.paused
	var per_day: float = TimeManager.seconds_per_game_day
	var scale: float = TimeManager.time_scale
	var sweep: float = _regrowth.sweep_seconds
	TimeManager.paused = false
	TimeManager.seconds_per_game_day = 1.0
	TimeManager.time_scale = 1.0
	_regrowth.sweep_seconds = 0.0001
	_regrowth.tick(days)
	_regrowth.sweep_seconds = sweep
	TimeManager.paused = was_paused
	TimeManager.seconds_per_game_day = per_day
	TimeManager.time_scale = scale


# Paint `cell` as grass and make it visible to the manager through FireManager's
# grid, which is how trampling discovers what a cell is.
func _put_grass(cell: Vector2i) -> void:
	_layer.set_cell(cell, RegrowthManager.SOURCE_GRASS, _grass_coord, 0)
	var tile := TileStub.new()
	tile.layer = _layer
	_grid.cells[cell] = tile
	FireManager._grid = _grid


# As _put_grass, but for a NAMED grass variant — the ladder tests need to start
# from a known rung, and get_tile_id(0) only ever gives one of them.
func _put_grass_variant(cell: Vector2i, coord: Vector2i) -> void:
	_layer.set_cell(cell, RegrowthManager.SOURCE_GRASS, coord, 0)
	var tile := TileStub.new()
	tile.layer = _layer
	_grid.cells[cell] = tile
	FireManager._grid = _grid


# Paint `cell` as ground terrain generation left DIRT — the state colonisation
# starts from. Uses a dirt variant the atlas really paints, for the same reason
# _put_grass does.
#
# FULL_CUBE, not TileStub's default FLAT: that is the kind TerrainPainter gives
# every flat ground cell, and it is the only one the grass ladders are authored
# on. With FLAT the cell takes the unladdered path and every length assertion
# below passes without testing anything.
const _GROUND_KIND: StringName = &"FULL_CUBE"


func _put_dirt(cell: Vector2i, walkable: bool = true) -> void:
	var coord: Vector2i = FireManager.pick_dirt_coord(_layer.tile_set, _GROUND_KIND)
	_layer.set_cell(cell, FireManager.SOURCE_DIRT, coord, 0)
	var tile := TileStub.new()
	tile.layer = _layer
	tile.tile_kind = _GROUND_KIND
	tile.walkable = walkable
	_grid.cells[cell] = tile
	FireManager._grid = _grid


func _is_grass(cell: Vector2i) -> bool:
	return _layer.get_cell_source_id(cell) == RegrowthManager.SOURCE_GRASS


func _ladder() -> GrassLadder:
	return GrassLadder.new(_layer.tile_set, RegrowthManager.SOURCE_GRASS)


func _burn_out(cell: Vector2i, grass_coord: Vector2i = Vector2i(-1, -1)) -> void:
	# A burn entry as _ignite writes it; _complete_burn is the real emitter.
	# Defaults to a grass variant the atlas actually paints, so the repaint on
	# recovery lands instead of being silently refused by the TileMapLayer.
	if grass_coord.x < 0:
		grass_coord = _grass_coord
	FireManager._burning[cell] = {
		"vfx": null,
		"age": 1.0,
		"fuel": 0.0,
		"fuel_max": 1.0,
		"max_intensity": 1.0,
		"frailejon": null,
		"grass_coord": grass_coord,
		"grass_layer": _layer,
	}
	FireManager._complete_burn(cell)


# --- pure models ------------------------------------------------------------

func test_recovery_rate_rises_with_rain() -> void:
	assert_eq(RegrowthManager.recovery_per_day(0.0, 0.15, 0.5), 0.15)
	assert_almost_eq(RegrowthManager.recovery_per_day(1.0, 0.15, 0.5),
			0.65, 0.0001)
	assert_eq(RegrowthManager.recovery_per_day(9.0, 0.8, 0.5), 1.0,
			"clamped — an out-of-range debug rain must not restore more than all")


func test_appeal_is_the_natural_fraction_of_the_mountain() -> void:
	# appeal = grass still standing / all tiles. Water and stone are always
	# natural; missing grass is the only non-natural state today.
	assert_eq(RegrowthManager.appeal_factor(0, 2304), 1.0)
	assert_almost_eq(RegrowthManager.appeal_factor(576, 2304), 0.75, 0.0001)
	assert_almost_eq(RegrowthManager.appeal_factor(1152, 2304), 0.5, 0.0001)
	assert_eq(RegrowthManager.appeal_factor(2304, 2304), 0.0)
	assert_eq(RegrowthManager.appeal_factor(9999, 2304), 0.0, "floored at zero")
	assert_eq(RegrowthManager.appeal_factor(5, 0), 1.0,
			"no grid (total 0) means no penalty rather than dividing by zero")


func test_appeal_counts_partial_loss_partially() -> void:
	# The whole point of one continuous value: half-worn ground is half a cell
	# of damage, not a cell and not nothing. Under the old two-set model this
	# could only ever be 0 or 1.
	assert_almost_eq(RegrowthManager.appeal_factor(0.5, 4), 0.875, 0.0001)


# --- char bookkeeping --------------------------------------------------------

func test_burnout_registers_a_charred_cell() -> void:
	_burn_out(Vector2i(4, 4))
	assert_eq(_regrowth.bare_count(), 1)
	assert_eq(_regrowth.vegetation_at(Vector2i(4, 4)), 0.0,
			"a burnt-out cell loses ALL its grass in one event")
	# This fixture attaches no world to FireManager, so the whole-mountain
	# denominator is 0 and appeal stays pinned at 1.0 — the no-grid rule.
	# The denominator's live path is covered by test_fire_manager's grid
	# fixture via FireManager.grid_cell_count().
	assert_eq(_regrowth.get_appeal_factor(), 1.0)


func test_extinguished_fires_do_not_char() -> void:
	# extinguish restores the grass itself and emits nothing — only burnOUT
	# goes through the regrowth ledger.
	FireManager._burning[Vector2i(5, 5)] = {
		"vfx": null, "age": 1.0, "fuel": 0.5, "fuel_max": 1.0,
		"max_intensity": 1.0, "frailejon": null,
		"grass_coord": Vector2i(3, 1), "grass_layer": _layer,
	}
	FireManager._extinguish(Vector2i(5, 5))
	assert_eq(_regrowth.bare_count(), 0)


func test_a_payload_without_a_layer_is_ignored() -> void:
	FireManager.tile_burned.emit(Vector2i(1, 1), Vector2i(-1, -1), null)
	assert_eq(_regrowth.bare_count(), 0)


# --- recovery ----------------------------------------------------------------

func test_certain_recovery_repaints_the_original_grass() -> void:
	var cell := Vector2i(7, 2)
	_burn_out(cell, _grass_coord)
	_regrowth.base_recovery_per_day = 1.0
	_regrowth.rain_recovery_bonus = 0.0

	_advance_days()

	assert_eq(_regrowth.bare_count(), 0)
	assert_eq(_layer.get_cell_source_id(cell), RegrowthManager.SOURCE_GRASS,
			"the cell must be grass again")
	assert_eq(_layer.get_cell_atlas_coords(cell), _grass_coord,
			"and the SAME grass variant it was before the fire")


func test_a_fully_recovered_cell_stops_being_tracked() -> void:
	# The ledger must stay proportional to the DAMAGE, not grow for the whole
	# run: every cell ever burnt or walked on would otherwise be iterated every
	# day forever.
	_burn_out(Vector2i(7, 2))
	_regrowth.base_recovery_per_day = 1.0
	_advance_days()
	assert_eq(_regrowth._veg.size(), 0)


func test_a_zero_rate_never_recovers() -> void:
	_burn_out(Vector2i(7, 2))
	_regrowth.base_recovery_per_day = 0.0
	_regrowth.rain_recovery_bonus = 0.0
	_rain.intensity = 0.0

	_advance_days()

	assert_eq(_regrowth.bare_count(), 1, "a drought day heals nothing at rate 0")


func test_recovery_is_gradual_not_all_at_once() -> void:
	# Recovery is a RATE now, so a burn scar climbs back over several days. The
	# old model rolled a per-day coin and jumped straight from bare to whole.
	var cell := Vector2i(7, 2)
	_burn_out(cell)
	_regrowth.base_recovery_per_day = 0.25
	_regrowth.rain_recovery_bonus = 0.0

	_advance_days()
	assert_almost_eq(_regrowth.vegetation_at(cell), 0.25, 0.0001)
	assert_true(_regrowth.is_bare(cell), "a quarter grown back still reads bare")

	_advance_days()
	_advance_days()
	assert_almost_eq(_regrowth.vegetation_at(cell), 0.75, 0.0001)
	assert_false(_regrowth.is_bare(cell), "past regrow_threshold it is grass again")


func test_scars_heal_patchily() -> void:
	# The per-cell multiplier is what stops a whole scar popping back on one
	# day once recovery became continuous. Drawn once at damage time, so a slow
	# cell stays slow.
	_regrowth.recovery_rate_spread = 0.45
	_regrowth.base_recovery_per_day = 0.2
	_regrowth.rain_recovery_bonus = 0.0
	for i in 12:
		_burn_out(Vector2i(i, 9))
	_advance_days()

	var seen: Dictionary = {}
	for i in 12:
		seen[snappedf(_regrowth.vegetation_at(Vector2i(i, 9)), 0.0001)] = true
	assert_gt(seen.size(), 1, "every cell healed by exactly the same amount")


func test_rain_drives_recovery_within_a_single_step() -> void:
	# There is no day-average fallback any more, and nothing to fall back FROM:
	# rain is integrated continuously and consumed by whatever interval a cell
	# happens to be visited over, so a burst of rain heals a cell inside one
	# step. base 0 + bonus 1 at full rain = certain recovery.
	_burn_out(Vector2i(7, 2))
	_regrowth.base_recovery_per_day = 0.0
	_regrowth.rain_recovery_bonus = 1.0
	_rain.intensity = 1.0

	_advance_days()

	assert_eq(_regrowth.bare_count(), 0)


func test_no_recovery_outside_an_active_run() -> void:
	_burn_out(Vector2i(7, 2))
	_regrowth.base_recovery_per_day = 1.0
	SeasonManager.phase = SeasonManager.Phase.IDLE

	_advance_days()

	assert_eq(_regrowth.bare_count(), 1)
	assert_eq(_layer.get_cell_source_id(Vector2i(7, 2)), -1,
			"nothing repainted while no run is under way")


func test_day_average_rain_comes_from_the_process_integral() -> void:
	_burn_out(Vector2i(7, 2))
	_regrowth.base_recovery_per_day = 0.0
	_regrowth.rain_recovery_bonus = 1.0
	# Half a day of full rain, half of drought, integrated by _process.
	TimeManager.paused = false
	var half_day: float = TimeManager.seconds_per_game_day * 0.5 \
			/ maxf(TimeManager.time_scale, 0.001)
	_rain.intensity = 1.0
	_regrowth._process(half_day)
	_rain.intensity = 0.0
	_regrowth._process(half_day)

	# avg = 0.5 -> rate 0.5. Assert the INTEGRAL rather than the outcome, so
	# this stays a test of the integration and not of the recovery model. The
	# clocks are MONOTONIC now (never zeroed at midnight), which is what lets a
	# cell integrate its own interval whenever the sweep reaches it.
	assert_almost_eq(_regrowth._rain_days / _regrowth._days, 0.5, 0.0001)


# --- trampling ---------------------------------------------------------------

func test_a_footfall_takes_a_little_grass() -> void:
	var cell := Vector2i(2, 2)
	_put_grass(cell)
	_regrowth.trample_per_step = 0.1

	_regrowth.trample(cell)

	assert_almost_eq(_regrowth.vegetation_at(cell), 0.9, 0.0001)
	assert_false(_regrowth.is_bare(cell), "one step does not make a path")


func test_the_player_treads_lighter_than_a_visitor() -> void:
	var visitor_cell := Vector2i(2, 2)
	var player_cell := Vector2i(3, 2)
	_put_grass(visitor_cell)
	_put_grass(player_cell)
	_regrowth.trample_per_step = 0.4
	_regrowth.player_trample_fraction = 0.1

	_regrowth.trample(visitor_cell)
	_regrowth.trample_by_player(player_cell)

	assert_almost_eq(_regrowth.vegetation_at(visitor_cell), 0.6, 0.0001)
	assert_almost_eq(_regrowth.vegetation_at(player_cell), 0.96, 0.0001,
			"the player wears player_trample_fraction of a visitor's step")


func test_the_player_ratio_tracks_the_visitor_rate() -> void:
	# The ratio is the tuned quantity, so it must survive a retune of the base
	# rate — a player wear hardcoded in absolute terms would silently drift.
	var cell := Vector2i(2, 2)
	_put_grass(cell)
	_regrowth.trample_per_step = 1.0
	_regrowth.player_trample_fraction = 0.25

	_regrowth.trample_by_player(cell)

	assert_almost_eq(_regrowth.vegetation_at(cell), 0.75, 0.0001)


func test_a_player_fraction_of_zero_leaves_no_track() -> void:
	var cell := Vector2i(2, 2)
	_put_grass(cell)
	_regrowth.trample_per_step = 1.0
	_regrowth.player_trample_fraction = 0.0

	_regrowth.trample_by_player(cell)

	assert_almost_eq(_regrowth.vegetation_at(cell), 1.0, 0.0001,
			"trample() must early-out at zero wear, not track the cell at full veg")
	assert_false(_regrowth.is_bare(cell))


func test_repeated_traffic_wears_a_cell_to_dirt() -> void:
	# The feature in one test: walk the same cell often enough and it goes bare.
	var cell := Vector2i(2, 2)
	_put_grass(cell)
	_regrowth.trample_per_step = 0.1

	for _i in 9:
		_regrowth.trample(cell)

	assert_true(_regrowth.is_bare(cell))
	assert_eq(_layer.get_cell_source_id(cell), FireManager.SOURCE_DIRT,
			"and the ground is actually repainted, not just bookkept")


func test_traffic_spread_thin_leaves_no_path() -> void:
	# The complement, and the reason paths read as paths: a cell crossed once
	# by each of many visitors is nowhere near bare.
	for i in 20:
		var cell := Vector2i(i, 4)
		_put_grass(cell)
		_regrowth.trample(cell)
	assert_eq(_regrowth.bare_count(), 0)


func test_only_grass_wears() -> void:
	# trample is called for EVERY step a visitor takes, so it is handed water,
	# stone and bare ground constantly and must ignore all of it.
	var cell := Vector2i(3, 3)
	_layer.set_cell(cell, FireManager.SOURCE_WATER, Vector2i(0, 0), 0)
	var tile := TileStub.new()
	tile.layer = _layer
	_grid.cells[cell] = tile
	FireManager._grid = _grid

	for _i in 40:
		_regrowth.trample(cell)

	assert_eq(_regrowth.vegetation_at(cell), 1.0,
			"a cell with no grass on it has none to lose")
	assert_eq(_regrowth._veg.size(), 0, "and is not even tracked")


func test_an_unknown_cell_is_ignored() -> void:
	FireManager._grid = _grid
	_regrowth.trample(Vector2i(99, 99))
	assert_eq(_regrowth._veg.size(), 0)


func test_trampling_is_off_at_zero() -> void:
	# The knob for isolating this during balance work.
	var cell := Vector2i(2, 2)
	_put_grass(cell)
	_regrowth.trample_per_step = 0.0
	for _i in 40:
		_regrowth.trample(cell)
	assert_eq(_regrowth.vegetation_at(cell), 1.0)


func test_walking_on_a_fire_changes_nothing() -> void:
	var cell := Vector2i(2, 2)
	_put_grass(cell)
	FireManager._burning[cell] = {
		"vfx": null, "age": 1.0, "fuel": 0.5, "fuel_max": 1.0,
		"max_intensity": 1.0, "frailejon": null,
		"grass_coord": _grass_coord, "grass_layer": _layer,
	}
	_regrowth.trample(cell)
	assert_eq(_regrowth.vegetation_at(cell), 1.0,
			"the burn is fire's to resolve; a footfall must not pre-empt it")


func test_worn_ground_grows_back() -> void:
	var cell := Vector2i(2, 2)
	_put_grass(cell)
	_regrowth.trample_per_step = 1.0
	_regrowth.trample(cell)
	assert_true(_regrowth.is_bare(cell))

	_regrowth.base_recovery_per_day = 1.0
	_advance_days()

	assert_false(_regrowth.is_bare(cell))
	assert_eq(_layer.get_cell_atlas_coords(cell), _grass_coord,
			"the same grass variant it was wearing before the traffic")


func test_paint_does_not_flip_back_and_forth_at_one_threshold() -> void:
	# Bare and regrow are deliberately far apart. With a single threshold, a
	# cell walked daily and healing daily would change appearance EVERY day.
	var cell := Vector2i(2, 2)
	_put_grass(cell)
	_regrowth.trample_per_step = 1.0
	_regrowth.trample(cell)  # bare, veg 0

	_regrowth.base_recovery_per_day = 0.2
	_regrowth.rain_recovery_bonus = 0.0
	_advance_days()
	_advance_days()

	assert_almost_eq(_regrowth.vegetation_at(cell), 0.4, 0.0001)
	assert_true(_regrowth.is_bare(cell),
			"above bare_threshold but below regrow_threshold: still a path")


func test_wear_and_char_are_the_same_number() -> void:
	# The merge, stated as a test: a cell already worn thin that then burns is
	# ONE damaged cell, not one charred plus one worn. Under two ledgers this
	# counted twice and appeal double-charged for it.
	var cell := Vector2i(2, 2)
	_put_grass(cell)
	_regrowth.trample_per_step = 0.4
	_regrowth.trample(cell)
	assert_almost_eq(_regrowth.vegetation_deficit(), 0.4, 0.0001)

	_burn_out(cell)

	assert_eq(_regrowth._veg.size(), 1, "one cell, one record")
	assert_almost_eq(_regrowth.vegetation_deficit(), 1.0, 0.0001)


func test_the_running_totals_never_drift_from_the_ledger() -> void:
	# bare_count and vegetation_deficit are maintained incrementally because the
	# simulator samples both once per TICK and summing there measured as about
	# half the run's wall clock. Incremental totals can drift; this recounts
	# from scratch after a mixed workload and compares.
	_regrowth.trample_per_step = 0.3
	_regrowth.base_recovery_per_day = 0.25
	for i in 6:
		_put_grass(Vector2i(i, 1))
	for i in 6:
		for _step in i:  # 0..5 crossings each: some bare, some part-worn, one clean
			_regrowth.trample(Vector2i(i, 1))
	_burn_out(Vector2i(2, 7))
	_burn_out(Vector2i(3, 7))
	_advance_days()
	_advance_days()

	var want_deficit: float = 0.0
	var want_bare: int = 0
	for cell: Vector2i in _regrowth._veg:
		want_deficit += 1.0 - float(_regrowth._veg[cell]["veg"])
		if bool(_regrowth._veg[cell]["bare"]):
			want_bare += 1
	assert_almost_eq(_regrowth.vegetation_deficit(), want_deficit, 0.0001)
	assert_eq(_regrowth.bare_count(), want_bare)


func test_the_totals_survive_a_wipe() -> void:
	_put_grass(Vector2i(2, 2))
	_regrowth.trample_per_step = 1.0
	_regrowth.trample(Vector2i(2, 2))
	_regrowth._wipe()
	assert_eq(_regrowth.vegetation_deficit(), 0.0)
	assert_eq(_regrowth.bare_count(), 0)


func test_a_regenerated_world_forgets_every_scar() -> void:
	_put_grass(Vector2i(2, 2))
	_regrowth.trample_per_step = 1.0
	_regrowth.trample(Vector2i(2, 2))
	_burn_out(Vector2i(4, 4))
	assert_gt(_regrowth._veg.size(), 0)

	_regrowth._wipe()

	assert_eq(_regrowth._veg.size(), 0,
			"stale records would repaint grass onto a brand new mountain")


func test_a_footfall_wears_the_plant_standing_on_the_cell() -> void:
	var cell := Vector2i(2, 2)
	_put_grass(cell)
	var plant := PlantStub.new()
	add_child_autofree(plant)
	_grid.occupants[cell] = plant
	_regrowth.trample_per_step = 0.2

	_regrowth.trample(cell)

	assert_almost_eq(plant.wear_taken, 0.2, 0.0001,
			"the plant takes the same wear the grass under it does")
	assert_almost_eq(_regrowth.vegetation_at(cell), 0.8, 0.0001)


func test_the_player_treads_lighter_on_plants_too() -> void:
	var cell := Vector2i(2, 2)
	_put_grass(cell)
	var plant := PlantStub.new()
	add_child_autofree(plant)
	_grid.occupants[cell] = plant
	_regrowth.trample_per_step = 0.4
	_regrowth.player_trample_fraction = 0.25

	_regrowth.trample_by_player(cell)

	assert_almost_eq(plant.wear_taken, 0.1, 0.0001)


func test_a_plant_on_bare_dirt_is_still_trampled() -> void:
	# The vegetation ledger only tracks grass-source tiles and gives up on
	# anything else. A rosette standing on dirt is still walked on, so the
	# plant hook cannot sit behind that early return.
	var cell := Vector2i(4, 4)
	var plant := PlantStub.new()
	add_child_autofree(plant)
	_grid.occupants[cell] = plant
	FireManager._grid = _grid
	_regrowth.trample_per_step = 0.3

	_regrowth.trample(cell)

	assert_almost_eq(plant.wear_taken, 0.3, 0.0001)
	assert_eq(_regrowth.vegetation_at(cell), 1.0, "no grass here to lose")


func test_a_burning_cell_is_fires_to_resolve_for_the_plant_as_well() -> void:
	var cell := Vector2i(2, 2)
	_put_grass(cell)
	var plant := PlantStub.new()
	add_child_autofree(plant)
	_grid.occupants[cell] = plant
	FireManager._burning[cell] = {}

	_regrowth.trample(cell)

	assert_eq(plant.wear_taken, 0.0)
	assert_eq(_regrowth.vegetation_at(cell), 1.0)


func test_a_non_plant_occupant_ignores_feet() -> void:
	var cell := Vector2i(2, 2)
	_put_grass(cell)
	_grid.occupants[cell] = MuteOccupantStub.new()
	autofree(_grid.occupants[cell])

	_regrowth.trample(cell)

	assert_almost_eq(_regrowth.vegetation_at(cell), 1.0 - _regrowth.trample_per_step, 0.0001,
			"the grass still wears; only the plant hook is skipped")


func test_a_grid_without_an_occupant_registry_does_not_break_trampling() -> void:
	# FireManager.grid() is typed Object so tests (and the headless sim) can
	# inject a stub; not every stub keeps occupants.
	var cell := Vector2i(2, 2)
	_put_grass(cell)
	FireManager._grid = RefCounted.new()
	_regrowth.trample_per_step = 0.1

	_regrowth.trample(cell)

	assert_eq(_regrowth.vegetation_at(cell), 1.0,
			"an unreadable grid means the cell is not tracked, not a crash")


# --- continuous recovery -----------------------------------------------------
#
# Recovery moved off the day boundary (2026-08-10). It used to be one pass at
# midnight, so grass returned in a single step 240 real seconds wide: a scar sat
# unchanged all day and then jumped. The three tests below pin the properties
# that replaced it — a cell heals DURING the day, the cadence cannot change how
# much it heals, and time spent on fire is never banked.

func test_grass_returns_during_the_day_not_only_at_midnight() -> void:
	_burn_out(Vector2i(7, 2))
	_regrowth.base_recovery_per_day = 0.4
	_regrowth.rain_recovery_bonus = 0.0

	_advance_days(0.25)

	assert_almost_eq(_regrowth.vegetation_at(Vector2i(7, 2)), 0.1, 0.0001,
			"a quarter day should return a quarter of a day's growth")


func test_recovery_is_independent_of_the_sweep_cadence() -> void:
	# The property the whole design rests on: a cell integrates its OWN elapsed
	# time, so it does not matter whether the sweep reaches it once or forty
	# times over the same day. If this ever fails, sweep_seconds has silently
	# become a balance knob.
	_regrowth.base_recovery_per_day = 0.3
	_regrowth.rain_recovery_bonus = 0.0
	_burn_out(Vector2i(1, 1))
	_advance_days(1.0)
	var in_one_step: float = _regrowth.vegetation_at(Vector2i(1, 1))

	_burn_out(Vector2i(2, 1))
	for i in 40:
		_advance_days(1.0 / 40.0)
	var in_forty_steps: float = _regrowth.vegetation_at(Vector2i(2, 1))

	assert_almost_eq(in_forty_steps, in_one_step, 0.0001,
			"cadence changed the amount recovered")


func test_grass_gets_shorter_before_it_disappears() -> void:
	# The feature in one test: loss is CONTINUOUS. A cell that has taken some
	# wear but is nowhere near bare must already look shorter — under the old
	# single threshold it looked untouched right up to the moment it turned to
	# dirt.
	var cell := Vector2i(2, 2)
	_put_grass_variant(cell, _TALL_WARM)
	_regrowth.trample_per_step = 0.6
	_regrowth.trample(cell)

	assert_eq(_layer.get_cell_source_id(cell), RegrowthManager.SOURCE_GRASS,
			"0.4 vegetation is well above bare_threshold — still grass")
	var worn: Vector2i = _layer.get_cell_atlas_coords(cell)
	assert_ne(worn, _TALL_WARM, "the grass never got shorter")
	assert_lt(_ladder().top_rung(worn), _ladder().top_rung(_TALL_WARM),
			"the grass changed variant but not to a SHORTER one")


func test_wearing_a_cell_never_changes_its_grass_type() -> void:
	# Two tones ship, and a cell must keep the one generation gave it: a cell
	# stepping across tones as it wore would read as the species changing, not
	# as the same stand of grass being walked down.
	var cell := Vector2i(3, 2)
	_put_grass_variant(cell, _TALL_COOL)
	_regrowth.trample_per_step = 0.2

	var seen: Array[Vector2i] = []
	for _i in 4:
		_regrowth.trample(cell)
		seen.append(_layer.get_cell_atlas_coords(cell))

	for coord: Vector2i in seen:
		assert_eq(coord.x, _TALL_COOL.x,
				"%s is not on the cool ladder (column %d)" % [coord, _TALL_COOL.x])


func test_grass_grows_back_no_longer_than_generation_made_it() -> void:
	# The ceiling, and the reason the ladder is anchored to the coord captured
	# at first damage: a short-grass cell that healed into the tall art would
	# quietly rewrite the mountain's authored texture every time it was walked
	# on and left alone.
	var cell := Vector2i(4, 2)
	var short_warm := Vector2i(0, 6)  # rung 1 of 5
	_put_grass_variant(cell, short_warm)
	_regrowth.trample_per_step = 1.0
	_regrowth.trample(cell)
	assert_true(_regrowth.is_bare(cell))

	_regrowth.base_recovery_per_day = 1.0
	_regrowth.rain_recovery_bonus = 0.0
	_advance_days()

	assert_eq(_layer.get_cell_atlas_coords(cell), short_warm,
			"a fully recovered cell must wear exactly the variant it was born with")


func test_grass_grows_back_through_the_lengths_it_lost() -> void:
	# Recovery is the same ladder in reverse: a burn scar comes back as short
	# grass first and only reaches its full length when the value does.
	var cell := Vector2i(5, 2)
	_put_grass_variant(cell, _TALL_WARM)
	_regrowth.trample_per_step = 1.0
	_regrowth.trample(cell)
	_regrowth.base_recovery_per_day = 0.3
	_regrowth.rain_recovery_bonus = 0.0

	var rungs: Array[int] = []
	for _i in 4:
		_advance_days()
		if not _regrowth.is_bare(cell):
			rungs.append(_ladder().top_rung(_layer.get_cell_atlas_coords(cell)))

	assert_gt(rungs.size(), 1, "the cell never came back at all")
	assert_gt(rungs[rungs.size() - 1], rungs[0], "the grass never grew longer")
	for i in range(1, rungs.size()):
		assert_true(rungs[i] >= rungs[i - 1], "recovery walked the ladder DOWN")


func test_length_does_not_flicker_on_a_rung_boundary() -> void:
	# The same problem bare_threshold/regrow_threshold solve, one scale down: a
	# lightly used route sits on a boundary for days, and without a deadband it
	# would re-cut its tile on every sweep.
	var cell := Vector2i(6, 2)
	_put_grass_variant(cell, _TALL_WARM)
	_regrowth.grass_step_hysteresis = 0.03
	_regrowth.trample(cell, 0.49)  # veg 0.51, just over the rung-2 boundary
	var settled: Vector2i = _layer.get_cell_atlas_coords(cell)

	_regrowth.trample(cell, 0.015)  # inside the deadband
	assert_eq(_layer.get_cell_atlas_coords(cell), settled,
			"a nudge smaller than the hysteresis changed the grass length")

	_regrowth.trample(cell, 0.05)  # and now clear of it
	assert_ne(_layer.get_cell_atlas_coords(cell), settled,
			"the deadband swallowed a move that really crossed the boundary")


func test_a_single_rung_variant_behaves_as_it_always_did() -> void:
	# Slopes, walls and stairs are painted once each and have no shorter art.
	# They must still wear to dirt and come back — the ladder is an addition, not
	# a precondition, and most of the grass source opts out of it.
	var cell := Vector2i(7, 6)
	var slope := Vector2i(2, 0)  # SLOPE_NW, no grass_length authored
	_put_grass_variant(cell, slope)
	_regrowth.trample_per_step = 0.25

	for _i in 3:  # veg 0.25 — worn thin, but still above bare_threshold
		_regrowth.trample(cell)
	assert_eq(_layer.get_cell_atlas_coords(cell), slope,
			"nothing to step down to, so the art must not change")

	_regrowth.trample(cell)
	assert_true(_regrowth.is_bare(cell))
	assert_eq(_layer.get_cell_source_id(cell), FireManager.SOURCE_DIRT)


func test_time_spent_burning_is_not_banked_and_paid_out_later() -> void:
	# The old pass skipped a burning cell for a whole day. With a monotonic
	# clock, skipping without STAMPING the cell would let it heal retroactively
	# for the time it spent alight the moment the fire went out — worse than the
	# behaviour it replaced, and invisible except as fires that leave no scar.
	var cell := Vector2i(4, 4)
	_burn_out(cell)
	_regrowth.base_recovery_per_day = 0.5
	_regrowth.rain_recovery_bonus = 0.0
	FireManager._burning[cell] = {"vfx": null, "age": 1.0, "fuel": 1.0, "fuel_max": 1.0}

	_advance_days(1.0)
	assert_eq(_regrowth.vegetation_at(cell), 0.0, "a burning cell must not recover")

	FireManager._burning.erase(cell)
	_advance_days(0.1)
	assert_almost_eq(_regrowth.vegetation_at(cell), 0.05, 0.0001,
			"only the time since the fire went out counts")


# --- colonisation: dirt the mountain never had grass on ----------------------


func test_ground_generated_as_dirt_grows_grass() -> void:
	# The whole feature: a cell terrain generation painted dirt is not a
	# permanent hole in the mountain, it is ground grass has not reached yet.
	var cell := Vector2i(2, 2)
	_put_dirt(cell)
	assert_false(_is_grass(cell), "generation left it dirt")

	# 0.55 / (0.15 * 0.25) ~= 15 days to cross regrow_threshold.
	_advance_days(20.0)
	assert_true(_is_grass(cell), "and grass has since colonised it")
	assert_false(_regrowth.is_bare(cell))


func test_reclaimed_dirt_never_grows_as_tall_as_the_stand_beside_it() -> void:
	# Terrain generation bands grass by altitude. Letting colonised ground reach
	# the full stand would erase that banding over a run, so the ceiling is a
	# FRACTION of the ladder — the reclaimed band reads green but visibly thin.
	var cell := Vector2i(2, 2)
	_put_dirt(cell)
	_advance_days(60.0)  # far past full

	var painted: Vector2i = _layer.get_cell_atlas_coords(cell)
	var ladder: GrassLadder = _ladder()
	assert_gt(ladder.rung_count(painted), 1,
			"FLAT must be laddered or this test proves nothing")
	assert_lt(ladder.top_rung(painted), ladder.rung_count(painted) - 1,
			"reclaimed dirt must stop short of its ladder's top rung")


func test_reclaimed_dirt_stops_climbing() -> void:
	# It reaches its ceiling and is dropped from the sweep — the ledger must
	# stay proportional to what is CHANGING, or the whole dirt band would sit in
	# it for the rest of the run.
	var cell := Vector2i(2, 2)
	_put_dirt(cell)
	_advance_days(60.0)
	var painted: Vector2i = _layer.get_cell_atlas_coords(cell)

	_advance_days(60.0)
	assert_eq(_layer.get_cell_atlas_coords(cell), painted,
			"nothing left to grow into")
	assert_false(_regrowth._veg.has(cell), "and nothing left to sweep")


func test_bare_dirt_is_not_a_scar() -> void:
	# Appeal is "the fraction of the mountain still in its NATURAL state", and
	# dirt is natural. Counting the seeded dirt band as missing grass would drop
	# a pristine mountain's appeal to near zero the moment the world loaded.
	for x in 5:
		_put_dirt(Vector2i(x, 0))
	_advance_days(0.5)

	assert_eq(_regrowth.bare_count(), 0, "generated dirt is not a scar")
	assert_eq(_regrowth.vegetation_deficit(), 0.0, "and no grass is missing")
	assert_eq(_regrowth.get_appeal_factor(), 1.0, "so the mountain reads pristine")


func test_reclaimed_ground_that_burns_costs_nothing() -> void:
	# Fire takes it back to the state generation left it in. Charging appeal for
	# that would make colonisation a LIABILITY — every cell it greened would be
	# a new way to lose points that the player never gained anything for.
	var cell := Vector2i(2, 2)
	_put_dirt(cell)
	_advance_days(60.0)
	assert_true(_is_grass(cell))

	_burn_out(cell)
	assert_eq(_regrowth.bare_count(), 0)
	assert_eq(_regrowth.vegetation_deficit(), 0.0)

	_advance_days(60.0)
	assert_true(_is_grass(cell), "and it colonises again from scratch")


func test_colonising_is_slower_than_a_scar_closing_over() -> void:
	# Reclaiming ground the mountain never had is not the same event as a burn
	# scar closing, and must not read at the same speed.
	var scar := Vector2i(1, 1)
	var dirt := Vector2i(3, 3)
	_put_grass(scar)
	_burn_out(scar)
	_put_dirt(dirt)

	_advance_days(1.0)
	assert_almost_eq(
			_regrowth.vegetation_at(dirt),
			_regrowth.vegetation_at(scar) * _regrowth.dirt_colonise_factor,
			0.0001, "colonisation is the recovery rate scaled by the factor")


func test_colonisation_is_off_at_zero() -> void:
	# The knob for isolating it in the balance simulator — and at zero it must
	# cost nothing, not merely move nothing.
	_regrowth.dirt_colonise_factor = 0.0
	var cell := Vector2i(2, 2)
	_put_dirt(cell)

	_advance_days(60.0)
	assert_false(_is_grass(cell))
	assert_eq(_regrowth._veg.size(), 0, "and nothing is tracked at all")


func test_only_ground_you_can_stand_on_colonises() -> void:
	# Underwater fill, cliff backing and wall faces are dirt too. Grass on a
	# vertical face would be the visible failure.
	var cell := Vector2i(2, 2)
	_put_dirt(cell, false)

	_advance_days(60.0)
	assert_false(_is_grass(cell))


func test_feet_hold_a_route_across_dirt_open() -> void:
	# Colonisation and trampling are the same value moving in opposite
	# directions, so a route walked often enough simply never closes — with no
	# rule anywhere saying so.
	var cell := Vector2i(2, 2)
	_put_dirt(cell)
	for _day in 30:
		_advance_days(1.0)
		_regrowth.trample(cell)  # 0.18 a day against 0.0375 gained

	assert_false(_is_grass(cell), "traffic outruns colonisation")
