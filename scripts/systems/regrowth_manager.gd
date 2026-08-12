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
## Appearance follows the value CONTINUOUSLY, in two stages.
##
## Above `bare_threshold` the cell is grass, and its LENGTH tracks the value: the
## atlas paints the same cube at several grass lengths per tone, GrassLadder
## orders them, and the value is cut into one band per rung. The ceiling is the
## variant TERRAIN GENERATION chose for that cell — grass grows back to the stand
## that belongs there and no further — and the ladder never leaves that variant's
## tone, so a cell keeps its grass TYPE while its length moves. A cell whose
## variant has no shorter form (a slope, a wall, a stair) simply has
## one rung and behaves as it always did.
##
## Below `bare_threshold` it is dirt, and it takes `regrow_threshold` to come
## back. Those two are deliberately far apart — at a single threshold a cell
## hovering there flips between grass and dirt every day. The gap also models the
## real thing: a path walked bare stays bare a while after the walking stops, and
## re-bares quickly when it resumes, because the value keeps falling and rising
## underneath the paint. The rung boundaries above it get the same treatment at a
## much smaller scale, via `grass_step_hysteresis`.
##
## Repaints go straight to the TileMapLayer (set_cell), exactly as fire does in
## both directions: TileGrid never observes source-id swaps and doesn't need to
## (fire's own grass test reads the layer too).
##
## ---------------------------------------------------------------------------
## Recovery
## ---------------------------------------------------------------------------
##
## Recovery is a RATE PER DAY, scaled by rain: a wet-season burn heals in a few
## days, a drought burn lingers most of a season. That asymmetry is the point —
## fire during the profitable dry season costs visitor-days exactly when they
## are worth the most.
##
## It is APPLIED CONTINUOUSLY, not at the day boundary. It used to run as one
## pass per completed day, which meant grass came back in a single step 240 real
## seconds wide: a scar sat unchanged all day and then jumped. Recovery is a
## continuous process and now looks like one.
##
## What makes the cadence free to change is that no cell recovers "a day's
## worth" — each integrates its own elapsed time against two MONOTONIC clocks
## (`_days`, `_rain_days`), so the authored per-day rate is exact whether a cell
## is visited every frame, once a second, or late because the ledger grew. The
## sweep therefore only has to promise that every cell is visited within
## `sweep_seconds`; it makes no promise about when or in what order, which is
## what lets it bound its per-frame cost by walking a slice.
##
## Rain is integrated the same way rather than averaged per day, so a downpour
## heals the mountain WHILE IT RAINS instead of retroactively at midnight.
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
## of the mountain still recovers. (It sat at 0.36 — that doubled — for a while:
## ~2 crossings bare a cell and one a day outpaces even a rainy day's recovery,
## which read as too punishing on the ground; halved back to the measured rate.)
@export var trample_per_step: float = 0.18

## The PLAYER's wear as a fraction of a visitor's, applied by Player and by the
## simulator's bot. One person walking their own mountain should leave a fainter
## mark than the public does, but not none — at 0 the player's own routes are
## the only traffic on the map that costs nothing, which reads as the mechanic
## being about tourists rather than about feet.
@export_range(0.0, 1.0, 0.05) var player_trample_fraction: float = 0.1
## Real seconds in which the whole damaged-cell ledger is swept once.
##
## Recovery USED to be applied in one pass at each midnight, which made grass
## return in a single step 240 real seconds wide — a scar sat unchanged all day
## and then jumped. It is a continuous process, so it now runs continuously; a
## second is far below the eye's threshold for "the mountain is healing" and far
## above the cost of a sweep.
##
## It is NOT a rate. Recovery per day is authored by base_recovery_per_day and
## rain_recovery_bonus, and each cell integrates against a monotonic clock, so
## changing this changes only how smoothly and how often the value moves — never
## how much grass a day returns. That is exactly why it is safe to expose.
@export var sweep_seconds: float = 4.0

## Vegetation at or below which a cell is painted dirt...
@export var bare_threshold: float = 0.15
## ...and at or above which it is painted grass again. Must exceed
## bare_threshold or cells flip paint every day (see the header).
@export var regrow_threshold: float = 0.55

## How far the value must move PAST a rung boundary before the grass changes
## length, in vegetation units. The same deadband bare_threshold/regrow_threshold
## give the dirt swap, applied to every rung above it: without one, a cell
## sitting on a boundary — walked a little each day, healing a little each day,
## which is exactly what a lightly used route does — would re-cut its tile every
## sweep. Costs nothing at rest; the rung only moves when the value really moves.
@export var grass_step_hysteresis: float = 0.03

