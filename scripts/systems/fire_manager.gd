extends Node

# ============================================================================
# FireManager (autoload)
# ============================================================================
#
# Owns the wildfire simulation: ignition rolls on low-altitude grass tiles,
# per-burning-cell burn progression, spread to 4-neighbour grass tiles, and
# the grass→dirt swap on burn-out.
#
# Lazy resolution: the autoload is alive across the title screen and other
# non-gameplay scenes. It silently idles while no Pathfinder exists, and picks
# one up the moment one enters the tree (via get_tree().node_added).
#
# It clears its state only when the WORLD is replaced — a different Pathfinder
# (scene load/reload) or a ProceduralWorld regeneration. Pathfinder.graph_changed
# on its own is not that: it also fires for every structure placement, which must
# leave burning cells untouched.
#
# Ignition tuning sits at the top of this file (BASE_IGNITION_RATE, day/altitude/
# water falloff). Burn/intensity/spread/fuel tuning lives in FireDynamics. Drop
# BASE_IGNITION_RATE (here) or FireDynamics.SPREAD_RATE for a calmer slice.
#
# Public signal:
#   tile_burned(cell)   emitted after a cell completes its burn.
#
# ============================================================================


# --- Tuning ----------------------------------------------------------------

# Per-sample chance, before all multipliers. Combined with K_IGNITION_SAMPLES
# this becomes ~K * BASE expected new-fire attempts per tick.
# 0.04 -> 0.01 (balance decision 2026-08-06): at 0.04 a 128-run sim sweep
# averaged ~2,450 ignitions/run with ~150 concurrent fires — 90% burned out
# untouched and the bot's ~6 douses/day were statistically irrelevant.
const BASE_IGNITION_RATE_PER_SAMPLE: float = 0.01
const K_IGNITION_SAMPLES: int = 4 # per ignition tick
const IGNITION_TICK_SECONDS: float = 0.25

## How often a burning cell rolls to spread. Matched to IGNITION_TICK_SECONDS,
## and to sim_runner's DT — see sim_tick for why those must agree.
const SPREAD_TICK_SECONDS: float = 0.25

# Burn progression, intensity, spread chance, and fuel consumption all live in
# FireDynamics now (the testable sim math). What remains here is ignition
# rolling, terrain gating, and the grass↔dirt swaps. A fire GROWS on its own
# from kindling and spreads BECAUSE it grew (intensity >= FireDynamics.SPREAD_MIN)
# — there is no isolated-cap ceiling anymore.

# Fuel a freshly-lit tile carries, before per-tile variety. FireDynamics is
# calibrated against FUEL_DEFAULT; a tile with more fuel simply burns longer.
const FUEL_DEFAULT: float = 1.0
# +/- fraction of hashed per-tile variation on FUEL_DEFAULT, so adjacent tiles
# don't burn in lockstep. Deterministic per cell. This is also the seam where a
# real long-vs-short-grass fuel value would come from later (see _fuel_for_cell).
const FUEL_VARIANCE: float = 0.35

const WATER_SEARCH_R: int = 6 # max bounded BFS radius (cells)
const ALTITUDE_FALLOFF_SCALE: float = 4.0 # exp(-alt / scale)
const DAY_SIGMA: float = 0.18 # day-curve gaussian width

# Ceiling on simultaneously burning cells — but read the next paragraph before
# treating it as one.
#
# IT ONLY GATES RANDOM IGNITION. `_roll_spread` calls `_ignite` directly rather
# than through `can_ignite`, so a fire front walks straight past this number.
# MEASURED at the previous value of 80, 12 seeds: peak_fires averaged 95 and hit
# 145. So it bounds how many fires the world STARTS, not how many burn, and the
# per-frame cost it is supposed to bound (FireManager._advance_burns, ~6 us per
# burning cell) scales with the number it does not control.
const MAX_CONCURRENT_BURNING: int = 64 # ignition cap — see above, NOT a ceiling

## First day_count on which the world lights its own fires. 1 = the opening day
## (day_count 0) never spontaneously ignites, which is what the FTUE is built on:
## the player learns to walk, read the journal and build without a fire on the
## mountain. Set to 0 for the pre-FTUE behaviour.
##
## Gates `_roll_ignitions` ONLY. `_roll_spread` and the public `ignite()` (the
## debug ignite action, the balance simulator's scripted burns) are untouched —
## on day 0 there is nothing to spread from anyway, and silencing the debug key
## would cost more than it buys.
var first_ignition_day: int = 1

# --- Rain coupling ---
# Spread chance hits zero at this rain intensity. Linear ramp from 0 (no rain
# = full spread) to RAIN_SPREAD_ZERO_AT (spread = 0).
const RAIN_SPREAD_ZERO_AT: float = 0.2
# Above this intensity, burning cells start rolling for extinguish each tick.
const RAIN_EXTINGUISH_THRESHOLD: float = 0.33
# Per-second extinguish chance at rain=1.0. Scales linearly between the
# threshold and 1.0.
const RAIN_EXTINGUISH_RATE_PER_SECOND: float = 0.8

const DAY_NIGHT_GROUP: StringName = &"day_night_controller"
const PROCEDURAL_WORLD_GROUP: StringName = &"procedural_world"

