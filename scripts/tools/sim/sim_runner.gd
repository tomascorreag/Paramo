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
## CSV columns (run row, in RUN_COLUMNS order):
##   scenario          scenario name
##   run_seed          the run's master seed (terrain seed; others derive)
##   days              in-game days completed when the run ended
##   tokens_final      ledger tokens at end
##   water_final       ledger water at end
##   tokens_visitors   total tokens earned from visitors
##   water_rain        total water earned from rainfall
##   water_fog         total water earned from fog capture
##   water_douse       net water spent dousing (negative or 0)
##   fires_ignited     exact (FireManager.stats_ignitions diff)
##   fires_burned_out  exact: tile_burned emissions (charred cells created)
##   fires_doused_rain exact (FireManager.stats_rain_extinguished diff)
##   fires_active_end  burning cells left when the run ended
##   peak_fires        max concurrent burning cells observed
##   charred_end       charred (unregrown) cells at end
##   charred_cell_days sum of charred count sampled at each day boundary
##   grass_frac_end    grass cells / initial grass cells at end
##   grass_frac_min    minimum of that fraction over the run (sampled per tick)
##   appeal_min        minimum visitor-appeal factor (day-boundary samples)
##   rain_frac         fraction of ticks with rain intensity > 0.1
##   dryness_mean      mean dryness (per-tick average)
##   unlock_day_bridge/_ladder/_frailejon  day the bot bought it (-1 = never)
##   bot_douses        cells the bot doused (player-verb extinguishes)
##   bot_travel_seconds  real seconds the bot spent walking
##
## Day row (per --per-day, DAY_COLUMNS order): scenario, run_seed, day,
## season_index, tokens, water, avg_rain, dryness, charred, grass_frac,
## appeal, fires_active, ignitions, burned_out.

const DT: float = 0.25          # real seconds per tick == fire's ignition tick
const TICKS_PER_DAY: int = 960  # 240 s/game-day at time_scale 1 / DT

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
		params.set(k, terrain_overrides[k])
	params.seed = run_seed
	# The Pathfinder is reused across runs, and traversal edges + cell
	# penalties deliberately SURVIVE rebuild (they track live structures in
	# the game) — scrub last run's ladders/frailejones or they leak.
	world.pathfinder.clear_all_cell_penalties()
	world.pathfinder._traversal_edges.clear()
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

	var host: Node = systems["SimWeatherHost"]
	var climate: Node = systems["ClimateController"]
	var regrowth: Node = systems["RegrowthManager"]

	# --- seeding + fire wiring ----------------------------------------------
	(host.get(&"rng") as RandomNumberGenerator).seed = run_seed ^ SEED_XOR_WEATHER
	(FireManager.get(&"rng") as RandomNumberGenerator).seed = run_seed ^ SEED_XOR_FIRE
	(regrowth.get(&"rng") as RandomNumberGenerator).seed = run_seed ^ SEED_XOR_REGROWTH
	FireManager.spawn_vfx = false
	FireManager.set_process(false)
	TimeManager.set_process(false)
	# A fresh run on the same Pathfinder: wipe fire state explicitly (a mere
	# rebuild deliberately does NOT), and resolve the new grid synchronously —
	# the whole run happens inside one frame, so deferred refreshes would
	# flush only after it ended.
	FireManager._wipe_all_fires()
	if FireManager._pathfinder != world.pathfinder:
		FireManager._attach_to_pathfinder(world.pathfinder)
	FireManager._refresh_grid_and_vfx()
	FireManager._ignition_accum = 0.0
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
		bot.fire_manager = FireManager
		bot.ledger = ResourceLedger
		bot.cell = world.spawn_cell

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

	var max_ticks: int = (SeasonManager.days_per_year + 2) * TICKS_PER_DAY
	while SeasonManager.phase != SeasonManager.Phase.RUN_OVER \
			and ticks_total < max_ticks:
		if SeasonManager.phase == SeasonManager.Phase.PLANNING:
			# Clock is paused, like the game. The bot shops, then the run taps
			# "next season".
			if bot != null:
				bot.on_planning(systems["UnlockState"], TimeManager.day_count)
			SeasonManager.begin_next_season()
			continue

		TimeManager.advance(DT)
		host.call(&"tick", DT)
		systems["WaterCycle"].call(&"tick", DT)
		climate.call(&"tick", DT)
		regrowth.call(&"tick", DT)
		systems["VisitorFlow"].call(&"tick", DT)
		var rain: float = float(host.call(&"get_rain_current_intensity"))
		FireManager.sim_tick(DT, rain)
		if bot != null:
			bot.tick(ticks_total * DT)

		ticks_total += 1
		day_ticks += 1
		day_rain_sum += rain
		if rain > 0.1:
			rain_ticks += 1
		dryness_sum += float(climate.get(&"dryness"))
		var burning: int = FireManager._burning.size()
		peak_fires = maxi(peak_fires, burning)
		var charred: int = int(regrowth.call(&"charred_count"))
		var grass_frac: float = _grass_fraction(initial_grass, burning, charred)
		grass_frac_min = minf(grass_frac_min, grass_frac)

		if TimeManager.day_count != last_day:
			last_day = TimeManager.day_count
			charred_cell_days += charred
			var appeal: float = float(regrowth.call(&"get_appeal_factor"))
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
					"dryness": float(climate.get(&"dryness")),
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

	# --- run row -------------------------------------------------------------
	var charred_end: int = int(regrowth.call(&"charred_count"))
	var burning_end: int = FireManager._burning.size()
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
		"grass_frac_end": _grass_fraction(initial_grass, burning_end, charred_end),
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
	}

	# --- cleanup -------------------------------------------------------------
	FireManager.tile_burned.disconnect(_on_tile_burned)
	FireManager._wipe_all_fires()
	if SeasonManager.phase != SeasonManager.Phase.RUN_OVER:
		push_warning("SimRunner: run hit the tick cap before RUN_OVER")
		SeasonManager.end_run(&"sim_tick_cap")
	for restore in autoload_restore:
		(restore[0] as Node).set(restore[1], restore[2])
	for def in _SYSTEM_DEFS:
		(systems[def[0]] as Node).free()

	return {"run": run_row, "days": days}


func _on_tile_burned(_cell: Vector2i, _coord: Vector2i,
		_layer: TileMapLayer) -> void:
	_burned_out_count += 1


# Grass is exact bookkeeping, no census needed: a burning cell was swapped to
# dirt at ignition, a charred cell stays dirt until regrowth removes it from
# the charred set (regrowth repaints the grass), and nothing else creates or
# destroys grass.
static func _grass_fraction(initial: int, burning: int, charred: int) -> float:
	if initial <= 0:
		return 1.0
	return float(initial - burning - charred) / float(initial)
