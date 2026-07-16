extends GutTest

# Guards FireDynamics — the pure sim math behind the wildfire. This is where the
# behaviour the user asked for is pinned as a spec:
#
#   - a fire grows on its own from kindling (no isolated-cap ceiling);
#   - it is "slow at first": it can't spread until it climbs past SPREAD_MIN,
#     and spread chance ramps up with intensity;
#   - it burns its tile's fuel at a rate set by how hot it is, then dies back to
#     embers and out — so a whole life is finite and near the old ~10s;
#   - over a life it reliably seeds a grass neighbour (fires don't silently stop
#     propagating — the load-bearing spread-window guard).


# --- Intensity ---------------------------------------------------------------

func test_intensity_starts_at_zero_and_ramps_up() -> void:
	assert_eq(FireDynamics.intensity(0.0, 1.0), 0.0, "a just-lit fire has no size yet")
	# Monotonic in age up to full ramp, at plentiful fuel.
	var prev: float = -1.0
	for i: int in range(0, 11):
		var age: float = FireDynamics.RAMP_SECONDS * float(i) / 10.0
		var v: float = FireDynamics.intensity(age, 1.0)
		assert_gte(v, prev, "intensity must not drop as a well-fuelled fire ages")
		prev = v
	assert_almost_eq(FireDynamics.intensity(FireDynamics.RAMP_SECONDS, 1.0), 1.0, 0.001,
		"a well-fuelled fire reaches full intensity by RAMP_SECONDS")


func test_intensity_is_slow_at_first() -> void:
	# Early on it must be below the spread gate — it has to GROW before it spreads.
	# On plentiful fuel intensity == ramp, so it crosses SPREAD_MIN at ~0.2 of the
	# ramp; sample below that to prove there is a genuine no-spread growth window.
	var early: float = FireDynamics.intensity(FireDynamics.RAMP_SECONDS * 0.15, 1.0)
	assert_lt(early, FireDynamics.SPREAD_MIN,
		"a fresh fire must still be sub-spread (kindling) early in the ramp")


func test_intensity_dies_back_to_embers_as_fuel_runs_out() -> void:
	var full_fuel: float = FireDynamics.intensity(FireDynamics.RAMP_SECONDS, 1.0)
	var no_fuel: float = FireDynamics.intensity(FireDynamics.RAMP_SECONDS, 0.0)
	assert_lt(no_fuel, full_fuel, "a fire on spent fuel must be dimmer than one on full fuel")
	assert_almost_eq(no_fuel, FireDynamics.EMBER_INTENSITY, 0.001,
		"at zero fuel a fully-aged fire sits at the ember floor")


func test_intensity_is_capped_by_the_fires_ceiling() -> void:
	# Each fire rolls its own max_intensity; the whole envelope scales to it, so a
	# well-fuelled, fully-aged fire peaks at exactly its ceiling (not 1.0).
	for cap: float in [0.25, 0.5, 1.0]:
		assert_almost_eq(FireDynamics.intensity(FireDynamics.RAMP_SECONDS, 1.0, cap), cap, 0.001,
			"a fire's peak intensity must equal its ceiling %.2f" % cap)
	# Scaling, not clamping: the ember floor stays BELOW a low ceiling rather than
	# poking above it.
	var low_ember: float = FireDynamics.intensity(FireDynamics.RAMP_SECONDS, 0.0, 0.25)
	assert_lt(low_ember, 0.25, "the ember floor must sit under a 0.25-ceiling fire, not above it")


func test_a_low_ceiling_fire_barely_spreads_vs_a_high_one() -> void:
	# The point of the random ceiling: small fires mostly just char their tile,
	# big ones run away. A min-ceiling fire's lifetime spread must be far below a
	# max-ceiling one's.
	var weak: float = float(_simulate_life(FireDynamics.FUEL_DEFAULT, FireDynamics.MAX_INTENSITY_MIN)["spread_sum"])
	var strong: float = float(_simulate_life(FireDynamics.FUEL_DEFAULT, FireDynamics.MAX_INTENSITY_MAX)["spread_sum"])
	assert_lt(weak, strong * 0.25, "a weak fire must spread far less than a strong one")


func test_intensity_clamps_out_of_range_inputs() -> void:
	assert_eq(FireDynamics.intensity(-5.0, 1.0), 0.0, "negative age is not a fire running backwards")
	assert_almost_eq(FireDynamics.intensity(9999.0, 1.0), 1.0, 0.001, "age saturates at full ramp")
	# fuel_frac out of range must clamp, not extrapolate the ember lerp.
	assert_eq(FireDynamics.intensity(FireDynamics.RAMP_SECONDS, 5.0),
		FireDynamics.intensity(FireDynamics.RAMP_SECONDS, 1.0), "fuel_frac clamps at 1")