# Source IDs in base_tileset.tres — kept in sync with TerrainPainter.
const SOURCE_GRASS: int = 0
const SOURCE_WATER: int = 3
const SOURCE_DIRT: int = 2

const _WALKABLE_LAYER: String = "walkable"
const _TILE_KIND_LAYER: String = "tile_kind"

const _NEIGHBOR_DIRS: Array[Vector2i] = [
	Vector2i(1, 0),
	Vector2i(-1, 0),
	Vector2i(0, 1),
	Vector2i(0, -1),
]

const VFX_CONTAINER_GROUP: StringName = &"vfx_container"


# --- Signals ---------------------------------------------------------------

## A fire finished consuming its cell (burnout, not extinguish). Carries the
## pre-burn grass atlas coord + layer so a regrowth system can repaint the
## grass later — without them the coord dies with the _burning entry and the
## cell is dirt forever.
signal tile_burned(cell: Vector2i, grass_coord: Vector2i, grass_layer: TileMapLayer)

## A fire went out WITHOUT consuming its tile — rain, or a player douse. The
## counterpart to tile_burned, and deliberately a separate signal: the two leave
## the cell in opposite states (grass restored vs. dirt), so a listener that
## cares about one almost never cares about the other.
##
## Emitted from the one private _extinguish, so every route out — the rain roll
## and the public extinguish() the douse action calls — reports identically. The
## FTUE's fire step advances off this.
signal tile_extinguished(cell: Vector2i)


# --- State -----------------------------------------------------------------

var _pathfinder: Node = null # Pathfinder (typed loosely to avoid autoload class_name pin)
var _grid: Object = null # TileGrid
var _vfx_container: Node2D = null
var _time_manager: Node = null
var _day_night: Node = null # DayNightSceneController, for rain query
var _climate: Node = null # ClimateController, for the dryness ignition multiplier

# cell -> { "vfx": BurningCellVFX, "age": float, "fuel": float, "fuel_max": float,
#           "max_intensity": float, "frailejon": Node2D (or null),
#           "grass_coord": Vector2i, "grass_layer": TileMapLayer }
# age = seconds since ignition (drives the intensity ramp); fuel/fuel_max = the
# tile's grass being consumed (drives the dissolve and burnout); max_intensity =
# this fire's own random ceiling (some fires stay small). See FireDynamics.
var _burning: Dictionary = {}

# Fire's own RNG stream. Every gameplay roll (ignition sample/roll, spread,
# rain extinguish, per-fire intensity ceiling, dirt-variant pick) draws from
# here, never from the global stream — so VFX (which stays on the global
# stream) can't perturb outcomes, and the balance simulator can seed this
# per run for determinism. Randomly seeded on construction, so the live game
# is distributionally unchanged.
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

# The simulator runs fire without a scene: no BurningCellVFX node per
# ignition. Entries then carry "vfx": null, which every consumer already
# guards with is_instance_valid. The game leaves this true.
var spawn_vfx: bool = true

# Lifetime tallies for the balance simulator (polling the burning set can't
# see an ignition and its burnout landing in the same tick). Monotonic;
# readers snapshot and diff. The game never resets or reads them.
var stats_ignitions: int = 0
var stats_rain_extinguished: int = 0

var _water_dist_cache: Dictionary[Vector2i, int] = {}

# tile_set -> { tile_kind: Array[Vector2i] }. For each kind painted on the
# dirt source, every walkable atlas coord wearing that kind. Built lazily on
# first ignition; cleared on graph_changed when a new map (and possibly a new
# TileSet) replaces the live grid. Ignition picks one entry at random so
# burned patches show visual variety across adjacent cells of the same kind.
var _dirt_coords_by_tileset: Dictionary = {}

var _ignition_accum: float = 0.0
## Time banked toward the next spread roll. Separate from _ignition_accum even
## though both tick at 0.25 s: ignitions consume theirs in a `while` (so a long
## frame fires several rolls), while spread hands the WHOLE accumulated interval
## to one roll — the probability is linear in dt, so that is equivalent and
## cheaper.
var _spread_accum: float = 0.0


func _ready() -> void:
	_time_manager = get_node_or_null("/root/TimeManager")
	# Pathfinder may already exist (autoload loads after scene tree on instant
	# scene transitions) — try to grab one up front; otherwise we'll catch the
	# next one via node_added.
	_try_resolve_pathfinder()
	get_tree().node_added.connect(_on_node_added)


# --- Public query / control ------------------------------------------------

## True iff `cell` is currently on fire.
func is_burning(cell: Vector2i) -> bool:
	return _burning.has(cell)


## True iff `cell` could be set alight right now. Public because callers outside
## the natural-ignition path (the debug ignite action) have no other way to ask.
##
## The grass test is the load-bearing one. `_ignite` does NOT check it — the
## random-ignition and spread paths are only safe because THEY pre-filter on
## `_is_grass` before calling it. Ignite a non-grass cell directly and `_ignite`
## caches whatever atlas coord happened to be there as `grass_coord`, so a later
## extinguish repaints that foreign coord from SOURCE_GRASS and corrupts the
## tile. Any new caller must go through here rather than `_ignite`.
## Is the world allowed to start its OWN fires right now? False through the
## FTUE's opening day (see first_ignition_day). Says nothing about spread or
## about the public ignite() — both bypass it deliberately. Public so the gate
## is testable without reaching into _roll_ignitions.
func spontaneous_ignition_allowed() -> bool:
	if _time_manager == null:
		return true
	return int(_time_manager.day_count) >= first_ignition_day