# cell -> {"coord": Vector2i, "layer": TileMapLayer, "kind": StringName,
#          "veg": float, "rate": float, "bare": bool,
#          "top": int, "rung": int, "d": float, "i": float}
# "coord" is the variant TERRAIN GENERATION chose, "top" its rung on that
# variant's grass ladder (the cell's maximum length) and "rung" the length it is
# currently wearing — see _rung_for.
# "d"/"i" are the clock and rain-integral readings when this cell last recovered
# — see _recover_cell.
var _veg: Dictionary = {}
# The same cells in a stable order, so the sweep below can walk a SLICE of the
# ledger per frame by index. Dictionary has no indexed access and .keys() would
# allocate an array of every damaged cell every frame. Maintained by
# _begin_tracking and _erase, the only two places _veg gains or loses a key.
var _order: Array[Vector2i] = []
# Where the next slice starts. Wraps; survives ledger growth because a cell's
# recovery is integrated from its OWN last-visit stamp, so an uneven walk is
# still exact.
var _cursor: int = 0
# Running totals over _veg, maintained on every write instead of summed on
# demand. The balance simulator samples BOTH once per tick — ~23k times a run
# against a ledger that reaches several hundred cells — and summing there
# measured as roughly half the run's wall clock. Every mutation goes through
# _set_veg / _set_bare / _erase so these cannot drift; test_regrowth_manager
# recounts from scratch and compares.
var _deficit: float = 0.0
var _bare: int = 0
# MONOTONIC clocks, never reset: game-days elapsed, and the integral of rain
# intensity over those days. A cell's recovery is the difference between the
# readings now and at its last visit, which is what lets the sweep run at any
# cadence — or unevenly — and still restore exactly the authored amount per day.
#
# They replace the old per-day accumulator pair, which had to be zeroed at every
# midnight and therefore only worked if recovery ran exactly at midnight too.
var _days: float = 0.0
var _rain_days: float = 0.0

var _day_night: Node = null
var _world_hooked: bool = false

# Grass-length ladders, read off the atlas once per TileSet. Every ground layer
# on a map shares one TileSet, so this is built on the first damaged cell and
# then reused for the whole run; it is keyed by the resource rather than cached
# outright so a fixture (or a second map) with a different atlas cannot inherit
# the wrong ladders.
var _ladder: GrassLadder = null
var _ladder_tile_set: TileSet = null

# Recovery's own RNG stream (per-cell rate draws, dirt-variant picks). Randomly
# seeded for the game; the balance simulator seeds it per run for determinism.
var rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	add_to_group(GROUP)
	FireManager.tile_burned.connect(_on_tile_burned)


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
	# Swap-remove: order carries no meaning (the sweep only needs to visit every
	# cell, not visit them in sequence), and erase-by-value on a several-hundred
	# entry array would be O(n) per healed cell.
	var at: int = _order.find(cell)
	if at >= 0:
		_order[at] = _order[_order.size() - 1]
		_order.resize(_order.size() - 1)


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
	_days += game_day_delta
	_rain_days += rain_intensity() * game_day_delta
	_sweep(delta)


## Recover a SLICE of the ledger, sized so the whole of it is covered every
## `sweep_seconds`.
##
## Why a slice rather than the whole ledger: the cost of a full pass is
## proportional to the scar, and the scar reaches several hundred cells in a bad
## run (measured 0.4-0.7 ms at 170 cells). Running that every frame would put a
## system that changes almost nothing on any given frame among the most
## expensive in the game. A slice bounds the per-frame cost instead, and because
## each cell integrates from its OWN last-visit stamp, being visited unevenly —
## or late, or twice in quick succession after the ledger grows — changes
## nothing about how much grass it regains per day.
func _sweep(delta: float) -> void:
	var n: int = _order.size()
	if n == 0:
		return
	var seconds: float = maxf(sweep_seconds, 0.001)
	# Ceil, so a small ledger still finishes inside the window and a large one
	# never stalls.
	var slice: int = int(ceil(float(n) * minf(delta / seconds, 1.0)))
	for i in mini(slice, n):
		if _cursor >= _order.size():
			_cursor = 0
		# _recover_cell can erase the cell (fully healed, or its layer died),
		# which swap-removes another cell INTO this slot — so only step forward
		# when it survived, or that cell is skipped this round.
		if _recover_cell(_order[_cursor]):
			_cursor += 1


