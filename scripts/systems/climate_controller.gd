class_name ClimateController
extends Node

## Owns the run's global DRYNESS scalar and the climate-change ramp.
##
## Dryness is the simulation's spine: one number in [0, 1] that rain pushes
## toward 0 and clear sky pulls toward the season's equilibrium
## (SeasonProfile.dryness_equilibrium). Fire ignition multiplies by it (via
## get_ignition_multiplier), so a rainless stretch of dry season makes the
## mountain tinder while a storm re-soaks it over hours, not instantly.
##
## The climate ramp is deliberately GENTLE (~5%/season, @export): each season
## boundary scales the rain START probability down (pushed into
## DayNightSceneController.set_rain_probability_scale — never by mutating the
## shared DayNightProfile .tres) and drifts the dryness equilibrium up. The
## slice's run is one year, so per-season is the only cadence that can be felt;
## the GDD's per-year altitude-band creep arrives with ClimateState later.
##
## Scene-scoped (gameplay_base.tscn), not an autoload: run state that should
## die with the scene. Consumers find it via the "climate" group with a 1.0
## fallback, so bare test scenes and tools never need it.

const GROUP: StringName = &"climate"
const DAY_NIGHT_GROUP: StringName = &"day_night_controller"

## Pull toward the season equilibrium under clear sky, per in-game day.
## 0.35/day ≈ most of the gap closed over a 6-day season.
@export var dry_rate_per_day: float = 0.35
## Push toward 0 at full rain, per in-game day. Much faster than drying:
## one solid storm undoes days of desiccation.
@export var wet_rate_per_day: float = 1.2
## Climate change: rain START probability is scaled by
## (1 - this) ^ season_index. 0.05 = 5% less likely each season.
@export var climate_rain_decay_per_season: float = 0.05
## Climate change: dryness equilibrium rises by this much per season elapsed.
@export var climate_dryness_drift_per_season: float = 0.05
## Fire-ignition multiplier when fully soaked (dryness 0).
@export var ignition_mult_at_zero: float = 0.3
## Fire-ignition multiplier at bone dry (dryness 1).
@export var ignition_mult_at_one: float = 2.0

var dryness: float = 0.5

var _day_night: Node = null
# Set by season_started; -1 until then so the first _process can pull the
# already-running season lazily (season 0 fires from start_run, which can
# precede this node's _ready in scene-load order).
var _season_index: int = -1
var _equilibrium: float = 0.5


func _ready() -> void:
	add_to_group(GROUP)
	SeasonManager.season_started.connect(_on_season_started)


## Pure dryness integrator, static for tree-free tests. Clear sky closes the
## gap to `equilibrium` at dry_rate (suppressed by rain); rain drives toward 0
## at wet_rate * intensity. Result clamped to [0, 1].
static func dryness_step(d: float, equilibrium: float, rain: float,
		game_day_delta: float, dry_rate: float, wet_rate: float) -> float:
	var r: float = clampf(rain, 0.0, 1.0)
	var next: float = d + (equilibrium - d) \
			* minf(1.0, dry_rate * game_day_delta) * (1.0 - r)
	next -= wet_rate * r * game_day_delta
	return clampf(next, 0.0, 1.0)


## Pure climate curve: the rain-start probability scale after N elapsed
## seasons. Season 0 is always exactly 1.0 (the authored profile).
static func rain_scale_for(season_index: int, decay_per_season: float) -> float:
	return pow(1.0 - clampf(decay_per_season, 0.0, 1.0), maxi(season_index, 0))


func get_dryness() -> float:
	return dryness


## Read by FireManager's ignition roll (group lookup, fallback 1.0).
func get_ignition_multiplier() -> float:
	return lerpf(ignition_mult_at_zero, ignition_mult_at_one, dryness)


func rain_intensity() -> float:
	if _day_night == null or not is_instance_valid(_day_night):
		_day_night = get_tree().get_first_node_in_group(DAY_NIGHT_GROUP)
	if _day_night != null and _day_night.has_method(&"get_rain_current_intensity"):
		return float(_day_night.call(&"get_rain_current_intensity"))
	return 0.0


func _process(delta: float) -> void:
	if SeasonManager.phase != SeasonManager.Phase.ACTIVE:
		return
	if TimeManager.paused or TimeManager.seconds_per_game_day <= 0.0:
		return
	if _season_index != SeasonManager.season_index:
		# Missed (or predated) the season_started signal — pull lazily.
		_apply_season(SeasonManager.season_index, SeasonManager.current_profile())
	var game_day_delta: float = \
			delta * TimeManager.time_scale / TimeManager.seconds_per_game_day
	dryness = dryness_step(dryness, _equilibrium, rain_intensity(),
			game_day_delta, dry_rate_per_day, wet_rate_per_day)


func _on_season_started(index: int, profile: SeasonProfile) -> void:
	_apply_season(index, profile)


func _apply_season(index: int, profile: SeasonProfile) -> void:
	_season_index = index
	var base_eq: float = profile.dryness_equilibrium if profile != null else 0.5
	_equilibrium = clampf(
			base_eq + climate_dryness_drift_per_season * index, 0.0, 1.0)
	if _day_night == null or not is_instance_valid(_day_night):
		_day_night = get_tree().get_first_node_in_group(DAY_NIGHT_GROUP)
	if _day_night != null and _day_night.has_method(&"set_rain_probability_scale"):
		_day_night.call(&"set_rain_probability_scale",
				rain_scale_for(index, climate_rain_decay_per_season))
