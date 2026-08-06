class_name WaterCycle
extends Node

## Generates the player's water reserve while a run is ACTIVE: a slow constant
## trickle (fog capture — the páramo's frailejones and moss pulling moisture out
## of the cloud), plus a much larger term scaled by how hard it is currently
## raining.
##
## Deliberate override of ResourceLedger's "generation is season-quantized"
## stance: seeing the reserve climb *while it rains* is the point of the system,
## and a lump sum at the season boundary can't do that. The concern that header
## raises — continuous trickles inviting per-second optimization — doesn't bite
## here because the player has no lever on the weather. See the ledger's header
## for the full note.
##
## A scene node (wired into gameplay_base.tscn), not an autoload: it is
## scene-scoped gameplay, and a plain Node can be instantiated directly in a
## test. Rain is polled off DayNightSceneController exactly the way FireManager
## does it — there is no rain_started/rain_stopped signal anywhere in the
## codebase, and inventing one for this would leave two mechanisms for the same
## question.

## DayNightSceneController's group. It owns the weather state machine and is the
## only thing that knows the live rain intensity.
const DAY_NIGHT_GROUP: StringName = &"day_night_controller"

const WATER: StringName = &"water"

## Ledger source tags. Split so the end-screen's source_breakdown() can say how
## much of the run's water fell as rain versus condensed out of the fog — one
## extra accumulator now, versus a retrofit that can't recover history later.
const SOURCE_FOG: StringName = &"fog_capture"
const SOURCE_RAIN: StringName = &"rainfall"

## Real seconds between ledger commits. Accrual is computed every frame but
## banked on this beat, so resource_changed (and the journal label it drives)
## fires ~2x/second instead of 60x. Same accumulator shape as FireManager's
## ignition tick.
const COMMIT_INTERVAL: float = 0.5

## Water per in-game DAY from fog capture, regardless of weather.
##
## Rates are per game-day rather than per real second on purpose: retuning
## TimeManager.seconds_per_game_day for the balance pass then doesn't silently
## rescale the economy, and RunController's F fast-forward (time_scale = 60)
## speeds water up with everything else instead of desyncing from it.
@export var base_per_game_day: float = 2.0

## Additional water per in-game day at full rain (rain_amount 1.0), scaled
## linearly by the current intensity. Set well above base_per_game_day — "water
## comes from rain" has to be legible in the number, not just true in the math.
@export var rain_per_game_day_at_full: float = 30.0

var _day_night: Node = null
var _fog_accum: float = 0.0
var _rain_accum: float = 0.0
var _commit_accum: float = 0.0


## Water accrued over `game_day_delta` (in fractions of an in-game day) at the
## given rain intensity. Pure and static — the whole rate model is testable with
## no tree, no autoloads and no weather, mirroring FireDynamics.
static func gain_for(game_day_delta: float, rain: float,
		base_rate: float, rain_rate: float) -> float:
	return (base_rate + rain_rate * clampf(rain, 0.0, 1.0)) * game_day_delta


## Current total accrual rate, water per in-game day, at the live rain
## intensity. For the debug overlay and tests.
func rate_per_game_day() -> float:
	return gain_for(1.0, rain_intensity(), base_per_game_day, rain_per_game_day_at_full)


## Live rain intensity in [0, 1], or 0.0 when no DayNightSceneController is
## reachable (a bare test scene, or the title screen).
func rain_intensity() -> float:
	if _day_night == null or not is_instance_valid(_day_night):
		_day_night = get_tree().get_first_node_in_group(DAY_NIGHT_GROUP)
	if _day_night != null and _day_night.has_method(&"get_rain_current_intensity"):
		return float(_day_night.call(&"get_rain_current_intensity"))
	return 0.0


func _process(delta: float) -> void:
	# The run spine gates accrual, not visibility: this node lives in the
	# gameplay scene, which is also up behind the title screen and during the
	# planning phase. Neither should fill the reserve.
	if SeasonManager.phase != SeasonManager.Phase.ACTIVE:
		return
	if TimeManager.paused or TimeManager.seconds_per_game_day <= 0.0:
		return

	# Same conversion TimeManager uses to advance time_of_day, so water and the
	# clock can never drift apart.
	var game_day_delta: float = delta * TimeManager.time_scale / TimeManager.seconds_per_game_day
	var rain: float = rain_intensity()
	_fog_accum += gain_for(game_day_delta, 0.0, base_per_game_day, 0.0)
	_rain_accum += gain_for(game_day_delta, rain, 0.0, rain_per_game_day_at_full)

	_commit_accum += delta
	if _commit_accum >= COMMIT_INTERVAL:
		_commit_accum = 0.0
		flush()


## Bank whatever has accrued since the last commit. Called on the commit beat;
## public so tests can drive it deterministically without waiting out the timer.
func flush() -> void:
	if _fog_accum > 0.0:
		ResourceLedger.add(WATER, _fog_accum, SOURCE_FOG)
		_fog_accum = 0.0
	if _rain_accum > 0.0:
		ResourceLedger.add(WATER, _rain_accum, SOURCE_RAIN)
		_rain_accum = 0.0