## Bring one cell up to date. Returns false if the record was erased.
##
## The recovery is INTEGRATED between this cell's last visit and now, from the
## two monotonic clocks:
##
##     regained = (base + bonus * mean rain over the interval)
##                * days elapsed * this cell's own multiplier
##
## and since the mean rain over an interval is exactly the rain-integral delta
## divided by the day delta, the bonus term collapses to `bonus * rain_delta` —
## no per-cell rain history is needed. That is what keeps the authored rate "per
## day" while the sweep runs whenever it likes.
func _recover_cell(cell: Vector2i) -> bool:
	var rec: Dictionary = _veg.get(cell, {})
	if rec.is_empty():
		return false
	var layer: TileMapLayer = rec["layer"] as TileMapLayer
	if layer == null or not is_instance_valid(layer):
		_erase(cell)
		return false

	var d_delta: float = _days - float(rec["d"])
	var i_delta: float = _rain_days - float(rec["i"])
	# Stamped even when nothing is applied below, so a cell that spent the
	# interval on fire cannot bank it and heal retroactively once it goes out.
	rec["d"] = _days
	rec["i"] = _rain_days
	if d_delta <= 0.0:
		return true
	# Still alight: it is still losing grass, not regaining it.
	if FireManager.is_burning(cell):
		return true

	var avg_rain: float = clampf(i_delta / d_delta, 0.0, 1.0)
	var rate: float = recovery_per_day(
			avg_rain, base_recovery_per_day, rain_recovery_bonus)
	_set_veg(rec, float(rec["veg"]) + rate * d_delta * float(rec["rate"]))
	_refresh_paint(cell, rec)
	# Fully recovered and repainted: stop tracking, so the ledger stays
	# proportional to the damage rather than growing all run.
	if float(rec["veg"]) >= 1.0 and not bool(rec["bare"]):
		_erase(cell)
		return false
	return true


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
	# The variant generation chose IS the cell's longest grass, so its rung is
	# both the ceiling and the starting length. Captured here, at the one moment
	# the cell is known to be undamaged — the painted coord after this point is
	# whatever length the wear has left, and reading the ceiling off that would
	# ratchet the cell shorter every time it was re-tracked.
	var top: int = _ladder_for(layer).top_rung(coord)
	var rec: Dictionary = {
		"coord": coord,
		"layer": layer,
		"kind": kind,
		"veg": 1.0,
		"top": top,
		"rung": top,
		# Drawn once, never re-rolled — see the header.
		"rate": rng.randf_range(1.0 - recovery_rate_spread, 1.0 + recovery_rate_spread),
		"bare": false,
		# Recovery is integrated from HERE, so a cell damaged mid-interval is not
		# credited for the part of it that happened before the damage.
		"d": _days,
		"i": _rain_days,
	}
	_veg[cell] = rec
	_order.append(cell)
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
	var was_bare: bool = bool(rec["bare"])

	if not was_bare and veg <= bare_threshold:
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
		return
	if was_bare and veg < regrow_threshold:
		return

	# Grass is standing (or coming back): wear it at the length the value has
	# earned. On a cell whose variant has no shorter form this collapses to the
	# old behaviour — one rung, so the coord never changes and the only paint
	# that ever happens is the dirt swap above and the return from it.
	var rung: int = _rung_for(veg, int(rec["top"]), int(rec["rung"]))
	if not was_bare and rung == int(rec["rung"]):
		return
	rec["rung"] = rung
	layer.set_cell(cell, SOURCE_GRASS,
			_ladder_for(layer).coord_at(rec["coord"] as Vector2i, rung), 0)
	_set_bare(rec, false)


# The rung a cell wears at `veg`, given its ceiling `top` and the rung it is on.
#
# The grass span is everything above bare_threshold (below that the cell is
# dirt, which is rung -1 in spirit and handled by the caller), cut into `top+1`
# equal bands. So a cell generated with tall grass passes through more visible
# lengths on its way out than one generated short, which is what makes the loss
# read as continuous on the cells that have the most to lose.
#
# `grass_step_hysteresis` is applied against the DIRECTION of travel: the value
# must clear a boundary by that much to grow, and fall that far below it to
# wear. A cell parked on a boundary therefore holds its current length instead
# of re-cutting its tile on every sweep.
func _rung_for(veg: float, top: int, current: int) -> int:
	if top <= 0:
		return 0
	var span: float = 1.0 - bare_threshold
	if span <= 0.0:
		return top
	var bands: int = top + 1
	var t: float = (veg - bare_threshold) / span
	var h: float = grass_step_hysteresis / span
	var up: int = clampi(int(floor((t - h) * float(bands))), 0, top)
	if up > current:
		return up
	var down: int = clampi(int(floor((t + h) * float(bands))), 0, top)
	if down < current:
		return down
	return clampi(current, 0, top)


# Ladders for the atlas this layer paints from. Rebuilt only when handed a
# different TileSet, so the atlas scan happens once per map rather than per cell.
func _ladder_for(layer: TileMapLayer) -> GrassLadder:
	var ts: TileSet = layer.tile_set if layer != null else null
	if _ladder == null or ts != _ladder_tile_set:
		_ladder_tile_set = ts
		_ladder = GrassLadder.new(ts, SOURCE_GRASS)
	return _ladder


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
	_order.clear()
	_cursor = 0
	_deficit = 0.0
	_bare = 0
	# The clocks are NOT reset: they are monotonic, and every record that could
	# reference an old reading has just been cleared. Zeroing them would be
	# harmless today and a retroactive-healing bug the day something survives a
	# wipe.
