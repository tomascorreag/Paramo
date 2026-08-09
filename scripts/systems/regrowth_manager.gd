class_name RegrowthManager
extends Node

## Owns how much GRASS is on each cell, as one continuous value per cell, and
## grows it back over days — faster in rain. Also the home of the tourism
## "appeal" factor: the barer the mountain, the fewer visitors come (VisitorFlow
## reads get_appeal_factor via the group).
##
## ---------------------------------------------------------------------------
## One value, many ways to lose it
## ---------------------------------------------------------------------------
##
## There are two sources of loss today — FIRE (burnout takes a cell to bare in
## one event) and FEET (visitors wear a cell down a little per step) — and they
## write the SAME number. That is deliberate. Before this, char was a set of
## cells and wear would have been a second set with an identical payload, which
## means two ledgers answering one question ("how grassy is this cell"), an
## appeal term that double-counts any cell in both, and a special case to stop
## it. Mining and construction are on the GDD's list and would each have been a
## third and fourth set. As one value they are all just subtractions.
##
## `vegetation_at` is also the seam FireManager._fuel_for_cell has been waiting
## for (see its comment): a worn cell carries less fuel. Not wired yet — that
## changes fire balance and belongs in its own change.
##
## ---------------------------------------------------------------------------
## Where the value lives, and why not on CellData
## ---------------------------------------------------------------------------
##
## CellData has unused `health`/`moisture`/`biodiversity` placeholders, but
## TileGrid.build() reconstructs every CellData from the layers, so anything
## written there is lost on the next graph rebuild — and rebuilds happen
## whenever the player places a structure. The ledger lives here instead, keyed
## by cell, and is only wiped when the WORLD is regenerated.
##
## Cells are only tracked once damaged. An untracked cell reads as full grass,
## so the dictionary stays proportional to the damage, not to the map.
##
## ---------------------------------------------------------------------------
## Painting
## ---------------------------------------------------------------------------
##
## There is no partial-grass art, so appearance is a threshold on the value:
## bare (dirt source) below `bare_threshold`, grass again above
## `regrow_threshold`. Those two are deliberately far apart — a single threshold
## makes a cell hovering at it flip between grass and dirt every single day.
## The gap also models the real thing: a path that has been walked bare stays
## bare a while after the walking stops, and re-bares quickly when it resumes,
## because the value keeps falling and rising underneath the paint.
##
## Repaints go straight to the TileMapLayer (set_cell), exactly as fire does in
## both directions: TileGrid never observes source-id swaps and doesn't need to
## (fire's own grass test reads the layer too).
##
## ---------------------------------------------------------------------------
## Recovery
## ---------------------------------------------------------------------------
##
## Recovery is a RATE per completed day, scaled by the day's AVERAGE rain
## (integrated here in _process — each per-day consumer keeps its own integral
## so there is no ordering coupling between day_completed listeners). A
## wet-season burn heals in a few days; a drought burn lingers most of a season.
## That asymmetry is the point: fire during the profitable dry season costs
## visitor-days exactly when they are worth the most.
##
## Each cell also carries its own recovery MULTIPLIER, drawn once when it is
## first damaged. That is what keeps a burn scar healing patchily now that
## recovery is continuous: without it every cell burned on the same day heals on
## the same day and the scar vanishes as a block. Drawn once rather than rolled
## daily, so a cell that heals slowly keeps healing slowly.

const GROUP: StringName = &"regrowth"
const SOURCE_GRASS: int = 0

## Fraction of a cell's grass restored per completed day with zero rain.
## 0.15 ≈ a drought burn takes most of a 6-day season, matching the expected
## time under the per-day probability model this replaced.
@export var base_recovery_per_day: float = 0.15
## Added recovery per day at full-day full rain.
@export var rain_recovery_bonus: float = 0.5
## Per-cell recovery multiplier is drawn from 1 ± this. Purely cosmetic in
## aggregate (the mean is unchanged); it exists so scars heal patchily.
@export_range(0.0, 0.9, 0.05) var recovery_rate_spread: float = 0.45