func can_ignite(cell: Vector2i) -> bool:
	if _grid == null:
		return false
	if _burning.has(cell):
		return false
	# Respect the same safety cap the random rolls do — a debug tool shouldn't be
	# able to walk past the bound the whole VFX budget is sized against.
	if _burning.size() >= MAX_CONCURRENT_BURNING:
		return false
	return _is_grass(cell)


## Light a fire at `cell`: a fresh kindling at age 0, identical to what a
## random ignition produces — same spread, same burn, same VFX. Returns true if a
## fire actually started. Mirrors `extinguish`.
##
## The two optional arguments exist for ONE caller, the FTUE's scripted fire
## (see dev-notes/ftue.md), and both default to the natural behaviour:
##
##   `contained`  the fire never spreads. A fire lit to be walked to and put out
##                must still be one fire when the player arrives — the tutorial
##                asks for a single right click, and a front that has crossed
##                six tiles by then is a different, unwinnable lesson.
##   `fuel`       overrides the tile's own fuel (`< 0` keeps it). A default tile
##                burns out in ~10 s and the walk over is longer than that, so
##                the tutorial fire is given enough fuel to outlast the trip.
##
## Neither is reachable from the natural ignition path or from spread — this is
## the only entry point that can set them.
func ignite(cell: Vector2i, contained: bool = false, fuel: float = -1.0) -> bool:
	if not can_ignite(cell):
		return false
	_ignite(cell, contained, fuel)
	# _ignite can still bail (no grass source on the tileset, null CellData), so
	# report what actually happened rather than assuming it took.
	return _burning.has(cell)


## Put out the fire at `cell` (e.g. a player extinguish action). Rolls the cell
## back to its pre-ignition grass — same path rain uses, so no tile_burned
## fires. Returns true if a fire was actually extinguished.
func extinguish(cell: Vector2i) -> bool:
	if not _burning.has(cell):
		return false
	_extinguish(cell)
	return true


# --- Headless-driver surface (balance sim, tests) --------------------------
# The scene path attaches lazily via groups + call_deferred; a headless run
# happens inside ONE frame, so deferred work would land after the run ended.
# These are the only supported entry points for driving fire without a scene
# — reach-ins to _burning/_pathfinder/etc. couple callers to internals.

## Attach to `pf`'s world and start from a clean slate, synchronously.
func reset_to_world(pf: Node) -> void:
	_wipe_all_fires()
	if _pathfinder != pf:
		_attach_to_pathfinder(pf)
	_refresh_grid_and_vfx()
	_ignition_accum = 0.0


## Detach from the current world entirely (test teardown — the world node is
## about to be freed and _process must not touch its stale layers).
func detach_world() -> void:
	_wipe_all_fires()
	_pathfinder = null
	_grid = null


## Number of currently burning cells.
func burning_count() -> int:
	return _burning.size()


## Total cells in the attached world's TileGrid (0 with no world). Fire is the
## grid's owner-of-record among the autoloads, so consumers that need a
## whole-mountain denominator (RegrowthManager's appeal) read it here instead
## of finding the pathfinder themselves.
func grid_cell_count() -> int:
	return _grid.cell_count() if _grid != null else 0


## The attached TileGrid, or null. Same reasoning as grid_cell_count: fire owns
## the attach/detach lifecycle (pathfinder discovery, graph_changed, wipes), so
## a system that needs to read a cell's layer borrows it here rather than
## duplicating that lifecycle. Typed Object because TileGrid is resolved at
## runtime, exactly as _grid is.
func grid() -> Object:
	return _grid


## Read-only view of the burning set (cell -> entry). Returned BY REFERENCE
## on purpose: the sim's bot polls this every decision and must not pay a
## copy. Callers must not mutate it or hold it across a tick.
func burning_view() -> Dictionary:
	return _burning


func _on_node_added(n: Node) -> void:
	if _pathfinder != null and is_instance_valid(_pathfinder):
		return
	# A Pathfinder joins its group in _enter_tree before this hook runs.
	if n.is_in_group(&"pathfinder"):
		_attach_to_pathfinder(n)


func _try_resolve_pathfinder() -> void:
	var pf := get_tree().get_first_node_in_group(&"pathfinder")
	if pf != null:
		_attach_to_pathfinder(pf)


func _attach_to_pathfinder(pf: Node) -> void:
	if _pathfinder == pf:
		return
	# A DIFFERENT Pathfinder means a different world (scene load or reload) —
	# every fire belonged to the old one. This, and a world regeneration, are the
	# only two events that legitimately wipe the simulation; a mere graph_changed
	# is NOT one (see _on_graph_changed).
	if _pathfinder != null:
		_wipe_all_fires()
	_pathfinder = pf
	if pf.has_signal(&"graph_changed") and not pf.graph_changed.is_connected(_on_graph_changed):
		pf.graph_changed.connect(_on_graph_changed)
	# Resolve grid lazily — Pathfinder builds in its _ready. Defer one frame.
	call_deferred(&"_refresh_grid_and_vfx")


