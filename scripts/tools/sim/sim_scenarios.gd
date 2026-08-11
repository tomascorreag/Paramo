class_name SimScenarios
extends RefCounted

## The balance simulator's scenario table — the analogue of
## verify_terrain_invariants.gd's SCENARIOS, and just as edit-friendly. A
## scenario is {terrain: {TerrainGenerationParams field: value},
## balance: {NodeName: {property: value}}, bot: {BotPolicy field: value}}.
## Balance targets are the per-run system nodes by name (SimWeatherHost,
## WaterCycle, ClimateController, RegrowthManager, VisitorFlow, UnlockState)
## or the autoloads (SeasonManager, FireManager) — autoload overrides are
## restored after each run.
##
## Add a scenario per balance question: "what if regrowth were faster",
## "what if the climate ramp were steep", etc. Sweeps compare scenarios'
## summary blocks side by side.

const SCENARIOS: Dictionary = {
	"defaults": {},
	# No player intervention at all — the baseline every bot policy is
	# measured against.
	"no_bot": {"bot": {"enabled": false}},
	# An imperfect player: slow to react, 20% suboptimal choices.
	"sloppy_bot": {"bot": {"reaction_delay_seconds": 10.0, "decision_noise": 0.2}},
	# The climate ramp switched off — the control group for "does the gentle
	# per-season drying actually change outcomes".
	"no_climate_ramp": {
		"balance": {
			"ClimateController": {
				"climate_rain_decay_per_season": 0.0,
				"climate_dryness_drift_per_season": 0.0,
			},
		},
	},
	# A short 4-day year (1 day per season) — fast iteration + test fixture.
	"short_run": {
		"balance": {"SeasonManager": {"days_per_year": 4}},
	},
	# Tourism with no ground cost: visitors still arrive, pay and walk, but
	# their feet take nothing. The A/B partner for "defaults" — run both over
	# the same --seed0 range and the difference IS trampling, with fire, weather
	# and the bot held identical by the shared seeds.
	"no_trample": {
		"balance": {"RegrowthManager": {"trample_per_step": 0.0}},
	},
	# The crowd wears the ground but the player does not — isolates the bot's
	# own tracks, which are concentrated (it walks to fires, repeatedly, from
	# wherever it happens to be) rather than spread like tourist routes.
	"no_player_trample": {
		"balance": {"RegrowthManager": {"player_trample_fraction": 0.0}},
	},
	# Nobody comes at all: the ceiling on what tourism costs the mountain, and
	# the floor on what it pays. Between this and no_trample sits the crowd's
	# economic value; between no_trample and defaults sits its ecological price.
	"no_visitors": {
		"balance": {"VisitorSpawner": {"enabled": false}},
	},
	# Visitors walk the pathfinder's optimal line instead of detouring through
	# waypoints. The A/B that prices the ROUTE NOISE: it is the most expensive
	# visitor feature per body (every waypoint is another A*, on spawn and again
	# on every re-route) and its payoff is entirely visual, so the wall-clock
	# delta against "defaults" is the number to weigh it against. It also removes
	# the waypoint stops, hence every regroup barrier.
	"no_wander": {
		"balance": {"VisitorSpawner": {"wander_chance": 0.0}},
	},
	# Parties still detour, but members no longer wait for each other at the
	# waypoints. Isolates the regrouping barrier from the noise it rides on.
	"no_regroup": {
		"balance": {"VisitorSpawner": {"regroup_at_waypoints": false}},
	},
	# Faster regrowth: does halving the char recovery time restore tourism
	# quickly enough to matter?
	"fast_regrowth": {
		"balance": {
			"RegrowthManager": {
				"base_recovery_per_day": 0.3,
				"rain_recovery_bonus": 0.7,
			},
		},
	},
}


static func get_scenario(scenario_name: String) -> Dictionary:
	if not SCENARIOS.has(scenario_name):
		# Still returns a usable defaults-shaped spec, but never silently: a
		# typo'd --scenario would otherwise run "defaults" labeled by the typo.
		push_error("SimScenarios: unknown scenario '%s'. Known: %s"
				% [scenario_name, SCENARIOS.keys()])
	var spec: Dictionary = SCENARIOS.get(scenario_name, {}).duplicate(true)
	spec["name"] = scenario_name
	return spec
