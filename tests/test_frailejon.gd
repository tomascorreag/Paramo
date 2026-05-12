extends GutTest

# ===========================================================================
# Frailejon.set_growth_stage — clamping logic
# ===========================================================================
# Note: Frailejon needs a Sprite2D child for set_growth_stage to set the
# texture. We test clamping on the `growth_stage` var. The _sprite null-check
# in set_growth_stage guards against missing children. The max-stage bound
# is now data-driven (data.variants.size() - 1), so we install a stub
# PlantObjectData with N variants in before_each.

const _ICON: Texture2D = preload("res://icon.svg")

var plant: Frailejon
var _stub_data: PlantObjectData


func before_each() -> void:
	plant = Frailejon.new()
	# Stub data with 4 entries (matches the production frailejon.tres) so the
	# clamp uses max_stage = 3. Use any Texture2D for the entries — the test
	# only inspects growth_stage clamping, not the rendered pixels.
	_stub_data = PlantObjectData.new()
	_stub_data.variants = [_ICON, _ICON, _ICON, _ICON]
	plant.data = _stub_data
	# Don't add to tree — avoids _ready needing Sprite2D child and TimeManager.
	# set_growth_stage checks `if _sprite:` so it won't crash.


func after_each() -> void:
	plant.free()


func test_set_growth_stage_zero() -> void:
	plant.set_growth_stage(0)
	assert_eq(plant.growth_stage, 0)


func test_set_growth_stage_max() -> void:
	var max_stage: int = _stub_data.variants.size() - 1
	plant.set_growth_stage(max_stage)
	assert_eq(plant.growth_stage, max_stage)


func test_set_growth_stage_clamps_above() -> void:
	var max_stage: int = _stub_data.variants.size() - 1
	plant.set_growth_stage(max_stage + 5)
	assert_eq(plant.growth_stage, max_stage)


func test_set_growth_stage_clamps_below() -> void:
	plant.set_growth_stage(-1)
	assert_eq(plant.growth_stage, 0)


func test_max_stage_follows_variant_count() -> void:
	# Adding/removing a variant in the .tres now changes max growth stage.
	# Verify the data-driven bound by mutating the stub.
	_stub_data.variants = [_ICON, _ICON]
	plant.set_growth_stage(99)
	assert_eq(plant.growth_stage, 1)


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
