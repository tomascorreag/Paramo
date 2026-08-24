extends GutTest

# Guards the season → weather coupling. The swap plumbing
# (RunController._on_season_started → DayNightSceneController.set_profile) has
# existed since the spine, but both season .tres shipped with
# day_night_profile = null for months — set_profile(null) returns early, so
# weather was silently season-blind. These assertions make that regression loud.

var dry: SeasonProfile = preload("res://resources/seasons/dry.tres")
var wet: SeasonProfile = preload("res://resources/seasons/wet.tres")


func test_both_seasons_carry_a_day_night_profile() -> void:
	assert_not_null(dry.day_night_profile,
		"dry season must swap in a weather profile — null means season-blind weather")
	assert_not_null(wet.day_night_profile,
		"wet season must swap in a weather profile — null means season-blind weather")


func test_dry_season_rains_less_often_than_wet() -> void:
	assert_lt(dry.day_night_profile.rain_base_probability,
		wet.day_night_profile.rain_base_probability,
		"the whole point of the split: dry seasons must roll rain more rarely")


func test_dry_rain_is_weaker_when_it_does_come() -> void:
	assert_lte(dry.day_night_profile.rain_target_intensity_max,
		wet.day_night_profile.rain_target_intensity_max)


func test_profiles_keep_the_full_visual_set() -> void:
	# set_profile swaps EVERYTHING, so a rain-only profile would null out the
	# ambient grade at the first season boundary. The variants must stay
	# complete duplicates until Phase 1.5 authors distinct looks.
	for profile: DayNightProfile in [dry.day_night_profile, wet.day_night_profile]:
		assert_not_null(profile.ambient_gradient)
		assert_not_null(profile.rain_probability_curve)
		assert_not_null(profile.wind_intensity_curve)