## Grass removed per visitor step. The whole trampling feature turns off at 0,
## which is the knob to use when isolating it during balance work.
##
## Read it against base_recovery_per_day, because that is what decides whether a
## track can exist at all: a cell heals ~0.15-0.65 a day, so at 0.06 a cell had
## to be crossed 3+ times EVERY day merely to break even, which essentially only
## happened at the trailhead funnel — hence the measured "no detectable effect on
## the ground". At 0.18 a couple of crossings a day holds a cell down and ~5
## wear it bare, so routes that genuinely overlap now leave a mark and the rest
## of the mountain still recovers. (0.36 is that doubled: ~2 crossings bare a
## cell, and one a day outpaces even a rainy day's recovery.)
@export var trample_per_step: float = 0.36

## The PLAYER's wear as a fraction of a visitor's, applied by Player and by the
## simulator's bot. One person walking their own mountain should leave a fainter
## mark than the public does, but not none — at 0 the player's own routes are
## the only traffic on the map that costs nothing, which reads as the mechanic
## being about tourists rather than about feet.
@export_range(0.0, 1.0, 0.05) var player_trample_fraction: float = 0.1
## Vegetation at or below which a cell is painted dirt...
@export var bare_threshold: float = 0.15
## ...and at or above which it is painted grass again. Must exceed
## bare_threshold or cells flip paint every day (see the header).
@export var regrow_threshold: float = 0.55

# cell -> {"coord": Vector2i, "layer": TileMapLayer, "kind": StringName,
#          "veg": float, "rate": float, "bare": bool}
var _veg: Dictionary = {}
# Running totals over _veg, maintained on every write instead of summed on
# demand. The balance simulator samples BOTH once per tick — ~23k times a run
# against a ledger that reaches several hundred cells — and summing there
# measured as roughly half the run's wall clock. Every mutation goes through
# _set_veg / _set_bare / _erase so these cannot drift; test_regrowth_manager
# recounts from scratch and compares.
var _deficit: float = 0.0
var _bare: int = 0
# Day-average rain: integral of intensity over in-game days, plus elapsed.
var _rain_integral: float = 0.0
var _rain_elapsed: float = 0.0

var _day_night: Node = null
var _world_hooked: bool = false

# Recovery's own RNG stream (per-cell rate draws, dirt-variant picks). Randomly
# seeded for the game; the balance simulator seeds it per run for determinism.
var rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	add_to_group(GROUP)
	FireManager.tile_burned.connect(_on_tile_burned)
	TimeManager.day_completed.connect(_on_day_completed)


## Pure recovery model, static for tree-free tests. Returns the fraction of a
## cell's grass restored in one day before the per-cell multiplier.
static func recovery_per_day(day_avg_rain: float, base_rate: float,
		bonus: float) -> float:
	return clampf(base_rate + bonus * clampf(day_avg_rain, 0.0, 1.0), 0.0, 1.0)


## Pure appeal model (balance decision 2026-08-06): every tile has a NATURAL
## state, and appeal is simply the fraction of the mountain still in it —
## water, stone and cliffs count in the total and are always natural. Missing
## grass is the only non-natural state today, and it is now CONTINUOUS: a cell
## half worn contributes half a cell of loss. 1.0 pristine, 0.0 only if
## literally every cell is bare.
## (Replaces the old 30-cell saturation constant, under which steady-state
## char of ~200+ cells pinned appeal to 0 for entire runs.)
static func appeal_factor(non_natural: float, total_cells: int) -> float:
	if total_cells <= 0:
		return 1.0
	return 1.0 - minf(1.0, maxf(non_natural, 0.0) / float(total_cells))


## Cells currently painted dirt. The headline "how scarred is the mountain"
## number; vegetation_deficit is the precise one.
func bare_count() -> int:
	return _bare


