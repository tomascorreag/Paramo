extends GutTest

# ===========================================================================
# The bent page corners that turn the journal's pages (JournalPageCorners).
# ===========================================================================
# Three kinds of guard:
#   - THE ART: the corner hit boxes are constants measured off
#     BookPageCrease.png; re-measure them here so a repaint cannot move a
#     corner out from under its hit box. The sheet is drawn over the audited
#     page area, so its colours are checked against the palette too.
#   - THE SEQUENCE: run spread, then the pairs — no wrap. Which corners have
#     somewhere to go, and where a click lands.
#   - THE INPUT CONTRACT: only the shown corner is hit; nothing else on the
#     paper loses its input to this node.

const JOURNAL_SCENE: PackedScene = preload("res://scenes/ui/field_journal.tscn")

var journal: FieldJournal
var corners: JournalPageCorners
var edge: JournalForeEdge


func before_each() -> void:
	journal = JOURNAL_SCENE.instantiate() as FieldJournal
	add_child_autofree(journal)
	corners = journal.get_node("Book/BookArt/PageCorners") as JournalPageCorners
	edge = journal.get_node("Book/BookArt/ForeEdge") as JournalForeEdge


func after_each() -> void:
	get_tree().paused = false


func _centre(c: int) -> Vector2:
	return Rect2(JournalPageCorners.CORNER_RECTS[c]).get_center()


func _far() -> Vector2:
	return Vector2(240, 135)


# --- the art -----------------------------------------------------------------

func test_the_corner_rects_are_where_the_sheet_differs_from_the_cover() -> void:
	# The sheet is Book.png with the corners bent — either a transparent
	# overlay or a full repaint, both have been authored — so a corner is the
	# bounding box, per quadrant, of the OPAQUE texels that differ from the
	# cover.
	var img := corners.texture.get_image()
	var book := (load("res://assets/sprites/UX/Panels/Book.png") as Texture2D).get_image()
	assert_not_null(img)
	assert_eq(img.get_size(), book.get_size(), "a full overlay of the cover")
	assert_eq(corners.size, Vector2(img.get_size()), "and the node is the same rectangle as the art")
	var w: int = img.get_width()
	var h: int = img.get_height()
	var quadrants: Array[Rect2i] = [
		Rect2i(0, 0, w / 2, h / 2), Rect2i(w / 2, 0, w - w / 2, h / 2),
		Rect2i(0, h / 2, w / 2, h - h / 2), Rect2i(w / 2, h / 2, w - w / 2, h - h / 2),
	]
	for c: int in 4:
		var q := quadrants[c]
		var lo := Vector2i(w, h)
		var hi := Vector2i(-1, -1)
		for y: int in range(q.position.y, q.end.y):
			for x: int in range(q.position.x, q.end.x):
				var px := img.get_pixel(x, y)
				if px.a > 0.0 and px != book.get_pixel(x, y):
					lo = Vector2i(mini(lo.x, x), mini(lo.y, y))
					hi = Vector2i(maxi(hi.x, x), maxi(hi.y, y))
		assert_true(hi.x >= 0, "corner %d: the sheet bends something in this quadrant" % c)
		var ink := Rect2i(lo, hi - lo + Vector2i.ONE)
		assert_eq(JournalPageCorners.CORNER_RECTS[c], ink,
			"corner %d: the hit box must be where the art differs from the cover" % c)


func test_the_sheet_is_drawn_in_palette_colours() -> void:
	# The corners lift over the audited paper. Every opaque texel INSIDE a
	# corner rect (the only part ever drawn) must be a palette entry; the one
	# that is not is reported by value so it can be repainted in Aseprite.
	var img := corners.texture.get_image()
	var off: Dictionary = {}
	for r: Rect2i in JournalPageCorners.CORNER_RECTS:
		for y: int in range(r.position.y, r.end.y):
			for x: int in range(r.position.x, r.end.x):
				var px := img.get_pixel(x, y)
				if px.a <= 0.0:
					continue
				var c := Color(px.r, px.g, px.b, 1.0)
				if not Palette.COLORS.has(c):
					off[c.to_html(false)] = int(off.get(c.to_html(false), 0)) + 1
	# Known at authoring (2026-09-12, the larger corners): A39870, the crease
	# shadow, 796 texels across the four. Pending a repaint; anything ELSE
	# off-palette is a regression.
	var known := {"a39870": 796}
	assert_eq(off, known, "BookPageCrease.png: off-palette texels by colour (only the known one)")


