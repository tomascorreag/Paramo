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

	func get_tile(cell: Vector2i) -> Variant:
		return cells.get(cell)

	func cell_count() -> int:
		return cells.size()


class TileStub:
	extends RefCounted

	var layer: TileMapLayer = null
	var tile_kind: StringName = &"FLAT"


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


# Paint `cell` as grass and make it visible to the manager through FireManager's
# grid, which is how trampling discovers what a cell is.
func _put_grass(cell: Vector2i) -> void:
	_layer.set_cell(cell, RegrowthManager.SOURCE_GRASS, _grass_coord, 0)
	var tile := TileStub.new()
	tile.layer = _layer
	_grid.cells[cell] = tile
	FireManager._grid = _grid


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

	_regrowth._on_day_completed(1)

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
	_regrowth._on_day_completed(1)
	assert_eq(_regrowth._veg.size(), 0)


func test_a_zero_rate_never_recovers() -> void:
	_burn_out(Vector2i(7, 2))
	_regrowth.base_recovery_per_day = 0.0
	_regrowth.rain_recovery_bonus = 0.0
	_rain.intensity = 0.0

	_regrowth._on_day_completed(1)

	assert_eq(_regrowth.bare_count(), 1, "a drought day heals nothing at rate 0")


func test_recovery_is_gradual_not_all_at_once() -> void:
	# Recovery is a RATE now, so a burn scar climbs back over several days. The
	# old model rolled a per-day coin and jumped straight from bare to whole.
	var cell := Vector2i(7, 2)
	_burn_out(cell)
	_regrowth.base_recovery_per_day = 0.25
	_regrowth.rain_recovery_bonus = 0.0

	_regrowth._on_day_completed(1)
	assert_almost_eq(_regrowth.vegetation_at(cell), 0.25, 0.0001)
	assert_true(_regrowth.is_bare(cell), "a quarter grown back still reads bare")

	_regrowth._on_day_completed(2)
	_regrowth._on_day_completed(3)
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
	_regrowth._on_day_completed(1)

	var seen: Dictionary = {}
	for i in 12:
		seen[snappedf(_regrowth.vegetation_at(Vector2i(i, 9)), 0.0001)] = true
	assert_gt(seen.size(), 1, "every cell healed by exactly the same amount")


func test_rain_fallback_drives_recovery_on_burst_days() -> void:
	# The M-key debug path fires day_completed with no _process in between, so
	# the day-average integral is empty. The fallback must read the CURRENT
	# rain — base 0 + bonus 1 at full rain = certain recovery, so this test
	# only passes if the fallback branch runs.
	_burn_out(Vector2i(7, 2))
	_regrowth.base_recovery_per_day = 0.0
	_regrowth.rain_recovery_bonus = 1.0
	_rain.intensity = 1.0

	_regrowth._on_day_completed(1)

	assert_eq(_regrowth.bare_count(), 0)


func test_no_recovery_outside_an_active_run() -> void:
	_burn_out(Vector2i(7, 2))
	_regrowth.base_recovery_per_day = 1.0
	SeasonManager.phase = SeasonManager.Phase.IDLE

	_regrowth._on_day_completed(1)

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
	# this stays a test of the integration and not of the recovery model.
	assert_almost_eq(_regrowth._rain_integral / _regrowth._rain_elapsed,
			0.5, 0.0001)


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
	_regrowth._on_day_completed(1)

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
	_regrowth._on_day_completed(1)
	_regrowth._on_day_completed(2)

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
	_regrowth._on_day_completed(1)
	_regrowth._on_day_completed(2)

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