## Total grass missing, in cells. A fully bare cell contributes 1.0, a cell at
## half vegetation contributes 0.5.
func vegetation_deficit() -> float:
	return _deficit


# --- The only three mutators. Everything else goes through them. -------------

func _set_veg(rec: Dictionary, value: float) -> void:
	var clamped: float = clampf(value, 0.0, 1.0)
	_deficit += float(rec["veg"]) - clamped
	rec["veg"] = clamped


func _set_bare(rec: Dictionary, value: bool) -> void:
	if bool(rec["bare"]) == value:
		return
	rec["bare"] = value
	_bare += 1 if value else -1


func _erase(cell: Vector2i) -> void:
	var rec: Dictionary = _veg.get(cell, {})
	if rec.is_empty():
		return
	_deficit -= 1.0 - float(rec["veg"])
	if bool(rec["bare"]):
		_bare -= 1
	_veg.erase(cell)


## 0 (bare) .. 1 (untouched grass). Untracked cells are undamaged by
## definition, which includes water and stone — callers that care about those
## should be asking the layer, not this.
func vegetation_at(cell: Vector2i) -> float:
	var rec: Dictionary = _veg.get(cell, {})
	return 1.0 if rec.is_empty() else float(rec["veg"])


func is_bare(cell: Vector2i) -> bool:
	var rec: Dictionary = _veg.get(cell, {})
	return not rec.is_empty() and bool(rec["bare"])


## Read by VisitorFlow (group lookup, fallback 1.0). Future trail/flora
## bonuses multiply in at the caller, not here — this is only the natural-
## fraction term. The denominator is the whole TileGrid, via FireManager (the
## grid's owner among the autoloads); no grid attached -> 1.0, matching the
## static's total<=0 rule.
func get_appeal_factor() -> float:
	return appeal_factor(vegetation_deficit(), FireManager.grid_cell_count())


## Wear from a footfall. `amount` defaults to trample_per_step.
##
## Called per visitor step (Visitor._on_step_started), so it must stay cheap and
## must tolerate being handed any cell at all: water, stone, a cell that is
## already bare, a cell that is on fire. Only GRASS wears.
##
## Note this is the ONLY thing that makes traffic visible, and it is a pure
## consequence of where visitors happen to walk — nothing routes toward worn
## ground. Tracks therefore appear where routes genuinely overlap (the trailhead
## funnel, popular goals) and stay diffuse elsewhere.
func trample(cell: Vector2i, amount: float = -1.0) -> void:
	var wear: float = trample_per_step if amount < 0.0 else amount
	if wear <= 0.0:
		return
	var rec: Dictionary = _veg.get(cell, {})
	if rec.is_empty():
		rec = _begin_tracking(cell)
		if rec.is_empty():
			return
	# A burning cell is already dirt and is fire's to resolve; walking on it
	# must not pre-empt the burnout that registers the damage.
	if FireManager.is_burning(cell):
		return
	_set_veg(rec, float(rec["veg"]) - wear)
	_refresh_paint(cell, rec)


## Wear from the PLAYER's own footfall — trample() at player_trample_fraction.
##
## A separate entry point rather than a flag on trample(), because the two
## callers are different KINDS of traffic and the ratio between them is the
## thing being tuned; a caller that had to pass the amount could drift from it.
func trample_by_player(cell: Vector2i) -> void:
	trample(cell, trample_per_step * player_trample_fraction)


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


# --- Damage -----------------------------------------------------------------

