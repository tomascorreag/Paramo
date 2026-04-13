extends GutTest

# ===========================================================================
# Player._update_lantern wrap-around time window logic
# ===========================================================================
# Player can't be instantiated in tests (needs Sprite2D, Shadow, Camera2D,
# PlayerLight children). We test the pure should_be_on formula directly.

# Replicates the exact logic from Player._update_lantern:
#   if activate > deactivate:
#       should_be_on = t >= activate or t < deactivate     (wraps midnight)
#   else:
#       should_be_on = t >= activate and t < deactivate    (normal window)

func _should_lantern_be_on(t: float, activate: float, deactivate: float) -> bool:
	if activate > deactivate:
		return t >= activate or t < deactivate
	else:
		return t >= activate and t < deactivate


# --- Wrap window: activate=0.75 (dusk), deactivate=0.28 (dawn) ---
# Active window crosses midnight: [0.75, 1.0) U [0.0, 0.28)

func test_wrap_on_at_dusk() -> void:
	assert_true(_should_lantern_be_on(0.80, 0.75, 0.28))


func test_wrap_on_at_night() -> void:
	assert_true(_should_lantern_be_on(0.90, 0.75, 0.28))


func test_wrap_on_past_midnight() -> void:
	assert_true(_should_lantern_be_on(0.10, 0.75, 0.28))


func test_wrap_off_at_noon() -> void:
	assert_false(_should_lantern_be_on(0.50, 0.75, 0.28))


func test_wrap_off_before_activate() -> void:
	assert_false(_should_lantern_be_on(0.74, 0.75, 0.28))


# --- Non-wrap window: activate=0.30, deactivate=0.75 ---

func test_normal_on_midday() -> void:
	assert_true(_should_lantern_be_on(0.50, 0.30, 0.75))


func test_normal_off_before_activate() -> void:
	assert_false(_should_lantern_be_on(0.29, 0.30, 0.75))


func test_normal_off_after_deactivate() -> void:
	assert_false(_should_lantern_be_on(0.76, 0.30, 0.75))


# --- Edge cases ---

func test_exactly_at_activate_is_on() -> void:
	assert_true(_should_lantern_be_on(0.75, 0.75, 0.28))


func test_exactly_at_deactivate_is_off() -> void:
	# t < deactivate is strict, so t == deactivate is OFF.
	assert_false(_should_lantern_be_on(0.28, 0.75, 0.28))


func test_midnight_in_wrap_window() -> void:
	# t=0.0 with wrap window [0.75, 0.28): 0.0 < 0.28 -> ON.
	assert_true(_should_lantern_be_on(0.0, 0.75, 0.28))
