class_name SeasonProfile
extends Resource

## Data definition for one season in the run cycle (Dry / Wet).
##
## Resources ≈ Unity ScriptableObjects: this is pure config, no behaviour.
## SeasonManager holds an ordered Array[SeasonProfile] and steps through it,
## applying the active profile's parameters each time a season starts.
##
## Lean by design — only the fields the current slice step consumes live here.
## Laguna-drain and fire-interval fields are added when those systems land, so
## the .tres files don't accumulate speculative, unwired knobs.

## Stable identifier for dispatch / save data. Use &"dry", &"wet".
@export var id: StringName = &""

## Long name, English only. NOT player-facing today — its one consumer is a debug
## print in run_controller.gd. Localize it (and add keys to
## assets/translations/paramo.csv) if it ever reaches the HUD.
@export var display_name: String = ""

## Translation key for the SHORT name the journal's calendar prints down its
## gutter (&"SEASON_DRY" / &"SEASON_WET" — "dry"/"seca", "wet"/"lluvia").
## Separate from display_name because that gutter is 50 texels wide: "Dry Season"
## does not fit in any language. Empty falls back to `id`, untranslated.
@export var short_name_key: StringName = &""

## True for Verano (dry). Fire, water-generation, and tourist systems key off
## this rather than off id string-compares.
@export var is_dry: bool = true

## Whether wildfire may ignite during this season. FireManager gating hooks
## here in a later step; unused by the spine.
@export var allows_fire: bool = true

## Day/night look swapped in at the season boundary (golden haze vs gray-blue
## fog). Optional — null leaves the current profile untouched.
@export var day_night_profile: DayNightProfile = null

## Where the global dryness scalar settles during this season under clear sky
## (ClimateController pulls dryness toward this; rain pushes it toward 0).
## Fire ignition scales with dryness, so this is "how flammable a rainless
## stretch of this season makes the mountain".
@export_range(0.0, 1.0) var dryness_equilibrium: float = 0.5