# --- the sequence ------------------------------------------------------------

func test_the_book_is_one_sequence_run_spread_first() -> void:
	assert_eq(journal.page_index(), 0, "the run spread is page 0")
	assert_eq(journal.page_count(), 5, "eight species is four pairs, after the run spread")
	assert_false(journal.turn_page(-1), "no page before the calendar")
	assert_true(journal.turn_page(1))
	assert_eq(journal.spread(), &"bitacora")
	assert_eq(journal.page_index(), 1)
	assert_eq(journal.species(), StringName(journal.browsable_species()[0]))
	assert_true(journal.turn_page(-1), "and back to the calendar")
	assert_eq(journal.spread(), &"run")
	journal.show_species(StringName(journal.browsable_species()[7]))
	assert_eq(journal.page_index(), 4, "the last species is on the last page")
	assert_false(journal.turn_page(1), "no page after the last pair")
	assert_true(journal.turn_page(-3))
	assert_eq(journal.page_index(), 1)


func test_only_corners_with_a_page_to_turn_to_are_enabled() -> void:
	for c: int in [JournalPageCorners.Corner.TL, JournalPageCorners.Corner.BL]:
		assert_false(corners.is_enabled(c), "no left corner on the calendar")
	for c: int in [JournalPageCorners.Corner.TR, JournalPageCorners.Corner.BR]:
		assert_true(corners.is_enabled(c), "the calendar turns forward")
	journal.show_species(StringName(journal.browsable_species()[7]))
	for c: int in [JournalPageCorners.Corner.TL, JournalPageCorners.Corner.BL]:
		assert_true(corners.is_enabled(c))
	for c: int in [JournalPageCorners.Corner.TR, JournalPageCorners.Corner.BR]:
		assert_false(corners.is_enabled(c), "no right corner on the last pair")


func test_a_closed_bitacora_has_no_corner() -> void:
	var codex := FloraCodex.new()
	add_child_autofree(codex)
	var j := JOURNAL_SCENE.instantiate() as FieldJournal
	add_child_autofree(j)
	await get_tree().process_frame
	var c := j.get_node("Book/BookArt/PageCorners") as JournalPageCorners
	assert_eq(j.page_count(), 1, "the calendar is the whole book")
	assert_false(j.turn_page(1))
	assert_eq(j.spread(), &"run")
	c.hover(Vector2(415, 60))
	assert_eq(c.shown(), -1, "nothing after the calendar, so the right edge lifts nothing")
	codex.discover(&"frailejon")
	# (The node re-reads the REAL pointer on a find; a test cannot place it.)
	c.hover(Vector2(415, 60))
	assert_eq(c.shown(), JournalPageCorners.Corner.TR, "the find enables the corner")
	assert_eq(j.page_count(), 2)
	assert_true(j.turn_page(1))
	assert_eq(j.spread(), &"bitacora")
	assert_eq(j.species(), &"frailejon")
	assert_false(j.turn_page(1))
	assert_true(j.turn_page(-1))
	assert_eq(j.spread(), &"run")


# --- hover and click -------------------------------------------------------------

func test_the_zones_are_strips_along_the_pages_outer_edges() -> void:
	# Each corner's zone: from the cover's rim to REACH_PX inside the page's
	# outer edge, over that corner's half of the page. The four tile the two
	# strips; each holds its own corner's ink.
	var tl := corners.zone_rect(JournalPageCorners.Corner.TL)
	var bl := corners.zone_rect(JournalPageCorners.Corner.BL)
	var tr := corners.zone_rect(JournalPageCorners.Corner.TR)
	var br := corners.zone_rect(JournalPageCorners.Corner.BR)
	assert_eq(tl.position.x, 48, "the left strip starts at the cover's rim")
	assert_eq(tl.end.x, maxi(60 + JournalPageCorners.REACH_PX,
			JournalPageCorners.CORNER_RECTS[0].end.x), "and reaches into the left page, or to the corner's ink")
	assert_eq(tr.position.x, mini(420 - JournalPageCorners.REACH_PX,
			JournalPageCorners.CORNER_RECTS[1].position.x))
	assert_eq(tr.end.x, 432, "the right strip ends at the cover's rim")
	assert_eq(tl.position.y, 21)
	assert_eq(tl.end.y, bl.position.y, "top and bottom halves meet")
	assert_eq(bl.end.y, 252)
	assert_eq(tr.position.y, tl.position.y)
	assert_eq(br.end.y, bl.end.y)
	for c: int in 4:
		assert_true(corners.zone_rect(c).encloses(JournalPageCorners.CORNER_RECTS[c]),
			"corner %d's ink lies in its own zone" % c)


