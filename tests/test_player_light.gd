extends GutTest

var light: PlayerLightController


func before_each() -> void:
	light = PlayerLightController.new()
	light.max_energy = 1.0
	light.transition_duration = 0.5
	light.energy_curve = null
	# Skip _ready's deferred texture baking — we only test transition logic.
	add_child_autofree(light)


# ===========================================================================
# activate / deactivate
# ===========================================================================

func test_starts_inactive() -> void:
	assert_false(light._target_active)
	assert_eq(light._transition_t, 0.0)


func test_activate_enables() -> void:
	light.activate()
	assert_true(light._target_active)
	assert_true(light.enabled)


func test_deactivate_sets_target() -> void:
	light.activate()
	light.deactivate()
	assert_false(light._target_active)


func test_double_activate_is_noop() -> void:
	light.activate()
	light._transition_t = 0.5  # mid-transition
	light.activate()  # should not reset anything
	assert_eq(light._transition_t, 0.5)


# ===========================================================================
# transition ramp up
# ===========================================================================

func test_ramp_up_advances() -> void:
	light.activate()
	light._process(0.25)  # 0.25 / 0.5 = 0.5
	assert_almost_eq(light._transition_t, 0.5, 0.001)


func test_ramp_up_clamps_at_1() -> void:
	light.activate()
	light._process(1.0)  # 1.0 / 0.5 = 2.0, clamped to 1.0
	assert_eq(light._transition_t, 1.0)


# ===========================================================================
# transition ramp down
# ===========================================================================

func test_ramp_down_decreases() -> void:
	light.activate()
	light._transition_t = 1.0
	light.enabled = true
	light.deactivate()
	light._process(0.25)  # 1.0 - 0.25/0.5 = 0.5
	assert_almost_eq(light._transition_t, 0.5, 0.001)
	assert_true(light.enabled)  # still on mid-fade


func test_ramp_down_disables_at_zero() -> void:
	light.activate()
	light._transition_t = 0.1
	light.enabled = true
	light.deactivate()
	light._process(0.5)  # 0.1 - 0.5/0.5 = -0.9, clamped to 0.0
	assert_eq(light._transition_t, 0.0)
	assert_false(light.enabled)


# ===========================================================================
# instant mode (transition_duration = 0)
# ===========================================================================

func test_instant_activate() -> void:
	light.transition_duration = 0.0
	light.activate()
	light._process(0.016)
	assert_eq(light._transition_t, 1.0)


func test_instant_deactivate() -> void:
	light.transition_duration = 0.0
	light._target_active = false
	light._transition_t = 1.0
	light.enabled = true
	light._process(0.016)
	assert_eq(light._transition_t, 0.0)


# ===========================================================================
# energy calculation
# ===========================================================================

func test_energy_without_curve() -> void:
	light.activate()
	light._transition_t = 0.6
	light.enabled = true
	light._process(0.0)  # zero delta, just recalc energy
	# energy = _transition_t * max_energy = 0.6 * 1.0 (after _process clamps)
	# But _process with 0 delta and active: t += 0/0.5 = 0, so t stays 0.6
	assert_almost_eq(light.energy, 0.6, 0.01)
