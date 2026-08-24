extends GutTest

# ===========================================================================
# Visitor palette — the wardrobe, the slot encoding, and the roll
# ===========================================================================
#
# Guards the properties resources/characters/visitor_palette.tres cannot state
# about itself: that every colour on a visitor is a palette2 entry, that a
# "brightness gradient" really is one, and that a roll can never index off the
# end of a ramp.
#
# It deliberately stops at what GDScript decides. Whether the SHADER emits
# those colours is a different question and a different tool —
# scripts/tools/verify_visitor_palette.gd renders the sheet and diffs it, which
# is the only thing that can catch the shader's copy of the encoding constants
# drifting from VisitorSlots'.

const PALETTE_PATH := "res://resources/characters/visitor_palette.tres"
const SHEET_PATH := "res://assets/sprites/characters/Visitor_1_general.png"

var palette: VisitorPalette


func before_all() -> void:
	palette = load(PALETTE_PATH) as VisitorPalette


func _all_ramps() -> Array:
	var out: Array = []
	for slot in VisitorSlots.SLOT_COUNT:
		for ramp in palette.slot_ramps(slot):
			out.append([VisitorSlots.slot_name(slot), ramp])
	return out


static func _is_palette(c: Color) -> bool:
	for p in Palette.COLORS:
		if is_equal_approx(c.r, p.r) and is_equal_approx(c.g, p.g) and is_equal_approx(c.b, p.b):
			return true
	return false


# ---------------------------------------------------------------------------
# The wardrobe
# ---------------------------------------------------------------------------

func test_palette_resource_loads() -> void:
	assert_not_null(palette, "%s must exist and carry the VisitorPalette script" % PALETTE_PATH)


func test_every_slot_has_at_least_one_ramp() -> void:
	for slot in VisitorSlots.SLOT_COUNT:
		assert_gt(palette.slot_ramps(slot).size(), 0,
				"slot '%s' has no ramps — visitors would render magenta there"
				% VisitorSlots.slot_name(slot))


func test_every_stop_is_a_palette2_entry() -> void:
	# CLAUDE.md's Color Palette rule. A ramp is authored stop by stop precisely
	# so no interpolation can invent a colour that is in no palette.
	for entry in _all_ramps():
		var ramp: VisitorRamp = entry[1]
		for i in ramp.stops.size():
			assert_true(_is_palette(ramp.stops[i]),
					"%s ramp '%s' stop %d (%s) is not in palette2"
					% [entry[0], ramp.name, i, ramp.stops[i].to_html(false)])


func test_ramps_run_dark_to_light() -> void:
	# The whole shading model assumes stops[i-1] is a SHADOW of stops[i]. A ramp
	# authored the other way round would light the shaded texels and shade the
	# lit ones, which reads as the sprite being inside out.
	for entry in _all_ramps():
		var ramp: VisitorRamp = entry[1]
		for i in range(1, ramp.stops.size()):
			assert_gt(ramp.stops[i].get_luminance(), ramp.stops[i - 1].get_luminance(),
					"%s ramp '%s': stop %d must be brighter than stop %d"
					% [entry[0], ramp.name, i, i - 1])


func test_every_ramp_can_shade_the_art() -> void:
	for entry in _all_ramps():
		var ramp: VisitorRamp = entry[1]
		assert_gte(ramp.stops.size(), VisitorSlots.STEPS_PER_SLOT,
				"%s ramp '%s' has %d stop(s); the art paints %d shading rungs"
				% [entry[0], ramp.name, ramp.stops.size(), VisitorSlots.STEPS_PER_SLOT])


func test_ramps_have_names() -> void:
	for entry in _all_ramps():
		var ramp: VisitorRamp = entry[1]
		assert_ne(String(ramp.name), "",
				"an unnamed %s ramp makes the Inspector array unreadable" % entry[0])


# ---------------------------------------------------------------------------
# VisitorRamp.at_step — the window into a ramp
# ---------------------------------------------------------------------------

func test_at_step_takes_top_and_the_rung_below_it() -> void:
	var ramp := VisitorRamp.new()
	ramp.stops = PackedColorArray([Palette.P08, Palette.P06, Palette.P10, Palette.P04])
	assert_eq(ramp.at_step(2, 1, 2), Palette.P10, "lit texels take stops[top]")
	assert_eq(ramp.at_step(2, 0, 2), Palette.P06, "shaded texels take the rung below")


