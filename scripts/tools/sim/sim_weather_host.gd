class_name SimWeatherHost
extends Node

## The balance simulator's stand-in for DayNightSceneController: joins the
## same group and exposes exactly the polled surface every consumer uses
## (get_rain_current_intensity, set_rain_probability_scale, set_profile), but
## is backed by a bare WeatherModel — no shaders, no RainLayer, no grading.
## Weather in the sim is therefore the SAME state machine the game runs, at
## the same roll cadence (period_changed), minus the visuals.
##
## Wiring mirrors the game: season_started -> set_profile(day_night_profile)
## (RunController's one coupling), period_changed -> roll. The sim loop calls
## tick(delta) explicitly; _process stays disabled.

var model: WeatherModel = WeatherModel.new()
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var profile: DayNightProfile = null
var rain_probability_scale: float = 1.0


func _ready() -> void:
	add_to_group(&"day_night_controller")
	TimeManager.period_changed.connect(_on_period_changed)
	SeasonManager.season_started.connect(_on_season_started)


func set_profile(new_profile: DayNightProfile) -> void:
	if new_profile != null:
		profile = new_profile


func set_rain_probability_scale(scale: float) -> void:
	rain_probability_scale = maxf(0.0, scale)


func get_rain_current_intensity() -> float:
	return model.current


## One weather step. Same gates as the game controller's _process: pause
## freezes both clocks; a frozen game clock (seconds_per_game_day <= 0)
## freezes only the game-time half — ramps are REAL-time and keep moving,
## exactly as in the game controller. Diverging here was a measured drift.
func tick(delta: float) -> void:
	if profile == null:
		return
	if TimeManager.paused:
		return
	var game_day_delta: float = 0.0
	if TimeManager.seconds_per_game_day > 0.0:
		game_day_delta = delta * TimeManager.time_scale \
				/ TimeManager.seconds_per_game_day
	model.evolve(profile, delta, game_day_delta)


func _on_period_changed(_new: StringName, _old: StringName) -> void:
	model.roll(profile, TimeManager.time_of_day, rain_probability_scale, rng)


func _on_season_started(_index: int, season: SeasonProfile) -> void:
	if season != null:
		set_profile(season.day_night_profile)
