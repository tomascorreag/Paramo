class_name SimRunner
extends Node

## Drives one complete headless run of the game's simulation stack: the real
## TimeManager/SeasonManager/FireManager/ResourceLedger autoloads plus fresh
## scene-scoped system nodes (weather host, water, climate, regrowth,
## visitors, unlocks) created as children per run. Shared by balance_sim.gd
## (the CLI) and tests/test_sim_determinism.gd — the run loop exists exactly
## once.
##
## The loop calls the SAME functions a game frame calls (advance/tick/
## sim_tick), at a fixed DT, in a fixed order, with per-subsystem seeded RNG
## streams — so a run is a pure function of (run_seed, scenario).
##
## Ecosystem health is a CONTINUUM (user decision): there is no loss rule
## here or in the game. Rows report trajectories and percentages.
##
## Player-model limitations (policy-level, deliberate — factor into any CSV
## reading): the bot shops only at season boundaries (a player can buy from
## the journal any time); walks are commit-and-teleport (no mid-walk
## re-planning when a nearer fire ignites or the target burns out, no
## cancel); remove verbs are never used; boundary shopping takes zero game
## time, and unlike the old planning phase the clock no longer stops for it —
## which costs nothing, since it resolves inside one tick; bridge
## placement is not modeled (unlock purchase only); the stand cell beside a
## fire is picked by Manhattan distance then ONE A* (the game's action layer
## A*s every reachable stand and takes the shortest actual path, so around
## cliffs/water the bot over-pays travel time); the game's boot-time rain
## roll has no analogue here — correct, since the title intro resets weather
## dry before gameplay, which is the state the sim starts from.
##
## CSV columns (run row, in RUN_COLUMNS order):
##   scenario          scenario name
##   run_seed          the run's master seed (terrain seed; others derive)
##   days              in-game days completed when the run ended
##   tokens_final      ledger tokens at end
##   water_final       ledger water at end
##   tokens_visitors   total tokens earned from visitors
##   visitors_walked   bodies actually put on the mountain over the run. NOT the
##                     same as the arrivals VisitorFlow banked: opening hours
##                     and the concurrency cap hold some back. The gap between
##                     this and tokens_visitors is the crowd the economy was
##                     paid for but the ground never carried.
##   water_rain        total water earned from rainfall
##   water_fog         total water earned from fog capture
##   water_douse       net water spent dousing (negative or 0)
##   fires_ignited     exact (FireManager.stats_ignitions diff)
##   fires_burned_out  exact: tile_burned emissions (charred cells created)
##   fires_doused_rain exact (FireManager.stats_rain_extinguished diff)
##   fires_active_end  burning cells left when the run ended
##   peak_fires        max concurrent burning cells observed
##   charred_end       BARE (fully stripped, unregrown) cells at end. Fire is
##                     the only thing that bares a cell in a sim run, so this
##                     still means "charred" here; in the GAME trampling can
##                     bare one too.
##   charred_cell_days sum of that bare count sampled at each day boundary
##   grass_frac_end    grass remaining / initial grass cells at end. CONTINUOUS
##                     since vegetation became a per-cell amount: a half-worn
##                     cell counts as half a cell of loss, not zero or one.
##   grass_frac_min    minimum of that fraction over the run (sampled per tick)
##   appeal_min        minimum visitor-appeal factor (day-boundary samples)
##   rain_frac         fraction of ticks with rain intensity > 0.1. Sampled
##                     POST-tick; fire consumes the PRE-tick value (frame
##                     order) — a one-tick skew, negligible at DT 0.25.
##   dryness_mean      mean dryness (per-tick average)
##   unlock_day_bridge/_ladder/_frailejon  day the bot bought it (-1 = never)
##   bot_douses        cells the bot doused (player-verb extinguishes)
##   bot_travel_seconds  real seconds the bot spent walking
##
## Day row (per --per-day, DAY_COLUMNS order): scenario, run_seed, day,
## season_index, tokens, water, avg_rain, dryness, charred, grass_frac,
## appeal, fires_active, ignitions, burned_out.

const DT: float = 0.25  # real seconds per tick == fire's ignition tick

