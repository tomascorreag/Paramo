extends GutTest

# Guards the char → regrowth arc: burnout hands the pre-burn grass coord to the
# manager (the payload D3 added to tile_burned — before it, the coord died with
# the burn entry and a burned cell was dirt FOREVER), recovery is rolled daily
# scaled by rain, and the appeal factor VisitorFlow reads tracks the char count.
#
# White-box against the real FireManager autoload (burn entries injected, then
# _complete_burn called) because the manager subscribes to the real autoload's
# signal in _ready. day_completed is driven by calling the handler directly —
# emitting the real TimeManager signal would also advance SeasonManager.

var _regrowth: RegrowthManager
var _layer: TileMapLayer


class RainStub:
	extends Node

	var intensity: float = 0.0

	func _ready() -> void:
		add_to_group(&"day_night_controller")

	func get_rain_current_intensity() -> float:
		return intensity


var _rain: RainStub
var _phase_before: int
var _paused_before: bool


func before_each() -> void:
	_phase_before = SeasonManager.phase
	_paused_before = TimeManager.paused
	TimeManager.paused = true
	SeasonManager.phase = SeasonManager.Phase.ACTIVE
	FireManager._burning.clear()

	_rain = RainStub.new()
	add_child_autofree(_rain)
	_layer = TileMapLayer.new()
	add_child_autofree(_layer)
	_regrowth = RegrowthManager.new()
	add_child_autofree(_regrowth)


func after_each() -> void:
	SeasonManager.phase = _phase_before
	TimeManager.paused = _paused_before
	FireManager._burning.clear()


func _burn_out(cell: Vector2i, grass_coord: Vector2i = Vector2i(3, 1)) -> void:
	# A burn entry as _ignite writes it; _complete_burn is the real emitter.
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
	assert_eq(RegrowthManager.recovery_probability(0.0, 0.15, 0.5), 0.15)
	assert_almost_eq(RegrowthManager.recovery_probability(1.0, 0.15, 0.5),
			0.65, 0.0001)
	assert_eq(RegrowthManager.recovery_probability(9.0, 0.8, 0.5), 1.0,
			"clamped — an out-of-range debug rain must not exceed certainty")


func test_appeal_falls_linearly_with_char() -> void:
	assert_eq(RegrowthManager.appeal_factor(0, 30), 1.0)
	assert_almost_eq(RegrowthManager.appeal_factor(15, 30), 0.5, 0.0001)
	assert_eq(RegrowthManager.appeal_factor(30, 30), 0.0)
	assert_eq(RegrowthManager.appeal_factor(99, 30), 0.0, "floored at zero")
	assert_eq(RegrowthManager.appeal_factor(5, 0), 1.0,
			"saturation 0 disables the penalty rather than dividing by zero")


# --- char bookkeeping --------------------------------------------------------

func test_burnout_registers_a_charred_cell() -> void:
	_burn_out(Vector2i(4, 4))
	assert_eq(_regrowth.charred_count(), 1)
	assert_almost_eq(_regrowth.get_appeal_factor(), 1.0 - 1.0 / 30.0, 0.0001)


func test_extinguished_fires_do_not_char() -> void:
	# extinguish restores the grass itself and emits nothing — only burnOUT
	# goes through the regrowth ledger.
	FireManager._burning[Vector2i(5, 5)] = {
		"vfx": null, "age": 1.0, "fuel": 0.5, "fuel_max": 1.0,
		"max_intensity": 1.0, "frailejon": null,
		"grass_coord": Vector2i(3, 1), "grass_layer": _layer,
	}
	FireManager._extinguish(Vector2i(5, 5))
	assert_eq(_regrowth.charred_count(), 0)


func test_a_payload_without_a_layer_is_ignored() -> void:
	FireManager.tile_burned.emit(Vector2i(1, 1), Vector2i(-1, -1), null)
	assert_eq(_regrowth.charred_count(), 0)


# --- recovery ----------------------------------------------------------------

func test_certain_recovery_repaints_the_original_grass() -> void:
	var cell := Vector2i(7, 2)
	var coord := Vector2i(3, 1)
	_burn_out(cell, coord)
	_regrowth.base_recovery_per_day = 1.0
	_regrowth.rain_recovery_bonus = 0.0

	_regrowth._on_day_completed(1)

	assert_eq(_regrowth.charred_count(), 0)
	assert_eq(_layer.get_cell_source_id(cell), RegrowthManager.SOURCE_GRASS,
			"the cell must be grass again")
	assert_eq(_layer.get_cell_atlas_coords(cell), coord,
			"and the SAME grass variant it was before the fire")


func test_zero_probability_never_recovers() -> void:
	_burn_out(Vector2i(7, 2))
	_regrowth.base_recovery_per_day = 0.0
	_regrowth.rain_recovery_bonus = 0.0
	_rain.intensity = 0.0

	_regrowth._on_day_completed(1)

	assert_eq(_regrowth.charred_count(), 1, "a drought day heals nothing at p=0")


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

	assert_eq(_regrowth.charred_count(), 0)


func test_no_recovery_outside_an_active_run() -> void:
	_burn_out(Vector2i(7, 2))
	_regrowth.base_recovery_per_day = 1.0
	SeasonManager.phase = SeasonManager.Phase.PLANNING

	_regrowth._on_day_completed(1)

	assert_eq(_regrowth.charred_count(), 1)
	assert_eq(_layer.get_cell_source_id(Vector2i(7, 2)), -1,
			"nothing repainted while the clock is between seasons")


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

	# avg = 0.5 -> p = 0.5. Roll is random, so assert the INTEGRAL, not the
	# outcome: force certainty via the bonus and confirm elapsed was consumed.
	assert_almost_eq(_regrowth._rain_integral / _regrowth._rain_elapsed,
			0.5, 0.0001)
