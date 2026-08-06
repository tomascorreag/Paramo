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
	var spec: Dictionary = SCENARIOS.get(scenario_name, {}).duplicate(true)
	spec["name"] = scenario_name
	return spec