func _refresh_grid_and_vfx() -> void:
	if _pathfinder == null or not is_instance_valid(_pathfinder):
		return
	if _pathfinder.has_method(&"grid"):
		_grid = _pathfinder.grid()
	_vfx_container = get_tree().get_first_node_in_group(VFX_CONTAINER_GROUP) as Node2D
	if _vfx_container == null:
		# Fall back to the Pathfinder's scene root — the user may not have
		# wired a VFXContainer on a custom map yet.
		_vfx_container = _pathfinder.get_parent() as Node2D
	_day_night = get_tree().get_first_node_in_group(DAY_NIGHT_GROUP)
	# A world regeneration replaces the terrain under every live fire, so it IS a
	# wipe (unlike graph_changed). Connected here rather than in _ready because
	# the autoload outlives scenes and ProceduralWorld only exists inside one.
	var pw := get_tree().get_first_node_in_group(PROCEDURAL_WORLD_GROUP)
	if pw != null and pw.has_signal(&"generation_finished") \
			and not pw.is_connected(&"generation_finished", _wipe_all_fires):
		pw.connect(&"generation_finished", _wipe_all_fires)
	_water_dist_cache.clear()
	_prune_stale_burns()


func _on_graph_changed() -> void:
	# The graph changed SHAPE — a bridge or ladder landed, a rock was removed, or
	# Pathfinder rebuilt against the same painted map. This is NOT a new world, so
	# fires must survive it: every structure placement calls Pathfinder.rebuild(),
	# and wiping here put out every fire on the map the moment the player built
	# anything. A genuinely new world arrives as a new Pathfinder (scene reload)
	# or a regeneration — both wipe explicitly.
	#
	# Deferred: Pathfinder emits this from inside rebuild(), so re-resolve the
	# grid (and prune fires the new grid no longer has a tile for) next idle.
	call_deferred(&"_refresh_grid_and_vfx")


## Kill the whole simulation: live fires AND smouldering tails. Wipes by GROUP,
## not by _burning.values() — a cell that finished burning is already erased from
## _burning (see _complete_burn) while its VFX node lives on running the smoke
## tail, and a dictionary-based wipe would strand those over the new world.
func _wipe_all_fires() -> void:
	for v: Node in get_tree().get_nodes_in_group(BurningCellVFX.FIRE_VFX_GROUP):
		if is_instance_valid(v):
			v.queue_free()
	_burning.clear()
	_water_dist_cache.clear()
	_dirt_coords_by_tileset.clear()


# Drop burning cells the current grid can no longer describe: the TileMapLayer
# holding their grass overlay is gone, or the rebuilt grid has no tile at that
# cell (e.g. a bounds_clip change shrank the playable area). Everything else in
# an entry — age, fuel, the VFX node, the frailejon — is independent of the
# TileGrid instance, which is why a rebuild alone doesn't invalidate a fire.
func _prune_stale_burns() -> void:
	if _burning.is_empty():
		return
	for cell: Vector2i in _burning.keys():
		var entry: Dictionary = _burning[cell]
		var layer := entry.get("grass_layer") as TileMapLayer
		var alive: bool = is_instance_valid(layer) and layer.is_inside_tree()
		if alive and _grid != null and _grid.get_tile(cell) == null:
			alive = false
		if alive:
			continue
		var vfx := entry.get("vfx") as BurningCellVFX
		if is_instance_valid(vfx):
			vfx.queue_free()
		_burning.erase(cell)


# --- Per-frame loop --------------------------------------------------------

func _process(delta: float) -> void:
	# Same gates sim_tick applies, checked BEFORE _rain_intensity(): the rain
	# lookup is a validity check + dynamic call, and paying it every frame on
	# the title screen / pause / planning (where sim_tick would discard it) is
	# the only game-side cost the sim extraction added. Duplicating two cheap
	# branches removes it.
	if _grid == null:
		return
	if _time_manager != null and bool(_time_manager.get(&"paused")):
		return
	sim_tick(delta, _rain_intensity())


## One fire step at an explicit rain intensity. The frame path above and the
## headless balance simulator both run exactly this — the simulator calls it
## directly with a fixed dt and its own rain value.
func sim_tick(delta: float, rain: float) -> void:
	if _grid == null:
		return
	# Fire pauses with the game clock, like weather does. Without this gate,
	# fires burned/spread/ignited in REAL time through the title gate and the
	# planning phase (clock paused, player shopping) — a screen the player
	# can't fight from.
	if _time_manager != null and bool(_time_manager.get(&"paused")):
		return

	# Spread rolls on the SAME cadence as ignitions rather than every frame. The
	# probability is linear in dt (FireDynamics.spread_probability), so one roll
	# at 0.25 s carries the same expected spread as fifteen at 1/60 s — while
	# doing a fifteenth of the work. That work is not trivial: each roll walks
	# four neighbours, and each neighbour is a TileMapLayer query plus a level
	# check, for every burning cell, every frame.
	#
	# It also removes a GAME/SIM divergence nobody had noticed: sim_runner drives
	# this with DT = 0.25 exactly, so the balance model has ALWAYS measured
	# quarter-second spread rolls while the game rolled fifteen times as often at
	# a fifteenth the chance. Those are not identical — fifteen independent small
	# rolls spread ~4% less per unit time than one coarse roll, because they can
	# waste draws on the same neighbour. The game now matches what was balanced.
	var spread_dt: float = 0.0
	_spread_accum += delta
	if _spread_accum >= SPREAD_TICK_SECONDS:
		spread_dt = _spread_accum
		_spread_accum = 0.0

	_advance_burns(delta, rain, spread_dt)

	_ignition_accum += delta
	while _ignition_accum >= IGNITION_TICK_SECONDS:
		_ignition_accum -= IGNITION_TICK_SECONDS
		_roll_ignitions()