func test_hovering_the_outer_edge_lifts_the_corner_on_that_half() -> void:
	assert_eq(corners.shown(), -1, "nothing lifts until the pointer comes near")
	corners.hover(_far())
	assert_eq(corners.shown(), -1, "the middle of the book is nobody's zone")
	# Anywhere along the right page's outer edge, not only at the corner.
	corners.hover(Vector2(415, 60))
	assert_eq(corners.shown(), JournalPageCorners.Corner.TR, "top half of the edge: the top corner")
	corners.hover(Vector2(415, 200))
	assert_eq(corners.shown(), JournalPageCorners.Corner.BR, "bottom half: the bottom corner")
	corners.hover(Vector2(corners.zone_rect(JournalPageCorners.Corner.BR).position.x - 1, 200))
	assert_eq(corners.shown(), -1, "further into the page, it drops")
	corners.hover(Vector2(428, 240))
	assert_eq(corners.shown(), JournalPageCorners.Corner.BR, "the cover's rim counts")
	# A disabled corner never lifts, however close.
	corners.hover(_centre(JournalPageCorners.Corner.TL))
	assert_eq(corners.shown(), -1, "no page before the calendar, so no left corner")
	corners.hover(Vector2(65, 200))
	assert_eq(corners.shown(), -1)
	journal.show_species(&"frailejon")
	corners.hover(Vector2(65, 200))
	assert_eq(corners.shown(), JournalPageCorners.Corner.BL, "on a species page the left edge turns back")


func test_a_tab_is_never_a_corner() -> void:
	# The tab sits inside a strip (x 421..431 on the right, 49..58 on the
	# left, both between the page's edge and the cover's rim); a point on it
	# lifts nothing and a lifted corner does not take its click.
	var tab_centre: Vector2 = edge.position + Rect2(edge.tab_rect(edge.shown())).get_center()
	assert_true(corners.zone_rect(JournalPageCorners.Corner.TR).has_point(Vector2i(tab_centre)) 		or corners.zone_rect(JournalPageCorners.Corner.BR).has_point(Vector2i(tab_centre)),
		"on the run spread the bitácora tab lies in a right-hand zone")
	assert_true(edge._has_point(tab_centre - edge.position), "and on the tab")
	corners.hover(tab_centre)
	assert_eq(corners.shown(), -1)
	var beside := Vector2(410, tab_centre.y)
	assert_true(corners.zone_rect(JournalPageCorners.Corner.TR).has_point(Vector2i(beside)) \
		or corners.zone_rect(JournalPageCorners.Corner.BR).has_point(Vector2i(beside)),
		"the paper beside the tab is inside a corner's strip")
	corners.hover(beside)
	assert_eq(corners.shown(), -1, "but it is the tab's reach: no corner lifts there")
	corners.hover(Vector2(415, 60))
	assert_eq(corners.shown(), JournalPageCorners.Corner.TR)
	assert_false(corners._has_point(tab_centre), "the tab keeps its click")
	assert_false(corners._has_point(beside), "and so does its reach")
	assert_false(corners.handle_click(tab_centre))
	# And the same on the left, where the run tab hangs on the bitácora.
	journal.show_species(&"frailejon")
	var run_centre: Vector2 = edge.position + Rect2(edge.tab_rect(edge.shown())).get_center()
	assert_true(corners.zone_rect(JournalPageCorners.Corner.TL).has_point(Vector2i(run_centre)) 		or corners.zone_rect(JournalPageCorners.Corner.BL).has_point(Vector2i(run_centre)),
		"on the bitácora the run tab lies in a left-hand zone")
	corners.hover(run_centre)
	assert_eq(corners.shown(), -1)
	corners.hover(Vector2(65, 60))
	assert_eq(corners.shown(), JournalPageCorners.Corner.TL)
	assert_false(corners._has_point(run_centre), "the tab keeps its click")