# --- Fuel --------------------------------------------------------------------

func test_fuel_burns_faster_when_hotter() -> void:
	assert_eq(FireDynamics.fuel_consumed(0.0, 0.1), 0.0, "a dead-cold fire eats no fuel")
	var lo: float = FireDynamics.fuel_consumed(0.3, 0.1)
	var hi: float = FireDynamics.fuel_consumed(1.0, 0.1)
	assert_gt(lo, 0.0, "a live fire consumes fuel")
	assert_gt(hi, lo, "a hotter fire consumes fuel faster")


# --- Spread ------------------------------------------------------------------

func test_spread_is_gated_below_the_minimum() -> void:
	assert_eq(FireDynamics.spread_probability(FireDynamics.SPREAD_MIN - 0.01, 0.1, 1.0), 0.0,
		"a fire below SPREAD_MIN cannot spread — it just grows")
	assert_eq(FireDynamics.spread_probability(0.0, 0.1, 1.0), 0.0, "kindling never spreads")


func test_spread_rises_with_intensity_and_scales_with_rain() -> void:
	var mid: float = FireDynamics.spread_probability(0.5, 0.1, 1.0)
	var hot: float = FireDynamics.spread_probability(1.0, 0.1, 1.0)
	assert_gt(mid, 0.0, "above the gate, spread is possible")
	assert_gt(hot, mid, "a hotter fire spreads more readily")
	assert_eq(FireDynamics.spread_probability(1.0, 0.1, 0.0), 0.0, "rain (mult 0) stops spread")
	assert_almost_eq(
		FireDynamics.spread_probability(1.0, 0.1, 0.5),
		hot * 0.5, 0.0001, "rain scales the chance linearly")


# --- Flame count -------------------------------------------------------------

func test_flame_count_is_at_least_one_and_scales() -> void:
	assert_eq(FireDynamics.flame_count(0.0), 1, "even kindling draws one flame")
	assert_eq(FireDynamics.flame_count(1.0), FireDynamics.MAX_FLAMES_PER_CELL,
		"a full fire draws the max")
	var prev: int = 0
	for i: int in range(0, 11):
		var c: int = FireDynamics.flame_count(float(i) / 10.0)
		assert_gte(c, 1, "flame count is never zero")
		assert_gte(c, prev, "flame count must not drop as intensity rises")
		assert_lte(c, FireDynamics.MAX_FLAMES_PER_CELL, "flame count is capped")
		prev = c


# --- Whole-life integration (the load-bearing guards) ------------------------

# Simulate one fire's whole life at a fixed step (as FireManager does), returning
# {life, spread_sum}: total seconds burning, and the expected number of ignitions
# it would seed into ONE grass neighbour over that life (sum of per-frame spread
# probability at rain_mult 1). Pure — mirrors FireManager._advance_burns.
func _simulate_life(fuel_max: float, max_intensity: float = 1.0) -> Dictionary:
	var dt: float = 1.0 / 60.0
	var age: float = 0.0
	var fuel: float = fuel_max
	var spread_sum: float = 0.0
	var life: float = 0.0
	var guard: int = 0
	while fuel > 0.0 and guard < 200000:
		guard += 1
		age += dt
		var fuel_frac: float = clampf(fuel / fuel_max, 0.0, 1.0)
		var intensity: float = FireDynamics.intensity(age, fuel_frac, max_intensity)
		fuel -= FireDynamics.fuel_consumed(intensity, dt)
		if intensity >= FireDynamics.SPREAD_MIN:
			spread_sum += FireDynamics.spread_probability(intensity, dt, 1.0)
		life += dt
	return {"life": life, "spread_sum": spread_sum}


func test_a_fire_reliably_spreads_over_its_life() -> void:
	# R7: with the chosen constants, a fire must spend enough time in the
	# productive intensity band that it reliably seeds a grass neighbour. If this
	# ever drops near zero, fires silently stop propagating and the wildfire dies
	# out — retune RAMP_SECONDS / SPREAD_RATE / fuel until it holds.
	var r: Dictionary = _simulate_life(FireDynamics.FUEL_DEFAULT)
	assert_gt(float(r["spread_sum"]), 0.5,
		"expected spreads into one neighbour over a life is too low — fires won't propagate")


func test_a_fire_life_is_finite_and_near_ten_seconds() -> void:
	# R6: FireManager's MAX_CONCURRENT_BURNING=80 and the flame budget were sized
	# against the old ~10s burn. Keep a default tile's life in a sane band so those
	# bounds stay valid.
	var r: Dictionary = _simulate_life(FireDynamics.FUEL_DEFAULT)
	assert_between(float(r["life"]), 6.0, 20.0,
		"a default tile's burn life drifted out of the ~10s band the budgets assume")
