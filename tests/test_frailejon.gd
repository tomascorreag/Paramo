extends GutTest

# ===========================================================================
# Frailejon.set_growth_stage — clamping logic
# ===========================================================================
# Note: Frailejon needs a Sprite2D child for set_growth_stage to set frame.
# We test clamping on the `growth_stage` var. The _sprite null-check in
# set_growth_stage guards against missing children.

var plant: Frailejon


func before_each() -> void:
	plant = Frailejon.new()
	# Don't add to tree — avoids _ready needing Sprite2D child and TimeManager.
	# set_growth_stage checks `if _sprite:` so it won't crash.


func after_each() -> void:
	plant.free()


func test_set_growth_stage_zero() -> void:
	plant.set_growth_stage(0)
	assert_eq(plant.growth_stage, 0)


func test_set_growth_stage_max() -> void:
	plant.set_growth_stage(Frailejon.MAX_GROWTH_STAGE)
	assert_eq(plant.growth_stage, Frailejon.MAX_GROWTH_STAGE)


func test_set_growth_stage_clamps_above() -> void:
	plant.set_growth_stage(Frailejon.MAX_GROWTH_STAGE + 5)
	assert_eq(plant.growth_stage, Frailejon.MAX_GROWTH_STAGE)


func test_set_growth_stage_clamps_below() -> void:
	plant.set_growth_stage(-1)
	assert_eq(plant.growth_stage, 0)


func test_max_growth_stage_is_3() -> void:
	assert_eq(Frailejon.MAX_GROWTH_STAGE, 3)


# ===========================================================================
# Hour boundary formula: int(time_of_day * 24.0) % 24
# ===========================================================================
# This formula is used in Frailejon._process to detect hour changes.
# Testing the math directly since _process depends on TimeManager autoload.

func _hour_from_time(t: float) -> int:
	return int(t * 24.0) % 24


func test_hour_at_midnight() -> void:
	assert_eq(_hour_from_time(0.0), 0)


func test_hour_at_noon() -> void:
	assert_eq(_hour_from_time(0.5), 12)


func test_hour_at_end_of_day() -> void:
	assert_eq(_hour_from_time(0.999), 23)


func test_hour_at_6am() -> void:
	assert_eq(_hour_from_time(0.25), 6)


func test_hour_at_6pm() -> void:
	assert_eq(_hour_from_time(0.75), 18)