func test_only_the_shown_corners_zone_takes_input() -> void:
	assert_eq(corners.mouse_filter, Control.MOUSE_FILTER_STOP)
	assert_false(corners._has_point(_centre(JournalPageCorners.Corner.BR)),
		"a corner that is not lifted is not a button")
	corners.hover(Vector2(415, 200))
	assert_eq(corners.shown(), JournalPageCorners.Corner.BR)
	assert_true(corners._has_point(Vector2(415, 200)), "where the hover reacted, the click lands")
	assert_true(corners._has_point(_centre(JournalPageCorners.Corner.BR)))
	assert_true(corners._has_point(Vector2(405, 190)), "anywhere in the lifted corner's zone")
	assert_false(corners._has_point(_far()), "the paper falls through")
	assert_false(corners._has_point(_centre(JournalPageCorners.Corner.TR)),
		"and so does a corner that is not the lifted one")
	# Authored after the tabs and the shop hit box, so it is picked first.
	assert_gt(corners.get_index(), edge.get_index())
	assert_gt(corners.get_index(), journal.get_node("Book/BookArt/BookHit").get_index())


func test_a_lifted_corner_draws_over_the_polaroids() -> void:
	# The polaroids are floats parented to BookArt at runtime; they must be
	# inserted after the pages, not appended, or they draw over the corners
	# (and the tabs, and the tooltip).
	journal.show_species(&"frailejon")
	var book_art := journal.get_node("Book/BookArt") as Control
	var pages := book_art.get_node("Pages")
	var floats: int = 0
	for child: Node in book_art.get_children():
		if child is JournalPhotoFloat:
			floats += 1
			assert_gt(child.get_index(), pages.get_index(), "a float sits over the paper")
			assert_lt(child.get_index(), corners.get_index(), "and under the page corners")
			assert_lt(child.get_index(), edge.get_index(), "and under the tabs")
	assert_eq(floats, 8, "two pages, two polaroids each, photo and frame")


func test_clicking_a_corner_turns_the_page_and_the_corner_follows() -> void:
	corners.hover(Vector2(412, 180))
	assert_eq(corners.shown(), JournalPageCorners.Corner.BR)
	assert_true(corners.handle_click(Vector2(412, 180)), "a click where it lifted, not only on the ink")
	assert_eq(journal.spread(), &"bitacora")
	assert_eq(journal.page_index(), 1)
	assert_eq(corners.shown(), JournalPageCorners.Corner.BR,
		"the pointer is still on the corner and there is a page after this one")
	assert_true(corners.handle_click(_centre(JournalPageCorners.Corner.BR)))
	assert_eq(journal.page_index(), 2)
	corners.hover(_centre(JournalPageCorners.Corner.TL))
	assert_true(corners.handle_click(_centre(JournalPageCorners.Corner.TL)))
	assert_eq(journal.page_index(), 1)
	assert_true(corners.handle_click(_centre(JournalPageCorners.Corner.TL)))
	assert_eq(journal.spread(), &"run", "back to the calendar")
	assert_eq(corners.shown(), -1, "and there the left corner has nowhere to go")
	assert_false(corners.handle_click(_centre(JournalPageCorners.Corner.TL)))
	assert_false(corners.handle_click(_far()), "the paper is not a button")


func test_the_last_pair_drops_its_right_corner_after_the_turn() -> void:
	journal.show_species(StringName(journal.browsable_species()[4]))
	corners.hover(_centre(JournalPageCorners.Corner.TR))
	assert_eq(corners.shown(), JournalPageCorners.Corner.TR)
	assert_true(corners.handle_click(_centre(JournalPageCorners.Corner.TR)))
	assert_eq(journal.page_index(), 4)
	assert_eq(corners.shown(), -1, "the last pair has no page after it")


func test_the_tabs_still_jump_and_the_corners_follow() -> void:
	journal.show_species(StringName(journal.browsable_species()[7]))
	corners.hover(_centre(JournalPageCorners.Corner.BL))
	assert_eq(corners.shown(), JournalPageCorners.Corner.BL)
	assert_true(edge.handle_click(Rect2(edge.tab_rect(edge.tab(&"run"))).get_center()))
	assert_eq(journal.spread(), &"run")
	assert_eq(corners.shown(), -1, "on the calendar the left corner has nowhere to go")
	assert_true(journal.shows(StringName(journal.browsable_species()[7])),
		"the tab does not lose the page the book was open to")
