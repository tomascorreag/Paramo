extends GutTest

# Guards the grass-length ladders read off the REAL atlas, because that is where
# they are authored: GrassLadder names no coordinate, so every property below is
# a property of base_tileset.tres's grass_tone / grass_length custom data and an
# atlas edit that breaks one breaks the ladder silently in game (grass that never
# shortens looks exactly like grass that has not been walked on yet).

# The warm ladder's top rung is the tall pale PAJA — the same species left to
# grow out, not a different one. It is the only rung whose tile is 1x3 rather
# than 1x2, so stepping off it visibly drops the skyline by half a cell, which is
# the point.
const PAJA: Vector2i = Vector2i(0, 10)
const WARM: Array[Vector2i] = [
	Vector2i(0, 8), Vector2i(0, 6), Vector2i(0, 0), Vector2i(0, 2), Vector2i(0, 4),
	PAJA,
]
const COOL: Array[Vector2i] = [
	Vector2i(1, 8), Vector2i(1, 6), Vector2i(1, 0), Vector2i(1, 2), Vector2i(1, 4),
]

var _ladder: GrassLadder


func before_each() -> void:
	var tile_set: TileSet = load("res://resources/tiles/base_tileset.tres")
	_ladder = GrassLadder.new(tile_set, RegrowthManager.SOURCE_GRASS)


func test_the_warm_grass_runs_short_to_long() -> void:
	for i in WARM.size():
		assert_eq(_ladder.top_rung(WARM[i]), i,
				"warm rung %d is not where the atlas puts %s" % [i, WARM[i]])


func test_the_cool_grass_runs_short_to_long() -> void:
	for i in COOL.size():
		assert_eq(_ladder.top_rung(COOL[i]), i,
				"cool rung %d is not where the atlas puts %s" % [i, COOL[i]])


func test_the_two_tones_are_separate_ladders() -> void:
	# The whole point of grass_tone: wearing a cool cell down must never walk it
	# into the warm art, which would read as the grass changing species.
	for i in COOL.size():
		assert_eq(_ladder.coord_at(COOL[COOL.size() - 1], i), COOL[i],
				"the tallest cool grass wore down into another tone at rung %d" % i)


func test_a_cell_wears_down_its_own_ladder() -> void:
	var tall: Vector2i = WARM[WARM.size() - 1]
	for i in WARM.size():
		assert_eq(_ladder.coord_at(tall, i), WARM[i])


func test_rungs_are_clamped_to_the_ladder() -> void:
	# _rung_for clamps too, but the ladder must be safe on its own — it is the
	# thing that knows how long it is.
	assert_eq(_ladder.coord_at(WARM[2], -5), WARM[0])
	assert_eq(_ladder.coord_at(WARM[2], 99), WARM[WARM.size() - 1])


func test_the_paja_is_the_warm_ladder_at_full_height() -> void:
	# The tallest thing on the mountain has the furthest to fall, so it is also
	# the cell where the feature is most visible. It is warm grass grown out, NOT
	# a species of its own — a cell generated as paja must wear down through the
	# warm greens rather than dropping straight to dirt.
	assert_eq(_ladder.tone_of(PAJA), _ladder.tone_of(WARM[0]))
	assert_eq(_ladder.top_rung(PAJA), WARM.size() - 1)
	assert_eq(_ladder.coord_at(PAJA, 0), WARM[0])


func test_rung_count_separates_a_lone_species_from_a_bottom_rung() -> void:
	# Both report top_rung 0 and they mean opposite things — "there is nothing
	# shorter than me" versus "I AM the shortest of five". Anything auditing a
	# generated map for leaked degradation-only art has to tell them apart.
	assert_eq(_ladder.rung_count(WARM[0]), WARM.size())
	assert_eq(_ladder.rung_count(COOL[0]), COOL.size())
	assert_eq(_ladder.rung_count(Vector2i(2, 0)), 1, "a slope is its own only rung")


func test_unladdered_tiles_report_themselves() -> void:
	# Slopes, walls and stairs are painted once each, so callers must be able to
	# ask about any grass coord at all without checking first.
	var slope := Vector2i(2, 0)  # SLOPE_NW on the grass source
	assert_eq(_ladder.top_rung(slope), 0)
	assert_eq(_ladder.coord_at(slope, 4), slope)


func test_an_absent_tile_set_yields_an_inert_ladder() -> void:
	var empty := GrassLadder.new(null, RegrowthManager.SOURCE_GRASS)
	assert_eq(empty.top_rung(WARM[3]), 0)
	assert_eq(empty.coord_at(WARM[3], 0), WARM[3],
			"an inert ladder must hand the coord back, not an unset one")