## `spread_dt` is 0 on the frames between spread rolls, and the accumulated
## interval on the frames one is due — see sim_tick.
func _advance_burns(delta: float, rain: float, spread_dt: float = 0.0) -> void:
	if _burning.is_empty():
		return
	# Cache rain-derived multipliers once per tick rather than per cell.
	var spread_mult: float = clampf(1.0 - rain / RAIN_SPREAD_ZERO_AT, 0.0, 1.0)
	var extinguish_p: float = 0.0
	if rain > RAIN_EXTINGUISH_THRESHOLD:
		var rain_excess: float = (rain - RAIN_EXTINGUISH_THRESHOLD) \
				/ maxf(1.0 - RAIN_EXTINGUISH_THRESHOLD, 0.0001)
		extinguish_p = clampf(rain_excess, 0.0, 1.0) \
				* RAIN_EXTINGUISH_RATE_PER_SECOND * delta

	var completed: Array[Vector2i] = []
	var extinguished: Array[Vector2i] = []
	# Snapshot keys so we can mutate _burning during spread.
	#
	# Skipping the snapshot on non-spread frames (iterating the dictionary
	# directly, since extinguish and burnout are both deferred to the arrays
	# above) was tried and REVERTED: it measured 402-459 us against 341 before,
	# i.e. nothing outside this measurement's ~20% run-to-run spread. The
	# untyped iteration it forced may well have cost more than the allocation it
	# saved. Don't re-derive it without a benchmark that can resolve the
	# difference.
	var cells: Array = _burning.keys()
	for cell: Vector2i in cells:
		var entry: Dictionary = _burning[cell]

		if extinguish_p > 0.0 and rng.randf() < extinguish_p:
			extinguished.append(cell)
			continue

		# Age drives the intensity ramp; fuel drives the dissolve + burnout. The
		# fire grows on its own (no neighbour term) and eats the tile's fuel at a
		# rate set by how hot it is.
		#
		# `.get` with a default rather than `entry[...]` on every read: the burn
		# entry's shape is a contract with the tests, several of which inject an
		# entry carrying only the fields they care about. Indexing directly would
		# be marginally faster and would turn those into crashes.
		var age: float = float(entry.get("age", 0.0)) + delta
		entry["age"] = age
		var fuel: float = float(entry.get("fuel", FUEL_DEFAULT))
		var fuel_frac: float = clampf(
				fuel / maxf(float(entry.get("fuel_max", FUEL_DEFAULT)), 0.0001), 0.0, 1.0)

		var intensity: float = FireDynamics.intensity(
				age, fuel_frac, float(entry.get("max_intensity", 1.0)))
		fuel -= FireDynamics.fuel_consumed(intensity, delta)
		entry["fuel"] = fuel

		var vfx: BurningCellVFX = entry.get("vfx") as BurningCellVFX
		if vfx != null and is_instance_valid(vfx):
			vfx.set_state(intensity, fuel_frac)

		var frj: Node = entry.get("frailejon") as Node
		if frj != null and is_instance_valid(frj) and frj.has_method(&"set_burn_amount"):
			# Char the plant as its tile's fuel is consumed (reaches 1 at burnout).
			frj.call(&"set_burn_amount", 1.0 - fuel_frac)

		# `contained` is the FTUE's scripted fire and nothing else (see ignite):
		# it burns and douses exactly like any other, it simply never seeds a
		# neighbour. Checked here rather than inside _roll_spread so a contained
		# fire costs nothing per tick instead of walking four neighbours to
		# refuse them all.
		if spread_dt > 0.0 and not bool(entry.get("contained", false)) \
				and intensity >= FireDynamics.SPREAD_MIN and spread_mult > 0.0:
			_roll_spread(cell, intensity, spread_dt, spread_mult)

		if fuel <= 0.0:
			completed.append(cell)

	stats_rain_extinguished += extinguished.size()
	for cell: Vector2i in extinguished:
		_extinguish(cell)
	for cell: Vector2i in completed:
		_complete_burn(cell)