# Independent derived streams per subsystem (xor pattern from
# verify_terrain_invariants.gd; OBJECT xor lives in SimWorld).
const SEED_XOR_WEATHER: int = 0x57EA7E12
const SEED_XOR_FIRE: int = 0xF1FE0001
const SEED_XOR_REGROWTH: int = 0x0E600F02
const SEED_XOR_BOT: int = 0xB07B07B0

const RUN_COLUMNS: PackedStringArray = [
	"scenario", "run_seed", "days", "tokens_final", "water_final",
	"tokens_visitors", "water_rain", "water_fog", "water_douse",
	"fires_ignited", "fires_burned_out", "fires_doused_rain",
	"fires_active_end", "peak_fires",
	"charred_end", "charred_cell_days", "grass_frac_end", "grass_frac_min",
	"appeal_min", "rain_frac", "dryness_mean",
	"unlock_day_bridge", "unlock_day_ladder", "unlock_day_frailejon",
	"bot_douses", "bot_travel_seconds",
	"placements_ladder", "placements_frailejon",
	"visitors_walked",
]

const DAY_COLUMNS: PackedStringArray = [
	"scenario", "run_seed", "day", "season_index", "tokens", "water",
	"avg_rain", "dryness", "charred", "grass_frac", "appeal",
	"fires_active", "ignitions", "burned_out",
]

# Scene-scoped systems, in gameplay_base.tscn's child order (construction
# order = signal connection order = deterministic dispatch). Names are the
# targets for scenario balance overrides.
const _SYSTEM_DEFS: Array = [
	["SimWeatherHost", "res://scripts/tools/sim/sim_weather_host.gd"],
	["WaterCycle", "res://scripts/systems/water_cycle.gd"],
	["ClimateController", "res://scripts/systems/climate_controller.gd"],
	["RegrowthManager", "res://scripts/systems/regrowth_manager.gd"],
	["VisitorFlow", "res://scripts/systems/visitor_flow.gd"],
	# AFTER VisitorFlow: it connects to that node's visitors_arrived by group
	# lookup in _ready, so the flow has to exist first.
	["VisitorSpawner", "res://scripts/systems/visitor_spawner.gd"],
	["UnlockState", "res://scripts/systems/unlock_state.gd"],
]

## The headless world to run against. Assigned by the owner; reused across
## runs (regenerate() per run).
var world: SimWorld = null

var _burned_out_count: int = 0


