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
# Occupant interface follows `data`
# ===========================================================================

func test_occupant_kind_follows_data_id() -> void:
	_stub_data.id = &"chusquea"
	assert_eq(plant.occupant_kind(), &"chusquea")


func test_occupant_kind_without_data_is_frailejon() -> void:
	plant.data = null
	assert_eq(plant.occupant_kind(), &"frailejon")


func test_walk_penalty_and_displaceable_follow_data() -> void:
	_stub_data.walk_penalty = 0.6
	_stub_data.displaceable = true
	assert_eq(plant.walk_penalty(), 0.6)
	assert_true(plant.is_displaceable())
	_stub_data.displaceable = false
	assert_false(plant.is_displaceable())


func test_shadow_is_dropped_when_data_opts_out() -> void:
	var scene: PackedScene = load("res://scenes/tools/frailejon.tscn")
	var real_data: PlantObjectData = load("res://resources/objects/calamagrostis.tres")
	assert_false(real_data.casts_shadow, "calamagrostis.tres must opt out of the shadow")
	var inst: Frailejon = scene.instantiate()
	inst.data = real_data
	add_child_autofree(inst)
	await get_tree().process_frame
	assert_null(inst.get_node_or_null("Shadow"))
	assert_not_null(inst.get_node_or_null("Sprite2D"))


func test_shadow_is_kept_by_default() -> void:
	var scene: PackedScene = load("res://scenes/tools/frailejon.tscn")
	var inst: Frailejon = scene.instantiate()
	# The scene's own data is the frailejón (casts_shadow = true). The shadow
	# is reparented next to the plant, so look for it in the shadow group.
	add_child_autofree(inst)
	await get_tree().process_frame
	await get_tree().process_frame
	assert_gt(get_tree().get_nodes_in_group(&"shadow").size(), 0)


# ===========================================================================
# Wind
# ===========================================================================

func test_ground_cover_carries_the_sway_material_on_both_canvas_items() -> void:
	# A clumped cell draws its frontmost individual through the Sprite2D and
	# the rest through the node's own _draw(), so one material on the sprite
	# alone leaves most of the tufts standing still.
	var inst := _instance_with("res://resources/objects/chusquea.tres")
	await get_tree().process_frame
	var mat: ShaderMaterial = inst.data.wind_material
	assert_not_null(mat, "chusquea.tres must author a sway material")
	assert_eq(inst._sprite.material, mat)
	if not inst._extra_offsets.is_empty():
		assert_eq(inst.material, mat, "the extras' CanvasItem needs it too")


func test_the_material_is_shared_not_duplicated_per_plant() -> void:
	# One resource and one compiled program however many are on the mountain;
	# the per-plant phase comes from the item's own origin in the shader. A
	# duplicate per instance would also be a duplicate shader compile.
	var a := _instance_with("res://resources/objects/chusquea.tres")
	var b := _instance_with("res://resources/objects/chusquea.tres")
	await get_tree().process_frame
	assert_same(a._sprite.material, b._sprite.material)


func test_the_still_species_carry_no_material_at_all() -> void:
	# Not an aesthetic detail: these three are the cheap path. Calamagrostis
	# alone is ~180 plants a map, and dropping its material took the shaded
	# CanvasItem count on level1 from 437 to 202.
	for path in [
		"res://resources/objects/frailejon.tres",
		"res://resources/objects/espeletia_barclayana.tres",
		"res://resources/objects/calamagrostis.tres",
	]:
		var inst := _instance_with(path)
		await get_tree().process_frame
		assert_null(inst.data.wind_material, "%s must not sway" % path)
		assert_null(inst._sprite.material)
		assert_null(inst.material)


func test_exactly_the_authored_species_sway() -> void:
	# Pins the set, so a retune cannot silently enrol or drop a species.
	var swaying: Array[String] = []
	for kind in ObjectPainter.kinds():
		var d := ObjectPainter.data_for(kind) as PlantObjectData
		if d != null and d.wind_material != null:
			swaying.append(String(d.id))
	swaying.sort()
	assert_eq(swaying, [
		"arcytophyllum", "chusquea", "cortaderia",
		"espeletia_hartwegiana", "hypericum",
	])