func test_at_step_clamps_at_the_dark_end() -> void:
	# The requested behaviour: choose the darkest tone as the base and the shade
	# collapses onto it rather than running off the ramp.
	var ramp := VisitorRamp.new()
	ramp.stops = PackedColorArray([Palette.P08, Palette.P06, Palette.P10])
	assert_eq(ramp.at_step(0, 0, 2), Palette.P08)
	assert_eq(ramp.at_step(0, 1, 2), Palette.P08,
			"at the bottom of the ramp both rungs are the same colour")


func test_at_step_clamps_at_the_light_end() -> void:
	var ramp := VisitorRamp.new()
	ramp.stops = PackedColorArray([Palette.P08, Palette.P06])
	assert_eq(ramp.at_step(9, 1, 2), Palette.P06, "a top past the end clamps, never errors")


func test_empty_ramp_is_visibly_wrong_not_a_crash() -> void:
	var ramp := VisitorRamp.new()
	assert_eq(ramp.at_step(0, 0, 2), Color.MAGENTA)


# ---------------------------------------------------------------------------
# VisitorSlots — the encoding
# ---------------------------------------------------------------------------

func test_encode_decode_round_trips_every_slot_and_step() -> void:
	for slot in VisitorSlots.SLOT_COUNT:
		for step in VisitorSlots.STEPS_PER_SLOT:
			var pair := VisitorSlots.decode(VisitorSlots.encode(slot, step))
			assert_eq(pair, [slot, step],
					"%s step %d did not survive the round trip"
					% [VisitorSlots.slot_name(slot), step])


func test_decode_rejects_a_colour_that_is_not_an_index() -> void:
	assert_eq(VisitorSlots.decode(Color.WHITE), [-1, -1])
	assert_eq(VisitorSlots.decode(Color.BLACK), [-1, -1])


func test_uniform_indices_are_dense_and_unique() -> void:
	var seen: Dictionary = {}
	for slot in VisitorSlots.SLOT_COUNT:
		for step in VisitorSlots.STEPS_PER_SLOT:
			var i := VisitorSlots.uniform_index(slot, step)
			assert_false(seen.has(i), "uniform index %d used twice" % i)
			assert_between(i, 0, VisitorSlots.uniform_count() - 1)
			seen[i] = true
	assert_eq(seen.size(), VisitorSlots.uniform_count())


func test_source_colours_cover_every_slot() -> void:
	# A slot with no source colour has no texels on the sheet, so its ramps
	# would be authored and never seen.
	var covered: Dictionary = {}
	for hex: String in VisitorSlots.SOURCE_COLOURS:
		covered[VisitorSlots.SOURCE_COLOURS[hex][0]] = true
	for slot in VisitorSlots.SLOT_COUNT:
		assert_true(covered.has(slot),
				"no source colour maps to slot '%s'" % VisitorSlots.slot_name(slot))


func test_source_colours_are_palette2_entries() -> void:
	# The art is palette-bound at authoring time; this catches a repaint that
	# sampled a colour from somewhere else and was then copied in here.
	for hex: String in VisitorSlots.SOURCE_COLOURS:
		assert_true(_is_palette(Color.html(hex)), "source colour %s is not in palette2" % hex)


func test_every_shipped_sheet_only_contains_indices() -> void:
	# A shipped sheet must be the TOOL's output, not the art. A stray texel
	# renders as a hole (the shader discards what it cannot decode) — which is
	# exactly what happens if a new body sheet is dropped in and someone forgets
	# to run index_character_sheet.gd over it.
	for path: String in VisitorAppearance.SHEETS:
		var img := Image.load_from_file(ProjectSettings.globalize_path(path))
		assert_not_null(img, "%s must exist — run index_character_sheet.gd" % path)
		if img == null:
			continue
		img.convert(Image.FORMAT_RGBA8)
		var bad: int = 0
		for y in img.get_height():
			for x in img.get_width():
				var c := img.get_pixel(x, y)
				if c.a <= 0.0:
					continue
				if VisitorSlots.decode(c)[0] < 0:
					bad += 1
		assert_eq(bad, 0, "%s: %d opaque texel(s) do not decode to a slot" % [path, bad])


func test_every_shipped_sheet_shares_the_rig() -> void:
	# visitor.tscn authors hframes = 24 once, for whichever sheet is swapped in
	# at spawn. A sheet of a different width would silently play the wrong
	# frames rather than fail.
	for path: String in VisitorAppearance.SHEETS:
		var img := Image.load_from_file(ProjectSettings.globalize_path(path))
		if img == null:
			continue
		assert_eq(img.get_width(), 32 * GridWalker.WALK_FRAMES_PER_DIR * 4,
				"%s is not 4 facings x 6 frames of 32px" % path)
		assert_eq(img.get_height(), 32, "%s is not 32px tall" % path)