# Start tracking an undamaged cell, capturing what it takes to put it back:
# the exact grass variant it was wearing and the layer it is painted on. Only
# grass qualifies — everything else has no grass to lose.
func _begin_tracking(cell: Vector2i, layer: TileMapLayer = null,
		coord: Vector2i = Vector2i(-1, -1)) -> Dictionary:
	var kind: StringName = &"FLAT"
	if layer == null:
		var grid: Object = FireManager.grid()
		if grid == null:
			return {}
		var cd = grid.get_tile(cell)
		if cd == null or cd.layer == null:
			return {}
		layer = cd.layer
		if layer.get_cell_source_id(cell) != SOURCE_GRASS:
			return {}
		coord = layer.get_cell_atlas_coords(cell)
		kind = cd.tile_kind
	if coord.x < 0:
		return {}
	var rec: Dictionary = {
		"coord": coord,
		"layer": layer,
		"kind": kind,
		"veg": 1.0,
		# Drawn once, never re-rolled — see the header.
		"rate": rng.randf_range(1.0 - recovery_rate_spread, 1.0 + recovery_rate_spread),
		"bare": false,
	}
	_veg[cell] = rec
	return rec


# Fire took the cell all the way down in one event, and painted the dirt itself
# at ignition — so this records the loss without repainting. The payload is the
# pre-burn grass coord + layer; without it the coord dies with the burn entry
# and the cell would be dirt forever.
func _on_tile_burned(cell: Vector2i, grass_coord: Vector2i,
		grass_layer: TileMapLayer) -> void:
	if grass_layer == null or grass_coord.x < 0:
		return
	var rec: Dictionary = _veg.get(cell, {})
	if rec.is_empty():
		rec = _begin_tracking(cell, grass_layer, grass_coord)
		if rec.is_empty():
			return
	_set_veg(rec, 0.0)
	_set_bare(rec, true)


# --- Painting ---------------------------------------------------------------

func _refresh_paint(cell: Vector2i, rec: Dictionary) -> void:
	var layer: TileMapLayer = rec["layer"] as TileMapLayer
	if layer == null or not is_instance_valid(layer):
		_erase(cell)
		return
	var veg: float = float(rec["veg"])
	if not bool(rec["bare"]) and veg <= bare_threshold:
		# Keeps the cell's shape (a slope stays a slope) and picks a random dirt
		# variant of the same kind, so worn ground has the same visual variety
		# burned ground does. Drawn from OUR rng, never fire's.
		var dirt: Vector2i = FireManager.pick_dirt_coord(
				layer.tile_set, rec["kind"] as StringName, rng)
		if dirt.x < 0:
			dirt = FireManager.pick_dirt_coord(layer.tile_set, &"FLAT", rng)
		if dirt.x < 0:
			return  # no dirt art for this cell; leave it grass rather than empty
		layer.set_cell(cell, FireManager.SOURCE_DIRT, dirt, 0)
		_set_bare(rec, true)
	elif bool(rec["bare"]) and veg >= regrow_threshold:
		layer.set_cell(cell, SOURCE_GRASS, rec["coord"] as Vector2i, 0)
		_set_bare(rec, false)


# --- Recovery ---------------------------------------------------------------

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

	var rate: float = recovery_per_day(
			avg_rain, base_recovery_per_day, rain_recovery_bonus)
	for cell: Vector2i in _veg.keys():
		var rec: Dictionary = _veg[cell]
		var layer: TileMapLayer = rec["layer"] as TileMapLayer
		if layer == null or not is_instance_valid(layer):
			_erase(cell)
			continue
		# Still alight: it is still losing grass, not regaining it.
		if FireManager.is_burning(cell):
			continue
		_set_veg(rec, float(rec["veg"]) + rate * float(rec["rate"]))
		_refresh_paint(cell, rec)
		# Fully recovered and repainted: stop tracking, so the ledger stays
		# proportional to the damage rather than growing all run.
		if float(rec["veg"]) >= 1.0 and not bool(rec["bare"]):
			_erase(cell)


# A regeneration repaints the same TileMapLayer nodes with a new world, so stale
# records would corrupt fresh terrain. Mirror FireManager's wipe trigger. Lazy:
# ProceduralWorld joins its group in its own _ready, order unknown at ours.
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
	_veg.clear()
	_deficit = 0.0
	_bare = 0
	_rain_integral = 0.0
	_rain_elapsed = 0.0