func test_every_swaying_material_is_registered_for_the_day_wind_curve() -> void:
	# DayNightSceneController drives wind_intensity on the materials in its
	# wind_materials array. A sway material missing from it ignores the day's
	# wind entirely while the ground gusts — which is how this shipped first.
	var scene: PackedScene = load("res://scenes/templates/gameplay_base.tscn")
	var state: SceneState = scene.get_state()
	var registered: Array = []
	for i in state.get_node_count():
		for j in state.get_node_property_count(i):
			if state.get_node_property_name(i, j) == &"wind_materials":
				registered = state.get_node_property_value(i, j)
	assert_gt(registered.size(), 0, "gameplay_base must set wind_materials")
	for kind in ObjectPainter.kinds():
		var d := ObjectPainter.data_for(kind) as PlantObjectData
		if d != null and d.wind_material != null:
			assert_true(registered.has(d.wind_material),
				"%s's sway material is not in wind_materials" % d.id)


func test_burning_takes_the_sway_and_dousing_gives_it_back() -> void:
	var inst := _instance_with("res://resources/objects/chusquea.tres")
	await get_tree().process_frame
	var wind: ShaderMaterial = inst.data.wind_material
	inst.apply_burn_material()
	assert_ne(inst._sprite.material, wind, "a burning plant stops swaying")
	inst.clear_burn_material()
	assert_eq(inst._sprite.material, wind,
		"rain putting the fire out has to give the sway back")


# ===========================================================================
# Trampling walks the plant back down its growth stages
# ===========================================================================

class ClockStub:
	extends Node

	var time_of_day: float = 0.0


func test_damage_under_one_stage_costs_nothing_yet() -> void:
	_stub_data.trample_resistance = 1.0
	plant.set_growth_stage(3)
	plant.trample(0.6)
	assert_eq(plant.growth_stage, 3)
	assert_almost_eq(plant.trample_damage(), 0.6, 1e-5)


func test_filling_the_resistance_drops_one_stage_and_keeps_the_remainder() -> void:
	_stub_data.trample_resistance = 1.0
	plant.set_growth_stage(3)
	plant.trample(0.6)
	plant.trample(0.6)
	assert_eq(plant.growth_stage, 2)
	assert_almost_eq(plant.trample_damage(), 0.2, 1e-5)


func test_one_heavy_step_can_cost_several_stages() -> void:
	# The loop must not stop at one stage: a single call carrying three
	# stages' worth has to spend all of it.
	_stub_data.trample_resistance = 0.5
	plant.set_growth_stage(3)
	plant.trample(1.6)
	assert_eq(plant.growth_stage, 0)
	assert_almost_eq(plant.trample_damage(), 0.1, 1e-5)


func test_trampling_at_stage_zero_frees_the_plant() -> void:
	var doomed := Frailejon.new()
	var d := PlantObjectData.new()
	d.variants = [_ICON, _ICON, _ICON, _ICON]
	d.trample_resistance = 0.5
	doomed.data = d
	doomed.set_growth_stage(0)
	doomed.trample(0.4)
	assert_false(doomed.is_queued_for_deletion())
	doomed.trample(0.4)
	assert_true(doomed.is_queued_for_deletion(),
		"a plant trampled at stage 0 is removed, not left at stage 0 forever")


func test_zero_resistance_is_immune() -> void:
	_stub_data.trample_resistance = 0.0
	plant.set_growth_stage(2)
	plant.trample(99.0)
	assert_eq(plant.growth_stage, 2)
	assert_eq(plant.trample_damage(), 0.0)


func test_damage_heals_on_the_hourly_tick() -> void:
	var clock := ClockStub.new()
	add_child_autofree(clock)
	_stub_data.trample_resistance = 1.0
	_stub_data.growth_chance = 0.0  # isolate healing from the growth roll
	plant.set_growth_stage(3)
	plant._time_manager = clock
	plant._last_hour = 0
	plant.trample(0.9)
	clock.time_of_day = 1.0 / 24.0
	plant._process(0.0)
	assert_almost_eq(plant.trample_damage(),
		0.9 - Frailejon._TRAMPLE_HEAL_PER_DAY / 24.0, 1e-5)


