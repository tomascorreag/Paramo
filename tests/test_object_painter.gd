extends GutTest

# ===========================================================================
# ObjectPainter — placement rules and the per-seed ecosystem pick
# ===========================================================================
# Synthetic TerrainGrid: flat grass, one column of water, altitude authored
# per test. Exercises the pure terms (_altitude_term / _water_term) directly
# and assign_object_kinds end to end with the real registry and profiles.

# Small enough that a fully eligible flat grid stays under
# ObjectPainter.PLANT_BUDGET — the budget warning is not what is under test.
const _W: int = 24
const _H: int = 24


func _flat_grid(altitude: int, with_water: bool = true) -> TerrainGrid:
	var g := TerrainGrid.new(_W, _H)
	for y in _H:
		for x in _W:
			var c := TerrainCell.new()
			c.kind = TerrainCell.Kind.WATER if (with_water and x == 0) else TerrainCell.Kind.GROUND
			c.biome = TerrainCell.Biome.GRASS
			c.ground_shape = TerrainCell.GroundShape.FULL_CUBE
			c.altitude = altitude
			g.set_cell(x, y, c)
	return g


func _rng(seed: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed
	return r


func _count(g: TerrainGrid, kind: StringName) -> int:
	var n: int = 0
	for y in g.height:
		for x in g.width:
			if g.at(x, y).object_kind == kind:
				n += 1
	return n


func _kinds_map(g: TerrainGrid) -> PackedStringArray:
	var out := PackedStringArray()
	for y in g.height:
		for x in g.width:
			out.append(String(g.at(x, y).object_kind))
	return out


# --- altitude term ----------------------------------------------------------

func test_band_is_flat_inside() -> void:
	var d := WorldObjectData.new()
	d.altitude_band = Vector2i(10, 20)
	assert_eq(ObjectPainter._altitude_term(d, 10), 1.0)
	assert_eq(ObjectPainter._altitude_term(d, 15), 1.0)
	assert_eq(ObjectPainter._altitude_term(d, 20), 1.0)


func test_band_decays_outside() -> void:
	# σ = 3 half-steps: exp(-2) ≈ 0.135 at 6 out, exp(-4.5) ≈ 0.011 at 9 out.
	var d := WorldObjectData.new()
	d.altitude_band = Vector2i(10, 20)
	assert_almost_eq(ObjectPainter._altitude_term(d, 26), exp(-2.0), 1e-6)
	assert_almost_eq(ObjectPainter._altitude_term(d, 4), exp(-2.0), 1e-6)
	assert_lt(ObjectPainter._altitude_term(d, 29), 0.02)
	assert_gt(ObjectPainter._altitude_term(d, 22), 0.5)


func test_band_wins_over_preferred_altitude() -> void:
	var d := WorldObjectData.new()
	d.altitude_band = Vector2i(10, 20)
	d.preferred_altitude = 30
	assert_eq(ObjectPainter._altitude_term(d, 15), 1.0)


func test_preferred_altitude_fallback_and_flat() -> void:
	var d := WorldObjectData.new()
	d.preferred_altitude = 18
	assert_eq(ObjectPainter._altitude_term(d, 18), 1.0)
	assert_lt(ObjectPainter._altitude_term(d, 24), 0.2)
	var flat := WorldObjectData.new()
	assert_eq(ObjectPainter._altitude_term(flat, 3), 1.0)


# --- water term --------------------------------------------------------------

func test_attraction_falls_with_distance_and_collapses_without_water() -> void:
	assert_almost_eq(ObjectPainter._water_term(0.5, 0), 1.0, 1e-6)
	assert_gt(ObjectPainter._water_term(0.5, 1), ObjectPainter._water_term(0.5, 2))
	assert_almost_eq(ObjectPainter._water_term(0.5, 2147483647), 0.0, 1e-6)


func test_avoidance_suppresses_shore_and_is_full_without_water() -> void:
	assert_almost_eq(ObjectPainter._water_term(-0.3, 1), 1.0 - exp(-0.3), 1e-6)
	assert_gt(ObjectPainter._water_term(-0.3, 3), 0.9)
	assert_almost_eq(ObjectPainter._water_term(-0.3, 2147483647), 1.0, 1e-6)


# --- assign_object_kinds -----------------------------------------------------

func test_same_seed_same_layout_and_ecosystem() -> void:
	var a := _flat_grid(14)
	var b := _flat_grid(14)
	ObjectPainter.assign_object_kinds(a, _rng(1234))
	ObjectPainter.assign_object_kinds(b, _rng(1234))
	assert_not_null(a.ecosystem)
	assert_eq(a.ecosystem.id, b.ecosystem.id)
	assert_eq(_kinds_map(a), _kinds_map(b))


func test_different_seeds_differ() -> void:
	var a := _flat_grid(14)
	var b := _flat_grid(14)
	ObjectPainter.assign_object_kinds(a, _rng(1))
	ObjectPainter.assign_object_kinds(b, _rng(2))
	assert_ne(_kinds_map(a), _kinds_map(b))


func test_profile_zero_scale_never_spawns() -> void:
	var g := _flat_grid(14)
	ObjectPainter.assign_object_kinds(g, _rng(7), ObjectPainter.profile_by_id(&"nevados"))
	assert_eq(g.ecosystem.id, &"nevados")
	assert_eq(_count(g, &"frailejon"), 0)
	assert_eq(_count(g, &"espeletia_barclayana"), 0)
	assert_gt(_count(g, &"calamagrostis"), 0)


func test_pinned_profile_is_written_to_grid() -> void:
	var g := _flat_grid(14)
	ObjectPainter.assign_object_kinds(g, _rng(7), ObjectPainter.profile_by_id(&"guerrero"))
	assert_eq(g.ecosystem.id, &"guerrero")
	assert_eq(_count(g, &"frailejon"), 0)
	assert_gt(_count(g, &"espeletia_barclayana"), 0)


func test_only_eligible_cells_get_objects() -> void:
	var g := _flat_grid(14)
	g.at(5, 5).ground_shape = TerrainCell.GroundShape.SLOPE_NE
	g.at(6, 6).kind = TerrainCell.Kind.EMPTY
	for s in 5:
		ObjectPainter.assign_object_kinds(g, _rng(s))
		assert_eq(g.at(5, 5).object_kind, &"")
		assert_eq(g.at(6, 6).object_kind, &"")
		for y in g.height:
			assert_eq(g.at(0, y).object_kind, &"")  # the water column


func test_every_kind_is_registered() -> void:
	var g := _flat_grid(14)
	for s in 3:
		ObjectPainter.assign_object_kinds(g, _rng(s), ObjectPainter.profiles()[s])
		for y in g.height:
			for x in g.width:
				var k: StringName = g.at(x, y).object_kind
				if k != &"":
					assert_not_null(ObjectPainter.data_for(k), "unregistered kind %s" % k)


func test_profile_by_id() -> void:
	assert_eq(ObjectPainter.profile_by_id(&"chingaza").id, &"chingaza")
	assert_null(ObjectPainter.profile_by_id(&""))
	assert_eq(ObjectPainter.profiles().size(), 3)


# --- data defaults -----------------------------------------------------------

func test_data_defaults() -> void:
	var d := WorldObjectData.new()
	assert_false(d.displaceable)
	assert_eq(d.altitude_band, Vector2i(-1, -1))
	assert_eq(d.patch_frequency, 0.0)
	assert_eq(d.patch_edge, 0.25)
	assert_eq(d.individuals_per_cell, Vector2i(1, 1))
	var p := PlantObjectData.new()
	assert_true(p.casts_shadow)


func test_ecosystem_profile_missing_kind_is_zero() -> void:
	var e := EcosystemProfile.new()
	e.density_scale = {&"chusquea": 0.5}
	e.plantable = [&"frailejon"]
	assert_eq(e.scale_for(&"chusquea"), 0.5)
	assert_eq(e.scale_for(&"frailejon"), 0.0)
	assert_true(e.can_plant(&"frailejon"))
	assert_false(e.can_plant(&"chusquea"))


func test_every_plantable_is_a_registered_plant_with_a_scale() -> void:
	for p in ObjectPainter.profiles():
		for kind in p.plantable:
			assert_true(ObjectPainter.data_for(kind) is PlantObjectData,
				"%s: %s is not a plant kind" % [p.id, kind])
			assert_gt(p.scale_for(kind), 0.0,
				"%s sells %s but never grows it" % [p.id, kind])


# --- patch gate --------------------------------------------------------------

func _patch_noise(freq: float) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = freq
	n.seed = 7
	return n


func test_patch_edge_sets_the_plateau_width() -> void:
	# The gate is clamp((noise - cut) / edge, 0, 1). Sample the same noise
	# field through a wide and a narrow edge: the narrow one must reach full
	# density on strictly more cells, which is what "the stand has an
	# interior" means. A wide edge over noise that only reaches +-0.75 is why
	# a patchy species can never hit its authored density.
	var noise := _patch_noise(0.08)
	var wide: int = 0
	var narrow: int = 0
	for y in 64:
		for x in 64:
			if ObjectPainter._patch_term(noise, 0.2, 0.25, x, y) >= 1.0:
				wide += 1
			if ObjectPainter._patch_term(noise, 0.2, 0.08, x, y) >= 1.0:
				narrow += 1
	assert_gt(narrow, wide, "a narrower ramp must widen the full-density plateau")
	assert_gt(narrow, 0, "cut 0.2 / edge 0.08 must have a plateau at all")


func test_patch_term_is_zero_below_the_cut_and_one_well_above() -> void:
	var noise := _patch_noise(0.08)
	for y in 32:
		for x in 32:
			var v: float = noise.get_noise_2d(float(x), float(y))
			var m: float = ObjectPainter._patch_term(noise, 0.0, 0.1, x, y)
			if v <= 0.0:
				assert_eq(m, 0.0)
			elif v >= 0.1:
				assert_eq(m, 1.0)
			else:
				assert_between(m, 0.0, 1.0)


func test_patch_amplitude_is_frequency_independent() -> void:
	# Frequency sets patch SIZE, not how much of the map a cut selects — the
	# .tres tuning table depends on this, so it is worth a test. Two very
	# different frequencies must select nearly the same share of cells.
	var shares: Array[float] = []
	for freq in [0.05, 0.12]:
		var n := _patch_noise(freq)
		var hits: int = 0
		for y in 96:
			for x in 96:
				if n.get_noise_2d(float(x), float(y)) >= 0.2:
					hits += 1
		shares.append(float(hits) / 9216.0)
	assert_almost_eq(shares[0], shares[1], 0.05)
