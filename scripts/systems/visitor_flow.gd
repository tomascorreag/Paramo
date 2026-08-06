class_name VisitorFlow
extends Node

## Abstract eco-tourism: how many visitors came today, and the tokens they
## paid. No entities — a computed count at each completed day. Tourist agents
## (trampling, campfires) are a later threat pass that will feed this number.
##
## visitors = base * (1 - day_avg_rain) * appeal, where appeal comes from
## RegrowthManager (charred land drives it toward 0; future trails/flora
## bonuses hook in there or multiply at this seam). So sun pays and rain
## doesn't — and the same sun raises fire risk (ClimateController), whose
## burns crater appeal. Drought is a payday loan, which is the loop's argument.
##
## Income is banked as ONE lump per day into the ledger. This is deliberate
## ledger doctrine (see resource_ledger.gd): visitor income is PLAYER-STEERABLE
## (appeal responds to play), so unlike weather-driven water it must be
## quantized — a continuous trickle would invite per-second optimization. The
## day boundary is the quantum the user asked for.

const TOKENS: StringName = &"tokens"
const SOURCE: StringName = &"visitors"

## Visitors on a perfect day (no rain, pristine mountain). Small on purpose:
## at 5 tokens each, a good day pays 2 unlocks' worth.
@export var base_visitors_per_day: int = 4
@export var tokens_per_visitor: float = 5.0

const REGROWTH_GROUP: StringName = &"regrowth"
const DAY_NIGHT_GROUP: StringName = &"day_night_controller"

var _rain_integral: float = 0.0
var _rain_elapsed: float = 0.0
var _day_night: Node = null
var _regrowth: Node = null


func _ready() -> void:
	TimeManager.day_completed.connect(_on_day_completed)


## Pure daily model, static for tree-free tests. Rain and appeal both clamp to
## [0, 1]; the count rounds to the nearest whole visitor.
static func visitors_for(day_avg_rain: float, appeal: float, base: int) -> int:
	return int(roundf(float(base) * clampf(1.0 - day_avg_rain, 0.0, 1.0) \
			* clampf(appeal, 0.0, 1.0)))


func appeal() -> float:
	if _regrowth == null or not is_instance_valid(_regrowth):
		_regrowth = get_tree().get_first_node_in_group(REGROWTH_GROUP)
	if _regrowth != null and _regrowth.has_method(&"get_appeal_factor"):
		return float(_regrowth.call(&"get_appeal_factor"))
	return 1.0


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
	var game_day_delta: float = \
			delta * TimeManager.time_scale / TimeManager.seconds_per_game_day
	_rain_integral += rain_intensity() * game_day_delta
	_rain_elapsed += game_day_delta


func _on_day_completed(_day_count: int) -> void:
	if SeasonManager.phase != SeasonManager.Phase.ACTIVE:
		return
	# Own rain integral, instantaneous fallback: the M-key debug path emits
	# day_completed in a synchronous loop with no _process between emissions.
	var avg_rain: float = rain_intensity()
	if _rain_elapsed > 0.001:
		avg_rain = _rain_integral / _rain_elapsed
	_rain_integral = 0.0
	_rain_elapsed = 0.0

	var visitors: int = visitors_for(avg_rain, appeal(), base_visitors_per_day)
	if visitors <= 0:
		return
	ResourceLedger.add(TOKENS, float(visitors) * tokens_per_visitor, SOURCE)