func test_a_mature_damaged_plant_keeps_processing_until_it_has_healed() -> void:
	# The mature plant drops out of _process to keep idle dispatch off the
	# frame; damage has to put it back, or a trampled frailejon would never
	# recover and never resume growing.
	var clock := ClockStub.new()
	add_child_autofree(clock)
	_stub_data.trample_resistance = 1.0
	_stub_data.growth_chance = 0.0
	plant.set_growth_stage(3)
	plant._time_manager = clock
	plant.set_process(false)
	plant.trample(0.2)
	assert_true(plant.is_processing(), "damage must re-arm the tick")
	# Heal it off: 0.2 of damage at 0.15/day needs ~32 hours.
	for h in 40:
		plant._last_hour = -1
		clock.time_of_day = float(h % 24) / 24.0
		plant._process(0.0)
	assert_eq(plant.trample_damage(), 0.0)
	plant._process(0.0)
	assert_false(plant.is_processing(), "healed and mature: back off the frame")


# ===========================================================================
# Multi-individual cells (individuals_per_cell)
# ===========================================================================
# The grid still holds ONE occupant per cell; the extra individuals are draw
# commands on the plant's own CanvasItem. So these tests assert on the private
# offset arrays and on the sprite, not on the occupant registry.

func _instance_with(data_path: String) -> Frailejon:
	var inst: Frailejon = load("res://scenes/tools/frailejon.tscn").instantiate()
	inst.data = load(data_path)
	add_child_autofree(inst)
	return inst


func test_single_individual_kinds_draw_nothing_extra() -> void:
	var inst := _instance_with("res://resources/objects/frailejon.tres")
	await get_tree().process_frame
	assert_eq(inst.data.individuals_per_cell, Vector2i(1, 1),
		"an Espeletia is one plant on one cell")
	assert_eq(inst._extra_offsets.size(), 0)
	# Historical jitter box preserved for single-individual kinds.
	assert_between(inst._sprite.position.x, -4.0, 4.0)
	assert_between(inst._sprite.position.y, -4.0, 0.0)


func test_ground_cover_rolls_extra_individuals_inside_the_cell_diamond() -> void:
	var real: PlantObjectData = load("res://resources/objects/calamagrostis.tres")
	assert_gt(real.individuals_per_cell.x, 1, "calamagrostis.tres must clump")
	var inst := _instance_with("res://resources/objects/calamagrostis.tres")
	await get_tree().process_frame
	var n: int = inst._extra_offsets.size() + 1
	assert_between(n, real.individuals_per_cell.x, real.individuals_per_cell.y)
	assert_eq(inst._extra_flips.size(), inst._extra_offsets.size())
	for o in inst._extra_offsets:
		# |x|/SPREAD_X + |y|/SPREAD_Y <= 1, with a texel of rounding slack.
		var d: float = absf(o.x) / Frailejon._SPREAD_X + absf(o.y) / Frailejon._SPREAD_Y
		assert_lt(d, 1.35, "offset %s is outside the cell diamond" % o)


func test_the_sprite_is_the_frontmost_individual() -> void:
	# Extras are drawn by _draw(), which runs BEFORE the child Sprite2D, so
	# the sprite can only occlude correctly if it holds the largest y.
	for i in 12:
		var inst := _instance_with("res://resources/objects/calamagrostis.tres")
		await get_tree().process_frame
		for o in inst._extra_offsets:
			assert_true(o.y <= inst._sprite.position.y,
				"extra at %s is in front of the sprite at %s" % [o, inst._sprite.position])


func test_burning_a_clump_chars_the_extras_too() -> void:
	var inst := _instance_with("res://resources/objects/calamagrostis.tres")
	await get_tree().process_frame
	inst.apply_burn_material()
	assert_not_null(inst.material, "the clump's own CanvasItem needs the burn shader")
	assert_eq(inst.material, inst._sprite.material)
	inst.clear_burn_material()
	# Calamagrostis does not sway, so both items go back to no material at all.
	# The give-it-back case is test_burning_takes_the_sway_and_dousing_gives_it_back.
	assert_eq(inst._sprite.material, inst.data.wind_material)
	assert_null(inst.material)


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