func _roll_spread(from_cell: Vector2i, intensity: float, delta: float, rain_mult: float) -> void:
	# Spread chance rises with the source fire's intensity (quadratic above the
	# gate) — slow just over SPREAD_MIN, aggressive once hot. See FireDynamics.
	var p_per_neighbour: float = FireDynamics.spread_probability(intensity, delta, rain_mult)
	if p_per_neighbour <= 0.0:
		return
	# Strict elevation rule: a burning slope can't propagate, and spread only
	# crosses to coplanar flats at the same altitude (never up/down elevation).
	var from_cd = _grid.get_tile(from_cell)
	if from_cd == null or not _is_flat(from_cd):
		return
	for d in _NEIGHBOR_DIRS:
		var nb: Vector2i = from_cell + d
		if _burning.has(nb):
			continue
		if not _is_grass(nb):
			continue
		if not _same_flat_level(from_cd, nb):
			continue
		if rng.randf() < p_per_neighbour:
			_ignite(nb)


func _roll_ignitions() -> void:
	if _burning.size() >= MAX_CONCURRENT_BURNING:
		return
	if _grid == null:
		return
	if not spontaneous_ignition_allowed():
		return
	var b: Rect2i = _grid.bounds()
	if b.size.x <= 0 or b.size.y <= 0:
		return
	var day_mult: float = _day_curve()
	# Cheap early-out: at deep midnight, day_mult is near zero — skip the sampling.
	if day_mult < 0.001:
		return
	for i in K_IGNITION_SAMPLES:
		var c := Vector2i(
			b.position.x + rng.randi() % b.size.x,
			b.position.y + rng.randi() % b.size.y,
		)
		if _burning.has(c):
			continue
		if not _is_grass(c):
			continue

		var alt_mult: float = _altitude_falloff(_grid.altitude_center(c))
		var water_mult: float = _water_falloff(c)
		var p: float = BASE_IGNITION_RATE_PER_SAMPLE * day_mult * alt_mult \
				* water_mult * _climate_ignition_multiplier()
		if rng.randf() < p:
			_ignite(c)
			if _burning.size() >= MAX_CONCURRENT_BURNING:
				return


# --- Ignition / completion -------------------------------------------------

func _ignite(cell: Vector2i, contained: bool = false, fuel_override: float = -1.0) -> void:
	if _burning.has(cell):
		return
	var cd = _grid.get_tile(cell)
	if cd == null or cd.layer == null:
		return
	var layer: TileMapLayer = cd.layer
	var atlas_coords: Vector2i = layer.get_cell_atlas_coords(cell)
	var grass_src := layer.tile_set.get_source(SOURCE_GRASS) as TileSetAtlasSource
	if grass_src == null:
		return

	# Burned terrain keeps the cell's original shape (slope stays slope, etc.)
	# but swaps to a random walkable dirt variant of the same kind, so a
	# patch of charred ground shows visual variety. Fall back to FLAT if the
	# dirt source doesn't paint the cell's kind.
	var dirt_coord: Vector2i = pick_dirt_coord(layer.tile_set, cd.tile_kind)
	if dirt_coord.x < 0:
		dirt_coord = pick_dirt_coord(layer.tile_set, &"FLAT")

	# Swap underlying tile to dirt immediately. The BurningCellVFX overlay
	# holds the grass texture and dissolves it pixel-by-pixel — as alpha drops,
	# the freshly-painted dirt tile shows through. Skip the swap if even FLAT
	# wasn't painted on the dirt source (cell would otherwise go empty).
	if dirt_coord.x >= 0:
		layer.set_cell(cell, SOURCE_DIRT, dirt_coord, 0)

	# Headless simulation runs without the overlay node; every consumer of
	# entry["vfx"] already null/validity-guards.
	var vfx: BurningCellVFX = null
	if spawn_vfx:
		vfx = BurningCellVFX.new()
		vfx.setup(cell, layer, grass_src, atlas_coords)
		# Parent under the source TileMapLayer so the layer's altitude lift +
		# y_sort_origin place us in the same frame as the burning tile. Flames
		# then y-sort correctly against tiles on every other layer.
		layer.add_child(vfx)

	var occ: Node2D = cd.occupant
	var frailejon: Node = null
	if occ != null and occ.has_method(&"apply_burn_material"):
		occ.call(&"apply_burn_material")
		frailejon = occ

	var fuel: float = _fuel_for_cell(cell, cd)
	if fuel_override > 0.0:
		fuel = fuel_override
	stats_ignitions += 1
	_burning[cell] = {
		"vfx": vfx,
		"age": 0.0,
		"fuel": fuel,
		# fuel_max is what the dissolve and the flame size are read against, so a
		# high-fuel tutorial fire looks like a normal one at full burn rather than
		# like a tile that has barely started.
		"fuel_max": fuel,
		# Spread is refused from this cell for as long as it burns. Lives on the
		# entry rather than in a side table so it cannot outlive the fire.
		"contained": contained,
		# This fire's own intensity ceiling, rolled uniformly — some fires stay
		# small, some grow to full. See FireDynamics.intensity.
		"max_intensity": rng.randf_range(FireDynamics.MAX_INTENSITY_MIN, FireDynamics.MAX_INTENSITY_MAX),
		"frailejon": frailejon,
		# Cached for the extinguish-restore path: re-paint these on the source
		# layer to undo the ignition-time grass→dirt swap.
		"grass_coord": atlas_coords,
		"grass_layer": layer,
	}