func test_no_facing_block_repeats_another() -> void:
	# Visitor_2 shipped with its NW block a straight COPY of its NE block for 5
	# of 6 frames (only the last was mirrored), so a visitor walking NW faced NE
	# for most of the cycle and snapped round once per loop. Nothing in the rig
	# checks — it is 24 frames of the right size either way. Comparing each frame
	# against the same index in every OTHER facing catches a duplicated block
	# without asserting HOW the art is authored (the sheets mirror NE->NW, but
	# baseWalker has one hand-touched frame, so "must be a mirror" would be a
	# false constraint).
	for path: String in VisitorAppearance.SHEETS:
		var img := Image.load_from_file(ProjectSettings.globalize_path(path))
		if img == null:
			continue
		var frames: int = GridWalker.WALK_FRAMES_PER_DIR
		for f in frames:
			for a in 4:
				for b in range(a + 1, 4):
					var ra := Rect2i((a * frames + f) * 32, 0, 32, 32)
					var rb := Rect2i((b * frames + f) * 32, 0, 32, 32)
					assert_false(img.get_region(ra).get_data()
									== img.get_region(rb).get_data(),
							"%s: facing %d and %d share frame %d" % [path, a, b, f])


func test_a_build_is_rolled_per_visitor() -> void:
	# Two sheets means two BUILDS, not two colourways — recolouring alone gives
	# a crowd one silhouette in different outfits.
	assert_gt(VisitorAppearance.SHEETS.size(), 1,
			"with one sheet everyone has the same body")
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var seen: Dictionary = {}
	for _i in 40:
		var tex := VisitorAppearance.roll_sheet(rng)
		assert_not_null(tex)
		seen[tex.resource_path] = true
	assert_eq(seen.size(), VisitorAppearance.SHEETS.size(),
			"every sheet must be reachable from the roll")


func test_the_build_roll_is_deterministic_for_a_seed() -> void:
	var a := RandomNumberGenerator.new()
	var b := RandomNumberGenerator.new()
	a.seed = 99
	b.seed = 99
	assert_eq(VisitorAppearance.roll_sheet(a), VisitorAppearance.roll_sheet(b))


# ---------------------------------------------------------------------------
# VisitorAppearance — rolling
# ---------------------------------------------------------------------------

func test_resolve_fills_every_uniform_slot_with_a_palette_colour() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	for _i in 20:
		var colors := VisitorAppearance.roll_colors(palette, rng)
		assert_eq(colors.size(), VisitorSlots.uniform_count())
		for c in colors:
			assert_true(_is_palette(c), "rolled %s is not in palette2" % c.to_html(false))


func test_roll_is_deterministic_for_a_seed() -> void:
	# Visitors are spawned off a seeded stream like every other stochastic
	# system here, so the same seed must produce the same crowd.
	var a := RandomNumberGenerator.new()
	var b := RandomNumberGenerator.new()
	a.seed = 99
	b.seed = 99
	assert_eq(VisitorAppearance.roll(palette, a), VisitorAppearance.roll(palette, b))


func test_roll_respects_min_top_index() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for _i in 50:
		var choices := VisitorAppearance.roll(palette, rng)
		for slot in VisitorSlots.SLOT_COUNT:
			var ramps := palette.slot_ramps(slot)
			var pick: Array = choices[slot]
			var ramp: VisitorRamp = ramps[pick[0]]
			assert_between(pick[1], mini(palette.min_top_index, ramp.max_top()), ramp.max_top(),
					"%s roll picked a top outside its ramp" % VisitorSlots.slot_name(slot))


# ---------------------------------------------------------------------------
# VisitorPalette.pick_ramp — rarity
# ---------------------------------------------------------------------------

static func _ramp(n: String, w: float) -> VisitorRamp:
	var r := VisitorRamp.new()
	r.name = StringName(n)
	r.stops = PackedColorArray([Palette.P08, Palette.P06])
	r.weight = w
	return r


static func _palette_of(ramps: Array[VisitorRamp]) -> VisitorPalette:
	var p := VisitorPalette.new()
	p.hair = ramps
	return p