## Run one full game (start_run -> RUN_OVER) at `run_seed` under `scenario`
## ({terrain: {param: v}, balance: {NodeName: {prop: v}}, bot: {...}}).
## Returns {"run": Dictionary, "days": Array}. Deterministic per
## (run_seed, scenario) — timing lives in the caller, not the row.
func run_one(run_seed: int, scenario: Dictionary = {},
		collect_days: bool = false) -> Dictionary:
	assert(world != null, "SimRunner.world must be assigned")
	var scenario_name: String = String(scenario.get("name", "defaults"))

	# --- world ---------------------------------------------------------------
	var params := TerrainGenerationParams.new()
	var terrain_overrides: Dictionary = scenario.get("terrain", {})
	for k: String in terrain_overrides:
		if not (k in params):
			push_warning("SimRunner: unknown terrain param '%s' (typo?)" % k)
			continue
		params.set(k, terrain_overrides[k])
	params.seed = run_seed
	# The Pathfinder is reused across runs, and traversal edges + cell
	# penalties deliberately SURVIVE rebuild (they track live structures in
	# the game) — scrub last run's ladders or they leak.
	world.pathfinder.clear_all_cell_penalties()
	world.pathfinder.clear_all_traversal_edges()
	world.regenerate(params)
	var initial_grass: int = int(world.cell_census().get(0, 0))

	# --- systems -------------------------------------------------------------
	var systems: Dictionary = {}
	for def in _SYSTEM_DEFS:
		var node := Node.new()
		node.set_script(load(def[1]))
		node.name = def[0]
		add_child(node)
		node.set_process(false)
		systems[def[0]] = node

	var balance: Dictionary = scenario.get("balance", {})
	var autoload_restore: Array = []  # [node, prop, old_value]
	for target_name: String in balance:
		var target: Node = systems.get(target_name)
		var is_autoload: bool = target == null
		if is_autoload:
			target = get_node_or_null(NodePath("/root/" + target_name))
		if target == null:
			push_warning("SimRunner: no balance target '%s'" % target_name)
			continue
		for prop: String in balance[target_name]:
			if is_autoload:
				autoload_restore.append([target, prop, target.get(prop)])
			target.set(prop, balance[target_name][prop])

	# Typed references for the per-tick loop below: ~8 dynamic call()/get()
	# lookups per tick x ~23k ticks/run is real dispatch cost, and this script
	# is load()ed at runtime so compile-time class names are legal here.
	var host: SimWeatherHost = systems["SimWeatherHost"]
	var water: WaterCycle = systems["WaterCycle"]
	var climate: ClimateController = systems["ClimateController"]
	var regrowth: RegrowthManager = systems["RegrowthManager"]
	var visitors: VisitorFlow = systems["VisitorFlow"]
	var spawner: VisitorSpawner = systems["VisitorSpawner"]
	var unlocks: UnlockState = systems["UnlockState"]

	# --- seeding + fire wiring ----------------------------------------------
	host.rng.seed = run_seed ^ SEED_XOR_WEATHER
	FireManager.rng.seed = run_seed ^ SEED_XOR_FIRE
	regrowth.rng.seed = run_seed ^ SEED_XOR_REGROWTH
	# The crowd walks the real world: bodies parented into it, the derived entry
	# anchored on the player's spawn (SimBot is RefCounted and cannot be found by
	# group), and its own derived stream via set_seed. Without this the run has
	# no trampling, and trampling is now part of what the run measures.
	spawner.set_seed(run_seed)
	spawner.entity_parent = world.object_parent
	spawner.anchor_cell_override = world.spawn_cell
	FireManager.spawn_vfx = false
	# Frozen autoload _process for the run's duration — restored in cleanup so
	# a GUT suite (which shares the autoloads with every other test) doesn't
	# inherit a dead clock.
	var proc_restore: Array = [
		[FireManager, FireManager.is_processing()],
		[TimeManager, TimeManager.is_processing()],
	]
	FireManager.set_process(false)
	TimeManager.set_process(false)
	# A fresh run on the same Pathfinder: wipe fire state explicitly (a mere
	# rebuild deliberately does NOT), and resolve the new grid synchronously —
	# the whole run happens inside one frame, so deferred refreshes would
	# flush only after it ended.
	FireManager.reset_to_world(world.pathfinder)
	var base_ignitions: int = FireManager.stats_ignitions
	var base_rain_ext: int = FireManager.stats_rain_extinguished

	_burned_out_count = 0
	FireManager.tile_burned.connect(_on_tile_burned)

	# --- bot -----------------------------------------------------------------
	# The scripted player. Default ON with the default policy — a sweep about
	# no-intervention dynamics opts out via bot: {"enabled": false}.
	var bot_cfg: Dictionary = scenario.get("bot", {})
	var bot: SimBot = null
	if bool(bot_cfg.get("enabled", true)):
		bot = SimBot.new()
		bot.policy = BotPolicy.new()
		for prop: String in bot_cfg:
			if prop != "enabled":
				bot.policy.set(prop, bot_cfg[prop])
		bot.rng.seed = run_seed ^ SEED_XOR_BOT
		bot.pathfinder = world.pathfinder
		bot.object_parent = world.object_parent
		bot.fire_manager = FireManager
		bot.ledger = ResourceLedger
		bot.regrowth = regrowth
		bot.cell = world.spawn_cell
		if bot.cell.x < 0:
			# _find_starting_cell can legitimately fail; an inert bot would
			# silently read as a no-bot baseline in the CSV.
			push_warning("SimRunner: seed %d has no spawn cell — bot is inert"
					% run_seed)

	# The bot shops at each SEASON BOUNDARY. That used to be the PLANNING phase
	# (removed 2026-08-09 — nothing in the game left it, so the run deadlocked
	# there); seasons now roll straight over, and season_ended is the same
	# instant. The handler only RAISES a flag: the shopping itself runs at the
	# top of the loop below, once SeasonManager has finished transitioning, so
	# the bot never mutates unlocks/occupants mid-signal. Connected per run and
	# disconnected after — SeasonManager is an autoload shared by every run in
	# the process, so a leaked connection would have run N bots on run N+1.
	var boundary_pending: Array[bool] = [false]
	var on_season_ended: Callable = func(_i: int, _p: SeasonProfile) -> void:
		boundary_pending[0] = true
	SeasonManager.season_ended.connect(on_season_ended)

	# --- the run -------------------------------------------------------------
	SeasonManager.start_run()

	var days: Array = []
	var last_day: int = 0
	var ticks_total: int = 0
	var rain_ticks: int = 0
	var dryness_sum: float = 0.0
	var peak_fires: int = 0
	var charred_cell_days: int = 0
	var appeal_min: float = 1.0
	var grass_frac_min: float = 1.0
	# Per-day accumulators.
	var day_rain_sum: float = 0.0
	var day_ticks: int = 0
	var day_ignitions_prev: int = base_ignitions
	var day_burned_prev: int = 0

	# Derived, not a constant: TimeManager is a legal balance-override target,
	# so a scenario retuning seconds_per_game_day or time_scale must move the
	# tick cap with it or the cap silently lies.
	var ticks_per_day: int = maxi(1, int(round(TimeManager.seconds_per_game_day
			/ (DT * maxf(TimeManager.time_scale, 0.0001)))))
	var max_ticks: int = (SeasonManager.days_per_year + 2) * ticks_per_day
	while SeasonManager.phase != SeasonManager.Phase.RUN_OVER \
			and ticks_total < max_ticks:
		if boundary_pending[0]:
			boundary_pending[0] = false
			if bot != null:
				bot.on_season_boundary(unlocks, TimeManager.day_count)

		TimeManager.advance(DT)
		# Frame-order fidelity: autoloads process before scene nodes, so in
		# the game FireManager runs BEFORE the weather controller evolves —
		# fire reads the PREVIOUS frame's rain. Read the host before ticking
		# it to reproduce that exactly.
		FireManager.sim_tick(DT, host.get_rain_current_intensity())
		host.tick(DT)
		water.tick(DT)
		climate.tick(DT)
		regrowth.tick(DT)
		visitors.tick(DT)
		# After VisitorFlow, matching scene order: the flow banks the day's
		# arrivals and emits, and the spawner lets them in from the same tick.
		spawner.tick(DT)
		var rain: float = host.get_rain_current_intensity()
		if bot != null:
			bot.tick(ticks_total * DT)

		ticks_total += 1
		day_ticks += 1
		day_rain_sum += rain
		if rain > 0.1:
			rain_ticks += 1
		dryness_sum += climate.dryness
		var burning: int = FireManager.burning_count()
		peak_fires = maxi(peak_fires, burning)
		var charred: int = regrowth.bare_count()
		var grass_frac: float = _grass_fraction(
				initial_grass, burning, regrowth.vegetation_deficit())
		grass_frac_min = minf(grass_frac_min, grass_frac)

		if TimeManager.day_count != last_day:
			last_day = TimeManager.day_count
			# The whole run happens inside one frame, so queue_free (burnt
			# frailejones, from FireManager._complete_burn) never actually
			# lands — flush the dead here so their occupant slots vacate
			# (frailejon._exit_tree clears the grid claim on free).
			_flush_dead_objects()
			charred_cell_days += charred
			var appeal: float = regrowth.get_appeal_factor()
			appeal_min = minf(appeal_min, appeal)
			if collect_days:
				days.append({
					"scenario": scenario_name,
					"run_seed": run_seed,
					"day": last_day,
					"season_index": SeasonManager.season_index,
					"tokens": ResourceLedger.get_amount(&"tokens"),
					"water": ResourceLedger.get_amount(&"water"),
					"avg_rain": day_rain_sum / maxf(day_ticks, 1.0),
					"dryness": climate.dryness,
					"charred": charred,
					"grass_frac": grass_frac,
					"appeal": appeal,
					"fires_active": burning,
					"ignitions": FireManager.stats_ignitions - day_ignitions_prev,
					"burned_out": _burned_out_count - day_burned_prev,
				})
			day_rain_sum = 0.0
			day_ticks = 0
			day_ignitions_prev = FireManager.stats_ignitions
			day_burned_prev = _burned_out_count

	SeasonManager.season_ended.disconnect(on_season_ended)

	# --- run row -------------------------------------------------------------
	var charred_end: int = regrowth.bare_count()
	var burning_end: int = FireManager.burning_count()
	var run_row: Dictionary = {
		"scenario": scenario_name,
		"run_seed": run_seed,
		"days": TimeManager.day_count,
		"tokens_final": ResourceLedger.get_amount(&"tokens"),
		"water_final": ResourceLedger.get_amount(&"water"),
		"tokens_visitors": ResourceLedger.source_total(&"tokens", &"visitors"),
		"water_rain": ResourceLedger.source_total(&"water", &"rainfall"),
		"water_fog": ResourceLedger.source_total(&"water", &"fog_capture"),
		"water_douse": ResourceLedger.source_total(&"water", &"extinguish_fire"),
		"fires_ignited": FireManager.stats_ignitions - base_ignitions,
		"fires_burned_out": _burned_out_count,
		"fires_doused_rain": FireManager.stats_rain_extinguished - base_rain_ext,
		"fires_active_end": burning_end,
		"peak_fires": peak_fires,
		"charred_end": charred_end,
		"charred_cell_days": charred_cell_days,
		"grass_frac_end": _grass_fraction(
				initial_grass, burning_end, regrowth.vegetation_deficit()),
		"grass_frac_min": grass_frac_min,
		"appeal_min": appeal_min,
		"rain_frac": float(rain_ticks) / maxf(ticks_total, 1.0),
		"dryness_mean": dryness_sum / maxf(ticks_total, 1.0),
		"unlock_day_bridge":
				int(bot.unlock_days.get(&"bridge", -1)) if bot != null else -1,
		"unlock_day_ladder":
				int(bot.unlock_days.get(&"ladder", -1)) if bot != null else -1,
		"unlock_day_frailejon":
				int(bot.unlock_days.get(&"frailejon", -1)) if bot != null else -1,
		"bot_douses": bot.douses if bot != null else 0,
		"bot_travel_seconds":
				bot.travel_seconds if bot != null else 0.0,
		"placements_ladder":
				int(bot.placements.get(&"ladder", 0)) if bot != null else 0,
		"placements_frailejon":
				int(bot.placements.get(&"frailejon", 0)) if bot != null else 0,
		"visitors_walked": spawner.stats_spawned,
	}

	# --- cleanup -------------------------------------------------------------
	FireManager.tile_burned.disconnect(_on_tile_burned)
	FireManager.detach_world()
	# Bot-planted frailejones aren't in the procedural_object group (player
	# plants never are), so the next regenerate's sweep won't free them —
	# clear them here, along with anything still queued for deletion.
	for child: Node in world.object_parent.get_children():
		if child.is_queued_for_deletion() \
				or not child.is_in_group(&"procedural_object"):
			child.free()
	if SeasonManager.phase != SeasonManager.Phase.RUN_OVER:
		push_warning("SimRunner: run hit the tick cap before RUN_OVER")
		SeasonManager.end_run(&"sim_tick_cap")
	FireManager.spawn_vfx = true
	for entry in proc_restore:
		(entry[0] as Node).set_process(entry[1])
	for restore in autoload_restore:
		(restore[0] as Node).set(restore[1], restore[2])
	for def in _SYSTEM_DEFS:
		(systems[def[0]] as Node).free()

	return {"run": run_row, "days": days}


func _on_tile_burned(_cell: Vector2i, _coord: Vector2i,
		_layer: TileMapLayer) -> void:
	_burned_out_count += 1


func _flush_dead_objects() -> void:
	for child: Node in world.object_parent.get_children():
		if child.is_queued_for_deletion():
			child.free()


# Grass is exact bookkeeping, no census needed: a burning cell was swapped to
# dirt at ignition, and every other way a cell loses grass goes through
# RegrowthManager's ledger, whose deficit is grass-cells-worth missing.
#
# `deficit` is a FLOAT because vegetation is continuous now — a cell half worn
# away counts half. In a sim run it is always whole numbers, since fire is the
# only damage source here (visitor BODIES, the thing that tramples, are a scene
# node the simulator never constructs) — but the column has to carry the
# fraction for the game, where it does not stay whole.
static func _grass_fraction(initial: int, burning: int, deficit: float) -> float:
	if initial <= 0:
		return 1.0
	return (float(initial - burning) - deficit) / float(initial)