# How much fuel a tile carries when it ignites. Uniform FUEL_DEFAULT today, with
# deterministic per-cell variance so burn durations differ tile-to-tile. This is
# the seam for real per-tile fuel later (long vs short grass): read it off
# cd.tile_kind or a future grass-length field instead of the flat default.
func _fuel_for_cell(cell: Vector2i, _cd) -> float:
	# Hash the cell to a stable [-1, 1] and scale by FUEL_VARIANCE. `_cd` carries
	# the cell's kind/altitude if a richer rule is ever wanted; unused for now.
	# posmod, not %: hash() can be negative and GDScript's % keeps the sign, which
	# would push jitter below -1 and starve some tiles to near-zero fuel.
	var h: int = posmod(hash(cell), 2000)
	var jitter: float = (float(h) / 1000.0 - 1.0) * FUEL_VARIANCE
	return maxf(FUEL_DEFAULT * (1.0 + jitter), 0.05)


func _extinguish(cell: Vector2i) -> void:
	# Rain put the fire out before it burned through. Roll the cell back to its
	# pre-ignition state: re-paint grass on the source layer, clear the
	# frailejon's burn material, and despawn the VFX. No tile_burned signal —
	# nothing actually finished burning. Assumes no other system has mutated
	# this cell since ignition (true today; FireManager is the only writer).
	var entry: Dictionary = _burning.get(cell, {})
	if entry.is_empty():
		return

	# Fade the flame out over DOUSE_SECONDS instead of vanishing on the spot. The
	# node has left _burning, so nothing drives it again — begin_douse self-drives
	# the fade in _process, like the smoulder tail. The grass is repainted below
	# now; the shrinking flame + its overlay cover the swap until it frees.
	var vfx: BurningCellVFX = entry.get("vfx") as BurningCellVFX
	if is_instance_valid(vfx):
		vfx.begin_douse()

	var grass_layer: TileMapLayer = entry.get("grass_layer") as TileMapLayer
	var grass_coord: Vector2i = entry.get("grass_coord", Vector2i(-1, -1))
	if grass_layer != null and grass_coord.x >= 0:
		grass_layer.set_cell(cell, SOURCE_GRASS, grass_coord, 0)

	var frj: Node = entry.get("frailejon") as Node
	if is_instance_valid(frj) and frj.has_method(&"clear_burn_material"):
		frj.call(&"clear_burn_material")

	_burning.erase(cell)
	# After the erase, so a listener that queries is_burning() from the handler
	# gets the state the signal is announcing rather than the one before it.
	tile_extinguished.emit(cell)


func _complete_burn(cell: Vector2i) -> void:
	var entry: Dictionary = _burning.get(cell, {})
	if entry.is_empty():
		return

	# Hand the VFX off to its smoulder tail rather than freeing it: a burnt-out
	# tile keeps smoking for a few seconds, then frees itself. It leaves _burning
	# now, so nothing here will drive it again — the tail is self-driving, and
	# _on_graph_changed wipes it by group if the map reloads mid-smoulder.
	var vfx: BurningCellVFX = entry.get("vfx") as BurningCellVFX
	if is_instance_valid(vfx):
		vfx.begin_smoulder()

	var frj: Node = entry.get("frailejon") as Node
	if is_instance_valid(frj):
		frj.queue_free()

	var grass_coord: Vector2i = entry.get("grass_coord", Vector2i(-1, -1))
	var grass_layer: TileMapLayer = entry.get("grass_layer") as TileMapLayer
	_burning.erase(cell)
	tile_burned.emit(cell, grass_coord, grass_layer)


# --- Probability terms -----------------------------------------------------

func _rain_intensity() -> float:
	if _day_night != null and is_instance_valid(_day_night) \
			and _day_night.has_method(&"get_rain_current_intensity"):
		return float(_day_night.call(&"get_rain_current_intensity"))
	return 0.0


# Dryness scaling from the scene's ClimateController. Fallback 1.0 keeps
# scenes without one (tests, tools) at the pre-climate ignition rate.
func _climate_ignition_multiplier() -> float:
	if _climate == null or not is_instance_valid(_climate):
		_climate = get_tree().get_first_node_in_group(&"climate")
	if _climate != null and _climate.has_method(&"get_ignition_multiplier"):
		return float(_climate.call(&"get_ignition_multiplier"))
	return 1.0


func _day_curve() -> float:
	if _time_manager == null:
		return 1.0
	var t: float = float(_time_manager.time_of_day)
	var dx: float = (t - 0.5) / DAY_SIGMA
	return exp(-dx * dx)


func _altitude_falloff(alt: float) -> float:
	# Smooth falloff: ~1.0 at altitude 0, ~exp(-3) ≈ 0.05 at altitude 12.
	return clampf(exp(-maxf(alt, 0.0) / ALTITUDE_FALLOFF_SCALE), 0.0, 1.0)


func _water_falloff(cell: Vector2i) -> float:
	var d: int = _distance_to_water(cell)
	if d <= 0:
		return 0.0
	if d >= WATER_SEARCH_R:
		return 1.0
	# Smooth ramp from 0 at d=1 to ~1.0 at d=WATER_SEARCH_R.
	return clampf(float(d) / float(WATER_SEARCH_R), 0.0, 1.0)


