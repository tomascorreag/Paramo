extends GutTest
## The warp-block algebra JournalBlocks states, and the journal sections snap
## against. Pure arithmetic with no scene, so it can assert the cases the real page
## must never be authored into — including the one that shipped.

const BLOCK: int = 18


func test_a_run_shorter_than_a_block_fits_in_one_wherever_it_has_room() -> void:
	# 16 rows of ink in an 18-row block: two starting phases work, the rest push its
	# tail over the seam. This is the resources glyph.
	assert_eq(JournalBlocks.min_spans(16, BLOCK), 1)
	assert_eq(JournalBlocks.slack(16, BLOCK), 2, "two texels of freedom")
	assert_true(JournalBlocks.is_clean(36, 16, BLOCK))
	assert_true(JournalBlocks.is_clean(38, 16, BLOCK), "the last legal phase")
	assert_false(JournalBlocks.is_clean(39, 16, BLOCK), "one texel over the seam")


func test_a_run_as_tall_as_its_block_must_start_on_a_boundary() -> void:
	# Tiny5-16's line box. Zero slack is what pins the whole resources section.
	assert_eq(JournalBlocks.slack(18, BLOCK), 0)
	assert_true(JournalBlocks.is_clean(36, 18, BLOCK))
	assert_false(JournalBlocks.is_clean(37, 18, BLOCK))


func test_a_run_taller_than_a_block_crosses_seams_but_need_not_crossing_extra() -> void:
	# THE POINT the old whole-blocks rule missed. A 30-row fence swatch crosses a
	# seam wherever it is put — 30 > 18 — so the contract cannot be "avoid seams",
	# only "cross the fewest". That leaves it 7 legal phases, not 1.
	assert_eq(JournalBlocks.min_spans(30, BLOCK), 2, "it can never fit in one block")
	assert_eq(JournalBlocks.slack(30, BLOCK), 6)
	for phase: int in range(0, 7):
		assert_true(
			JournalBlocks.is_clean(36 + phase, 30, BLOCK),
			"phase %d must be legal for a 30-row run" % phase)
	assert_false(
		JournalBlocks.is_clean(43, 30, BLOCK),
		"phase 7 spills into a third block")


func test_the_gap_that_shipped_broken_is_rejected() -> void:
	# scenes/ui/field_journal.tscn carried header_gap_px = -12 on three sections,
	# which put the known sets' row top at 24 and the fence's ink at 27..56 — three
	# blocks where two would do. The regression this file exists for.
	assert_eq(JournalBlocks.spans(27, 30, BLOCK), 3)
	assert_false(JournalBlocks.is_clean(27, 30, BLOCK))


func test_snap_resolves_upward_on_a_tie() -> void:
	# A negative gap is a request to TIGHTEN, so a tie must not be answered by
	# moving the row down. Runs are (offset from the row's top, ink height).
	var runs: Array[Vector2i] = [Vector2i(0, 18)]
	assert_eq(JournalBlocks.snap_top(27, runs, BLOCK, 0), 18,
		"equidistant between 18 and 36, so take the tighter")
	assert_eq(JournalBlocks.snap_top(28, runs, BLOCK, 0), 36)


func test_snap_never_returns_a_top_below_the_floor() -> void:
	# The floor is the heading's own rule: tightening past it would print the
	# content through the line it is meant to sit under.
	var runs: Array[Vector2i] = [Vector2i(0, 18)]
	assert_eq(JournalBlocks.snap_top(-100, runs, BLOCK, 23), 36,
		"18 is legal but below the floor, so the next one up wins")


func test_snap_is_identity_when_the_request_already_renders() -> void:
	var runs: Array[Vector2i] = [Vector2i(3, 30), Vector2i(7, 21)]
	assert_eq(JournalBlocks.snap_top(36, runs, BLOCK, 23), 36)


func test_legal_tops_are_the_intersection_across_every_run() -> void:
	# A section's freedom is what ALL of its ink can live with, so the run with the
	# least slack decides. Ladder (21 rows, offset 7) and fence (30, offset 3) in
	# their authored 36-texel cells: the fence's 6 texels are what is left.
	var runs: Array[Vector2i] = [Vector2i(3, 30), Vector2i(7, 21)]
	var tops := JournalBlocks.legal_tops(runs, BLOCK, 23, 2 * BLOCK)
	assert_eq(Array(tops), [33, 34, 35, 36, 37, 38, 39, 51, 52, 53, 54, 55, 56, 57],
		"seven phases per block, offset by the fence's own centring")


func test_negative_tops_do_not_wrap_through_integer_division() -> void:
	# spans() is public and takes authored numbers; GDScript's / truncates toward
	# zero, so a naive floor would report the same block for -1 and 0.
	assert_eq(JournalBlocks.spans(-1, 2, BLOCK), 2, "-1..0 straddles the boundary")
	assert_eq(JournalBlocks.floordiv(-1, BLOCK), -1)
