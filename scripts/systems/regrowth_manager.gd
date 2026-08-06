class_name RegrowthManager
extends Node

## Tracks charred cells (fires that burned OUT — extinguished cells restore
## their own grass) and regrows them over days, faster in rain. Also the home
## of the tourism "appeal" factor: the more of the mountain is char, the fewer
## visitors come (VisitorFlow reads get_appeal_factor via the group).
##
## Listens to FireManager.tile_burned, which hands over the pre-burn grass
## atlas coord + layer — without that payload the coord dies with the burn
## entry and the cell would be dirt forever. Regrowth repaints the LAYER
## directly (set_cell), exactly as fire does in both directions: TileGrid never
## observes source-id swaps and doesn't need to (fire's own grass test reads
## the layer too).
##
## Recovery is rolled per charred cell once per completed day, using the day's
## AVERAGE rain (integrated here in _process — each per-day consumer keeps its
## own integral so there is no ordering coupling between day_completed
## listeners). A wet-season burn heals in a few days; a drought burn lingers
## most of a season. That asymmetry is the point: fire during the profitable
## dry season costs visitor-days exactly when they are worth the most.

const GROUP: StringName = &"regrowth"
const SOURCE_GRASS: int = 0

## Recovery probability per cell per completed day with zero rain.
## 0.15 ≈ a drought burn lingers most of a 6-day season.
@export var base_recovery_per_day: float = 0.15
## Added recovery probability at full-day full rain.
@export var rain_recovery_bonus: float = 0.5
## Charred-cell count at which visitor appeal reaches 0. The map has thousands
## of cells; 30 charred is already "the mountain is visibly scarred".
@export var charred_for_zero_appeal: int = 30

# cell -> {"coord": Vector2i, "layer": TileMapLayer}
var _charred: Dictionary = {}
# Day-average rain: integral of intensity over in-game days, plus elapsed.
var _rain_integral: float = 0.0
var _rain_elapsed: float = 0.0

var _day_night: Node = null
var _world_hooked: bool = false

# Recovery's own RNG stream (per-cell daily rolls). Randomly seeded for the
# game; the balance simulator seeds it per run for determinism.
var rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	add_to_group(GROUP)
	FireManager.tile_burned.connect(_on_tile_burned)
	TimeManager.day_completed.connect(_on_day_completed)


## Pure recovery model, static for tree-free tests.
static func recovery_probability(day_avg_rain: float, base_p: float,
		bonus: float) -> float:
	return clampf(base_p + bonus * clampf(day_avg_rain, 0.0, 1.0), 0.0, 1.0)


## Pure appeal model: 1.0 pristine, 0.0 at saturation charred cells.
static func appeal_factor(charred_count: int, saturation: int) -> float:
	if saturation <= 0:
		return 1.0
	return 1.0 - minf(1.0, float(charred_count) / float(saturation))


func charred_count() -> int:
	return _charred.size()


## Read by VisitorFlow (group lookup, fallback 1.0). Future trail/flora
## bonuses multiply in at the caller, not here — this is only the char term.
func get_appeal_factor() -> float:
	return appeal_factor(_charred.size(), charred_for_zero_appeal)


func rain_intensity() -> float:
	if _day_night == null or not is_instance_valid(_day_night):
		_day_night = get_tree().get_first_node_in_group(&"day_night_controller")
	if _day_night != null and _day_night.has_method(&"get_rain_current_intensity"):
		return float(_day_night.call(&"get_rain_current_intensity"))
	return 0.0


func _process(delta: float) -> void:
	tick(delta)


## The frame body, public so the headless simulator can drive fixed-dt steps
## with _process disabled. Identical logic either way.
func tick(delta: float) -> void:
	_hook_world_once()
	if SeasonManager.phase != SeasonManager.Phase.ACTIVE:
		return
	if TimeManager.paused or TimeManager.seconds_per_game_day <= 0.0:
		return
	var game_day_delta: float = \
			delta * TimeManager.time_scale / TimeManager.seconds_per_game_day
	_rain_integral += rain_intensity() * game_day_delta
	_rain_elapsed += game_day_delta


func _on_tile_burned(cell: Vector2i, grass_coord: Vector2i,
		grass_layer: TileMapLayer) -> void:
	if grass_layer == null or grass_coord.x < 0:
		return
	_charred[cell] = {"coord": grass_coord, "layer": grass_layer}


func _on_day_completed(_day_count: int) -> void:
	if SeasonManager.phase != SeasonManager.Phase.ACTIVE:
		return
	# Day-average rain from our own integral. The M-key debug path emits
	# day_completed in a synchronous loop with no _process in between, so
	# elapsed can be ~0 — fall back to the instantaneous intensity rather than
	# dividing by it.
	var avg_rain: float = rain_intensity()
	if _rain_elapsed > 0.001:
		avg_rain = _rain_integral / _rain_elapsed
	_rain_integral = 0.0
	_rain_elapsed = 0.0

	var p: float = recovery_probability(
			avg_rain, base_recovery_per_day, rain_recovery_bonus)
	for cell: Vector2i in _charred.keys():
		var rec: Dictionary = _charred[cell]
		var layer: TileMapLayer = rec["layer"] as TileMapLayer
		if layer == null or not is_instance_valid(layer):
			_charred.erase(cell)
			continue
		# Re-ignited before it recovered (needs the cell to be grass again, so
		# impossible today — cheap insurance against a future char-burns rule).
		if FireManager.is_burning(cell):
			continue
		if rng.randf() < p:
			layer.set_cell(cell, SOURCE_GRASS, rec["coord"] as Vector2i, 0)
			_charred.erase(cell)


# A regeneration repaints the same TileMapLayer nodes with a new world, so
# stale char records would corrupt fresh terrain. Mirror FireManager's wipe
# trigger. Lazy: ProceduralWorld joins its group in its own _ready, order
# unknown at ours.
func _hook_world_once() -> void:
	if _world_hooked:
		return
	var pw := get_tree().get_first_node_in_group(FireManager.PROCEDURAL_WORLD_GROUP)
	if pw == null:
		return
	if pw.has_signal(&"generation_finished"):
		pw.connect(&"generation_finished", _wipe)
	_world_hooked = true


func _wipe() -> void:
	_charred.clear()
	_rain_integral = 0.0
	_rain_elapsed = 0.0