# --- Tile classification ---------------------------------------------------

func _is_grass(cell: Vector2i) -> bool:
	if _grid == null:
		return false
	var cd = _grid.get_tile(cell)
	if cd == null or cd.layer == null:
		return false
	return cd.layer.get_cell_source_id(cell) == SOURCE_GRASS


func _is_flat(cd) -> bool:
	# A flat tile sits at one altitude with no ramp. Slopes (rise_dir != ZERO)
	# and any cell whose low/high differ are "elevation" and block spread.
	return cd != null and cd.rise_dir == Vector2i.ZERO \
			and cd.altitude_low == cd.altitude_high


func _same_flat_level(from_cd, nb: Vector2i) -> bool:
	# Spread only between coplanar flats at the identical altitude.
	var nb_cd = _grid.get_tile(nb)
	if nb_cd == null:
		return false
	return _is_flat(nb_cd) and nb_cd.altitude_low == from_cd.altitude_low


func _is_water_layer(layer: TileMapLayer, cell: Vector2i) -> bool:
	if layer == null:
		return false
	return layer.get_cell_source_id(cell) == SOURCE_WATER


## A random walkable dirt variant of `kind`, or (-1, -1) if the dirt source
## doesn't paint that kind. Public because fire is no longer the only thing that
## bares a cell — RegrowthManager's trampling wears grass down to dirt and must
## produce the same shape-preserving variety, and the atlas scan is cached here.
##
## `stream` lets a caller draw from its OWN RNG. Fire's stream is replayed
## byte-for-byte by the balance simulator, so a second system drawing from it
## would silently make fire outcomes depend on how much walking happened.
func pick_dirt_coord(tile_set: TileSet, kind: StringName,
		stream: RandomNumberGenerator = null) -> Vector2i:
	if tile_set == null or String(kind).is_empty():
		return Vector2i(-1, -1)
	var by_kind: Dictionary = _dirt_coords_by_tileset.get(tile_set, {})
	if by_kind.is_empty():
		by_kind = _scan_dirt_walkable_by_kind(tile_set)
		_dirt_coords_by_tileset[tile_set] = by_kind
	var coords: Array = by_kind.get(kind, [])
	if coords.is_empty():
		return Vector2i(-1, -1)
	var draw: RandomNumberGenerator = stream if stream != null else rng
	return coords[draw.randi() % coords.size()]


# Returns { tile_kind: Array[Vector2i] } over the dirt source: every painted
# atlas coord, grouped by its tile_kind custom data, excluding any entry whose
# `walkable` custom data is explicitly false (unset is treated as walkable,
# matching TerrainPainter's convention). Only alternative 0 is considered —
# TerrainPainter writes alt 0 for ground tiles.
static func _scan_dirt_walkable_by_kind(tile_set: TileSet) -> Dictionary:
	var out: Dictionary = {}
	var src: TileSetAtlasSource = tile_set.get_source(SOURCE_DIRT) as TileSetAtlasSource
	if src == null:
		return out
	var walk_layer_id: int = -1
	var kind_layer_id: int = -1
	for i in tile_set.get_custom_data_layers_count():
		match tile_set.get_custom_data_layer_name(i):
			_WALKABLE_LAYER: walk_layer_id = i
			_TILE_KIND_LAYER: kind_layer_id = i
	if kind_layer_id < 0:
		push_warning(
			"FireManager: dirt source has no '%s' custom data layer — "
			% _TILE_KIND_LAYER
			+ "burned cells will not be repainted."
		)
		return out
	for i in src.get_tiles_count():
		var coord: Vector2i = src.get_tile_id(i)
		var data: TileData = src.get_tile_data(coord, 0)
		if data == null:
			continue
		if walk_layer_id >= 0:
			var w: Variant = data.get_custom_data_by_layer_id(walk_layer_id)
			if w is bool and not w:
				continue
		var k: Variant = data.get_custom_data_by_layer_id(kind_layer_id)
		if not (k is String) or (k as String).is_empty():
			continue
		var kind_name := StringName(k as String)
		if not out.has(kind_name):
			out[kind_name] = []
		(out[kind_name] as Array).append(coord)
	return out


func _distance_to_water(cell: Vector2i) -> int:
	# Bounded BFS, memoised. Returns 0 if `cell` itself is water,
	# WATER_SEARCH_R if no water is found within the radius.
	if _water_dist_cache.has(cell):
		return _water_dist_cache[cell]

	var visited: Dictionary[Vector2i, bool] = {}
	var queue: Array = [[cell, 0]]
	var head: int = 0
	visited[cell] = true
	var result: int = WATER_SEARCH_R
	while head < queue.size():
		var entry: Array = queue[head]
		head += 1
		var c: Vector2i = entry[0]
		var d: int = entry[1]

		var cd = _grid.get_tile(c)
		if cd != null and cd.layer != null and _is_water_layer(cd.layer, c):
			result = d
			break

		if d >= WATER_SEARCH_R:
			continue
		for dir in _NEIGHBOR_DIRS:
			var n := c + dir
			if visited.has(n):
				continue
			visited[n] = true
			queue.append([n, d + 1])

	_water_dist_cache[cell] = result
	return result