func _tally(p: VisitorPalette, draws: int, seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var counts: Dictionary = {}
	for _i in draws:
		var i := p.pick_ramp(VisitorSlots.Slot.HAIR, rng)
		counts[i] = counts.get(i, 0) + 1
	return counts


func test_a_heavier_ramp_comes_up_more_often() -> void:
	# The headline behaviour: 3 vs 1 is three-to-one, not "somewhat more".
	var p := _palette_of([_ramp("common", 3.0), _ramp("rare", 1.0)] as Array[VisitorRamp])
	var counts := _tally(p, 8000, 1234)
	var ratio := float(counts.get(0, 0)) / float(maxi(counts.get(1, 0), 1))
	assert_almost_eq(ratio, 3.0, 0.25, "weight 3 beside weight 1 should land near 3:1")


func test_weights_are_ratios_not_percentages() -> void:
	# Scaling a whole slot must change nothing — that is what lets a ramp be
	# added without re-normalising every other number in the array.
	var a := _tally(_palette_of([_ramp("x", 1.0), _ramp("y", 2.0)] as Array[VisitorRamp]), 4000, 77)
	var b := _tally(_palette_of([_ramp("x", 5.0), _ramp("y", 10.0)] as Array[VisitorRamp]), 4000, 77)
	assert_eq(a, b, "weights are normalised by their sum, so 1:2 and 5:10 are the same wardrobe")


func test_the_default_weight_rolls_uniformly() -> void:
	# An unweighted palette must behave exactly as it did before weights existed,
	# so adding the field cannot silently reshape a crowd.
	var p := _palette_of([_ramp("a", 1.0), _ramp("b", 1.0), _ramp("c", 1.0)] as Array[VisitorRamp])
	var counts := _tally(p, 6000, 4321)
	for i in 3:
		assert_almost_eq(float(counts.get(i, 0)), 2000.0, 250.0)


func test_a_fresh_ramp_defaults_to_the_neutral_weight() -> void:
	assert_eq(VisitorRamp.new().weight, 1.0,
			"a ramp added in the Inspector must join the roll without touching the others")


func test_a_zero_weight_ramp_never_appears() -> void:
	# The "park a colour without deleting it" case.
	var p := _palette_of([_ramp("live", 1.0), _ramp("parked", 0.0)] as Array[VisitorRamp])
	assert_false(_tally(p, 3000, 5).has(1), "a 0-weight ramp must be out of circulation")


func test_a_parked_ramp_last_in_the_array_is_still_never_picked() -> void:
	# Guards the float-rounding fallback: landing on "the last ramp" rather than
	# "the last ramp with weight" would hand out the parked one on that path.
	var p := _palette_of([_ramp("live", 2.0), _ramp("parked", 0.0)] as Array[VisitorRamp])
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for _i in 2000:
		assert_eq(p.pick_ramp(VisitorSlots.Slot.HAIR, rng), 0)


func test_an_all_zero_slot_falls_back_to_uniform() -> void:
	# A mis-authored slot should look wrong, not render magenta — magenta reads
	# as a shader fault and sends you to the wrong file.
	var p := _palette_of([_ramp("a", 0.0), _ramp("b", 0.0)] as Array[VisitorRamp])
	var counts := _tally(p, 2000, 9)
	assert_eq(counts.size(), 2, "with nothing weighted, every ramp is back in play")
	assert_false(counts.has(-1))


func test_a_negative_weight_is_treated_as_parked() -> void:
	var p := _palette_of([_ramp("live", 1.0), _ramp("typo", -5.0)] as Array[VisitorRamp])
	assert_false(_tally(p, 1000, 3).has(1))


func test_pick_ramp_reports_an_unauthored_slot() -> void:
	var rng := RandomNumberGenerator.new()
	assert_eq(VisitorPalette.new().pick_ramp(VisitorSlots.Slot.HAIR, rng), -1)


func test_every_shipped_ramp_is_reachable() -> void:
	# Nothing in the wardrobe should be accidentally parked: a ramp authored,
	# palette-checked and then never rolled is invisible dead data.
	for entry in _all_ramps():
		var ramp: VisitorRamp = entry[1]
		assert_gt(ramp.weight, 0.0,
				"%s ramp '%s' has weight %s — it is authored but can never appear"
				% [entry[0], ramp.name, ramp.weight])


func test_apply_writes_the_shader_uniform() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://assets/shaders/visitor_recolor.gdshader")
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var colors := VisitorAppearance.roll_colors(palette, rng)
	VisitorAppearance.apply(mat, colors)
	var got: PackedVector3Array = mat.get_shader_parameter(VisitorAppearance.UNIFORM)
	assert_eq(got.size(), VisitorSlots.uniform_count())
	for i in colors.size():
		assert_eq(got[i], Vector3(colors[i].r, colors[i].g, colors[i].b))
