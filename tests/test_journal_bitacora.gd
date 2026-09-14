extends GutTest

# ===========================================================================
# The bitacora spread: one species per page, two per spread, and the fore-edge
# tabs that turn to it.
# ===========================================================================
# Three kinds of guard here:
#   - SPREAD MECHANICS: the two spreads share the pages, and switching is
#     `visible` on every tagged section (FieldJournal.show_spread). A section
#     that forgot its tag would print through the other spread. The book turns
#     in PAIRS, and the field note rotates per showing.
#   - THE WARP CONTRACT, per species and per locale: every run of ink on both
#     pages nests in its 18-row block. The field note WRAPS, so a Spanish fact
#     one line longer than the English is a seam in one locale only — hence
#     both, and every fact, not just the one showing.
#   - COPY BUDGETS: the species name must be drawable in the title face and fit
#     the page; every phrase must fit the column; every note must end above the
#     page's foot. draw_string clips silently, so only measurement catches it.

const JOURNAL_SCENE: PackedScene = preload("res://scenes/ui/field_journal.tscn")
const LOCALES: Array[String] = ["en_GB", "es_CO"]
const BLOCK: int = 18
const PAGE_ROWS: int = 213

var journal: FieldJournal
var left: JournalSpeciesPlate
var right: JournalSpeciesPlate
var edge: JournalForeEdge
var _previous_locale: String


func before_each() -> void:
	_previous_locale = TranslationServer.get_locale()
	journal = JOURNAL_SCENE.instantiate() as FieldJournal
	add_child_autofree(journal)
	left = journal.get_node("%SpeciesPlateLeft") as JournalSpeciesPlate
	right = journal.get_node("%SpeciesPlateRight") as JournalSpeciesPlate
	edge = journal.get_node("Book/BookArt/ForeEdge") as JournalForeEdge


func after_each() -> void:
	TranslationServer.set_locale(_previous_locale)
	get_tree().paused = false


func _species_ids() -> PackedStringArray:
	var out := PackedStringArray()
	for data: PlantObjectData in journal.bitacora_species:
		out.append(String(data.id))
	return out


func _sections_tagged(tag: StringName) -> Array[Control]:
	var out: Array[Control] = []
	for c: Control in journal._sections:
		if StringName(c.get(&"spread")) == tag:
			out.append(c)
	return out


# Every run of ink a section draws must cross no more seams than its own
# height forces. Same helper as test_journal_pages.gd — same contract.
func _assert_ink_is_clean(section: Control, context: String = "") -> void:
	for run: Dictionary in section.call(&"ink_runs"):
		var top: int = run["top"]
		var h: int = run["height"]
		assert_true(JournalBlocks.is_clean(top, h, BLOCK),
			"%s: %s inks %d rows at %d, spanning %d blocks where %d would do%s"
				% [section.name, run["name"], h, top,
					JournalBlocks.spans(top, h, BLOCK),
					JournalBlocks.min_spans(h, BLOCK), context])


# Show `id` on the LEFT plate directly, whatever pair it would fall in, so a
# layout check sees every species on both page widths.
func _put(plate: JournalSpeciesPlate, id: String, fact: int = 0) -> void:
	for data: PlantObjectData in journal.bitacora_species:
		if String(data.id) == id:
			plate.set_species(data, fact)
			return
	fail_test("no species %s" % id)


# --- spread mechanics ---------------------------------------------------------

func test_the_book_opens_on_the_run_spread() -> void:
	assert_eq(journal.spread(), &"run")
	assert_false(left.visible, "the plates are not on the run spread")
	assert_false(right.visible)
	for c: Control in _sections_tagged(&"run"):
		assert_true(c.visible, "%s belongs to the run spread" % c.name)


func test_show_spread_flips_every_tagged_section() -> void:
	journal.show_spread(&"bitacora")
	assert_eq(journal.spread(), &"bitacora")
	for c: Control in _sections_tagged(&"run"):
		assert_false(c.visible, "%s must leave with the run spread" % c.name)
	for c: Control in _sections_tagged(&"bitacora"):
		assert_true(c.visible, "%s must arrive with the bitacora" % c.name)
	journal.show_spread(&"run")
	for c: Control in _sections_tagged(&"run"):
		assert_true(c.visible, "%s must come back" % c.name)


func test_every_page_section_carries_a_spread_tag() -> void:
	# The season slit is beside the pages, not inside one, and it belongs to the
	# run spread too — it used to hang over the species name.
	var expected := ["RunCalendar", "SpeciesPlateLeft", "Resources", "KnownBuildings",
			"KnownFlora", "SpeciesPlateRight", "SeasonGaugeHolder"]
	var names: Array[String] = []
	for c: Control in journal._sections:
		names.append(c.name)
	for n: String in expected:
		assert_has(names, n, "%s must be a tagged section" % n)


func test_the_bitacora_species_are_the_eight_plants() -> void:
	assert_eq(journal.bitacora_species.size(), 8)
	var ids := _species_ids()
	for id: String in ["frailejon", "espeletia_barclayana", "espeletia_hartwegiana",
			"hypericum", "arcytophyllum", "calamagrostis", "chusquea", "cortaderia"]:
		assert_has(ids, id)
	assert_eq(journal.browsable_species(), ids,
		"without a codex, everything is browsable, in authored order")


func test_the_spread_shows_two_species_a_pair_at_a_time() -> void:
	var ids := _species_ids()
	assert_true(journal.show_species(StringName(ids[3])))
	assert_eq(journal.spread(), &"bitacora")
	# ids[3] is at an odd position: it lands on the RIGHT page of the pair
	# starting at ids[2].
	assert_eq(journal.species(), StringName(ids[2]))
	assert_eq(journal.page_species(), [StringName(ids[2]), StringName(ids[3])])
	assert_true(journal.shows(StringName(ids[3])))
	assert_eq(left.species().id, StringName(ids[2]))
	assert_eq(right.species().id, StringName(ids[3]))


func test_show_species_refuses_what_is_not_a_species() -> void:
	assert_false(journal.show_species(&"fence"))
	assert_false(journal.show_species(&""))
	assert_eq(journal.spread(), &"run", "a refusal turns no page")


func test_next_and_prev_turn_in_pairs_and_wrap() -> void:
	var ids := _species_ids()
	journal.show_species(StringName(ids[0]))
	journal.next_species()
	assert_eq(journal.species(), StringName(ids[2]))
	journal.prev_species()
	assert_eq(journal.species(), StringName(ids[0]))
	journal.prev_species()
	assert_eq(journal.species(), StringName(ids[6]), "prev from the first pair wraps to the last")
	journal.next_species()
	assert_eq(journal.species(), StringName(ids[0]), "and next from the last wraps back")


func test_an_odd_ring_leaves_the_last_right_page_blank() -> void:
	var codex := FloraCodex.new()
	add_child_autofree(codex)
	var j := JOURNAL_SCENE.instantiate() as FieldJournal
	add_child_autofree(j)
	await get_tree().process_frame
	codex.discover(&"chusquea")
	codex.discover(&"frailejon")
	codex.discover(&"hypericum")
	# Authored (sheet-row) order: frailejon, chusquea, hypericum -> pairs
	# (frailejon, chusquea) and (hypericum, blank).
	j.show_species(&"hypericum")
	assert_eq(j.page_species(), [&"hypericum", &""], "three species: the second pair is one page")
	var r := j.get_node("%SpeciesPlateRight") as JournalSpeciesPlate
	assert_true(r.is_empty())
	assert_eq(r.ink_runs().size(), 0, "a blank page prints nothing, not the empty copy")
	assert_eq(j.page_count(), 3, "three species is two pairs, after the run spread")
	j.show_species(&"chusquea")
	assert_eq(j.page_species(), [&"frailejon", &"chusquea"], "chusquea is on the right of the first pair")


func test_the_spread_survives_closing_the_book() -> void:
	journal.show_species(&"hypericum")
	journal.open()
	journal.close()
	assert_eq(journal.spread(), &"bitacora", "a book stays where you left it")
	assert_true(journal.shows(&"hypericum"))


func test_the_field_note_rotates_per_showing() -> void:
	var ids := _species_ids()
	journal.show_species(StringName(ids[0]))
	var first: String = left.note_text()
	assert_eq(left.fact_index, 0, "the first showing prints the first fact")
	journal.show_species(StringName(ids[0]))
	assert_eq(left.fact_index, 1, "the second showing prints the second")
	assert_ne(left.note_text(), first)
	# Opening the book on the bitacora is a showing too.
	journal.open()
	assert_eq(left.fact_index, 2)
	journal.close()
	# And it wraps round the species' facts.
	journal.show_species(StringName(ids[0]))
	assert_eq(left.note_text(), first)
	# The right page's species has its own cursor.
	assert_eq(right.fact_index, 3, "the right page has been shown the same number of times")


func test_the_bitacora_is_closed_until_something_is_identified() -> void:
	var codex := FloraCodex.new()
	add_child_autofree(codex)
	var j := JOURNAL_SCENE.instantiate() as FieldJournal
	add_child_autofree(j)
	await get_tree().process_frame
	var e := j.get_node("Book/BookArt/ForeEdge") as JournalForeEdge
	assert_eq(j.browsable_species().size(), 0)
	assert_false(j.has_bitacora())
	assert_null(e.shown(), "nothing identified: no tab")
	assert_eq(j.page_count(), 1, "and no page after the calendar")
	assert_false(j.turn_page(1))
	j.show_spread(&"bitacora")
	assert_eq(j.spread(), &"run", "the turn is refused")
	assert_eq(j.species(), &"")
	var hits: int = 0
	for x: int in range(0, 480, 2):
		for y: int in range(0, 270, 2):
			if e._has_point(Vector2(x, y)):
				hits += 1
	assert_eq(hits, 0, "with no tab, the fore-edge takes no click anywhere")
	# The first find opens it: the tab appears and the turn works.
	var changes: Array[int] = []
	j.browsable_changed.connect(func() -> void: changes.append(1))
	codex.discover(&"cortaderia")
	assert_eq(changes.size(), 1, "the tab and the corners hear the find")
	assert_true(j.has_bitacora())
	assert_not_null(e.shown())
	assert_eq(e.shown().spread, &"bitacora")
	assert_eq(j.page_count(), 2)
	j.show_spread(&"bitacora")
	assert_eq(j.spread(), &"bitacora")
	assert_eq(j.species(), &"cortaderia")
	var l := j.get_node("%SpeciesPlateLeft") as JournalSpeciesPlate
	var r := j.get_node("%SpeciesPlateRight") as JournalSpeciesPlate
	assert_false(l.is_empty())
	assert_true(r.is_empty(), "one species: the right page is blank")
	assert_eq(r.ink_runs().size(), 0)
	assert_false(j.is_readable(&"frailejon"), "unidentified: nothing to read")
	assert_true(j.is_readable(&"cortaderia"))
	assert_false(j.show_species(&"frailejon"), "unidentified species do not open")


func test_the_book_turns_back_when_the_bitacora_empties_under_it() -> void:
	# The codex clears at season 0; a book open on the bitácora then has
	# nothing to show and goes back to the run spread.
	var codex := FloraCodex.new()
	add_child_autofree(codex)
	var j := JOURNAL_SCENE.instantiate() as FieldJournal
	add_child_autofree(j)
	await get_tree().process_frame
	codex.discover(&"frailejon")
	j.show_spread(&"bitacora")
	assert_eq(j.spread(), &"bitacora")
	codex._known.clear()
	j._revalidate_species()
	assert_eq(j.spread(), &"run")
	assert_eq(j.species(), &"")
	assert_null((j.get_node("Book/BookArt/ForeEdge") as JournalForeEdge).shown())


# --- the warp contract, per species and per locale ---------------------------

func test_both_plates_sit_on_the_block_grid() -> void:
	for c: Control in [left, right]:
		assert_eq(int(c.position.y) % BLOCK, 0, "%s must start on a block" % c.name)
		assert_eq(c.get(&"block_px"), BLOCK)


func test_every_species_inks_clean_on_both_pages_in_both_locales() -> void:
	# Every FACT, not only the one showing: `fact_index` walks them.
	for locale: String in LOCALES:
		TranslationServer.set_locale(locale)
		for id: String in _species_ids():
			for plate: JournalSpeciesPlate in [left, right]:
				for fact: int in 3:
					_put(plate, id, fact)
					_assert_ink_is_clean(plate, " (%s, %s, fact %d)" % [id, locale, fact])


func test_the_name_is_a_title_face_heading_in_its_own_block() -> void:
	# The journal's title face, as on every other heading, set with
	# JournalTitle's inset: a 17-row line box from row 1, one block.
	assert_eq(left.active_name_font().resource_path,
		"res://assets/fonts/FantasticBoogaloo-GDlq.ttf")
	assert_eq(left.name_font_size, 16)
	assert_eq(left.name_row_px(), BLOCK)
	assert_eq(left.font_size % 8, 0, "Tiny5's native em is 8")
	_put(left, "frailejon")
	var run: Dictionary = left.ink_runs()[0]
	assert_eq(run["name"], "name")
	assert_eq(run["top"], JournalTitle.INK_INSET_PX)
	assert_eq(run["height"], 17)
	assert_eq(JournalBlocks.spans(run["top"], run["height"], BLOCK), 1)


func test_two_data_lines_fill_one_block() -> void:
	assert_eq(left.line_px(), 9, "Tiny5 at 8 is a 9-row line")
	assert_eq(2 * left.line_px(), BLOCK)
	var f := left.active_font()
	assert_eq(f.get_height(left.font_size), 9.0,
		"draw_multiline_string advances by get_height, which must be the line box")
	assert_eq(left.subtitle_top_px, BLOCK, "the binomial is block 1's first line")
	assert_eq(left.stages_bottom_px, left.quadrants_top_px - 2,
		"the stages stand two rows clear of the quadrants")
	assert_eq(left.quadrants_top_px % BLOCK, 0, "the quadrants start on a block")
	for q: int in 4:
		assert_eq(left.text_top_px(q) % left.line_px(), 0,
			"quadrant %d's text starts on the 9-row line grid" % q)


# --- copy budgets ----------------------------------------------------------------

func test_species_names_draw_in_the_title_face_and_fit_the_page() -> void:
	# Accents included: "frailejón", "paja de páramo" — the title face must
	# have every glyph, which is what ruled Eggmode out for this heading.
	var f := left.active_name_font()
	for locale: String in LOCALES:
		TranslationServer.set_locale(locale)
		for data: PlantObjectData in journal.bitacora_species:
			_put(left, String(data.id))
			var text: String = left.name_text()
			assert_eq(text, JournalTitle.cased(tr(String(data.name_key))),
				"%s/%s: the name is cased like a heading" % [data.id, locale])
			assert_ne(text, text.to_lower(), "%s/%s: a capital somewhere" % [data.id, locale])
			for ch: String in text:
				assert_true(f.has_char(ch.unicode_at(0)),
					"%s/%s: '%s' has no glyph in the title face" % [data.id, locale, ch])
			var w: float = f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1,
					left.name_font_size).x
			assert_lt(w, right.size.x - 8.0,
				"%s/%s: '%s' is %d px wide on a %d px page"
					% [data.id, locale, text, int(w), int(right.size.x)])


func test_every_centred_line_fits_the_page() -> void:
	var f := left.active_font()
	for locale: String in LOCALES:
		TranslationServer.set_locale(locale)
		for id: String in _species_ids():
			_put(right, id)
			for line: Dictionary in right.text_lines():
				var face: Font = line.get("font", f)
				var w: float = face.get_string_size(line["text"],
						HORIZONTAL_ALIGNMENT_LEFT, -1, line["size"]).x
				assert_lt(w, right.size.x - 8.0,
					"%s/%s: '%s' runs off the page" % [id, locale, line["text"]])


func test_every_phrase_is_colon_free_and_the_facts_fit_their_quadrant() -> void:
	# The facts are phrases ("suelo seco"), not "label: value" pairs. In a
	# 72-px quadrant column a phrase may wrap; the six together must fit the
	# quadrant's eight lines, both locales, both page widths.
	for locale: String in LOCALES:
		TranslationServer.set_locale(locale)
		for id: String in _species_ids():
			for plate: JournalSpeciesPlate in [left, right]:
				_put(plate, id)
				var facts := plate.fact_lines()
				assert_eq(facts.size(), 6,
					"%s: height, altitude, water, feet, growth, where" % id)
				for text: String in facts:
					assert_false(text.contains(":"), "%s/%s: '%s' has a colon" % [id, locale, text])
				assert_true(facts[0].to_lower().begins_with(tr("JOURNAL_VAL_HEIGHT").substr(0, 5)),
					"%s/%s: the height line says 'up to'" % [id, locale])
				for text: String in facts:
					var first := text.substr(0, 1)
					assert_true(first == first.to_upper(),
						"%s/%s: '%s' must start in sentence case" % [id, locale, text])
					assert_eq(text.substr(1), text.substr(1).to_lower().replace(
							"chingaza", "Chingaza").replace("guerrero", "Guerrero").replace("nevados", "Nevados"),
						"%s/%s: '%s' — only the first letter and the mountains are capitals" % [id, locale, text])
				for note: String in plate.all_note_texts():
					var first := note.substr(0, 1)
					assert_true(first == first.to_upper(), "%s/%s: the note is sentence case" % [id, locale])
				assert_false(" ".join(facts).contains("token") or " ".join(facts).contains("ficha"),
					"%s/%s: no price on a notebook page" % [id, locale])
				var q: int = plate.quadrant_of(JournalSpeciesPlate.Kind.FACTS)
				assert_lte(plate.facts_lines(), plate.text_lines_max(q),
					"%s/%s: %d fact lines in a %d-line quadrant on %s"
						% [id, locale, plate.facts_lines(), plate.text_lines_max(q), plate.name])


func test_every_field_note_fits_its_quadrant() -> void:
	# Every fact of every species on BOTH page widths, both locales: the note
	# wraps in a 72-px column and has eight lines to the quadrant's foot.
	for locale: String in LOCALES:
		TranslationServer.set_locale(locale)
		for id: String in _species_ids():
			for plate: JournalSpeciesPlate in [left, right]:
				_put(plate, id)
				var texts := plate.all_note_texts()
				assert_between(texts.size(), 2, 3, "%s: two or three facts" % id)
				var q: int = plate.quadrant_of(JournalSpeciesPlate.Kind.NOTE)
				for text: String in texts:
					var n: int = plate.note_lines(text)
					assert_gt(n, 0)
					assert_lte(n, plate.text_lines_max(q),
						"%s/%s: '%s' is %d lines in a %d-line quadrant on %s"
							% [id, locale, text, n, plate.text_lines_max(q), plate.name])
					assert_lte(plate.text_top_px(q) + n * plate.line_px(), PAGE_ROWS,
						"%s/%s: '%s' runs off the page" % [id, locale, text])


func test_fact_keys_resolve() -> void:
	for data: PlantObjectData in journal.bitacora_species:
		for key: String in data.fact_keys:
			assert_ne(tr(key), key, "%s: %s is not in the CSV" % [data.id, key])
			assert_true(key.begins_with("NARRATIVE_"),
				"%s: field notes are prose, and NARRATIVE_ is what exempts them from lowercase"
					% key)
		assert_false(data.scientific_name.is_empty(), "%s has no binomial" % data.id)
		assert_false(data.family.is_empty(), "%s has no family" % data.id)
		assert_gt(data.height_m, 0.0, "%s has no height" % data.id)


# --- the plate's art ------------------------------------------------------------

func test_the_polaroids_float_over_the_book_and_the_stages_are_ink() -> void:
	# The photographs are NOT children of the plate: a picture inside the
	# page's 157x231 SubViewport is pixel art by construction. Each floats
	# over BookArt at window resolution, linear-filtered, from a 4x texture,
	# bent by the page's own warp, with a polaroid frame floating on top of
	# it. The stages stay in the page, inked.
	var book_art := journal.get_node("Book/BookArt") as Control
	for id: String in _species_ids():
		_put(left, id)
		var data := left.species()
		assert_not_null(data.photo, "%s has no herbarium sheet" % id)
		assert_not_null(data.photo_live, "%s has no field photo" % id)
		for tex: Texture2D in [data.photo, data.photo_live]:
			assert_eq(tex.get_size(), Vector2(216, 216), "%s: 4x the 54x54 window" % id)
			assert_true(tex.resource_path.ends_with("_palette.png"),
				"%s: the palette-snapped copy is the one shown" % id)
		assert_true(data.photo_live.resource_path.ends_with("_live_palette.png"))
		var inked := 0
		for child in left.get_children():
			if not (child is TextureRect):
				continue
			var tr_ := child as TextureRect
			assert_ne(tr_.texture, data.photo, "%s: the photo must not be drawn in the page" % id)
			assert_ne(tr_.texture, data.photo_live)
			inked += 1
			var mat := tr_.material as ShaderMaterial
			assert_not_null(mat, "%s: a growth stage must go through the ink" % id)
			assert_same(mat.shader, left.ink_material.shader)
		assert_eq(inked, data.variants.size(), "%s: four stages" % id)
		var photos := left.photo_floats()
		var frames := left.frame_floats()
		assert_eq(photos.size(), 2, "%s: two photographs float" % id)
		assert_eq(frames.size(), 2, "%s: and two frames" % id)
		var prs := left.photo_rects()
		var frrs := left.frame_rects()
		assert_eq(prs.size(), 2)
		assert_eq(frrs.size(), 2)
		var page := journal.get_node("Book/BookArt/Pages/PageLeft") as Control
		var content := left.get_parent() as Control
		var origin := Vector2i(page.position) + Vector2i(content.position)
		for i: int in 2:
			var f := photos[i]
			var fr := frames[i]
			assert_same(f.get_parent(), book_art, "over the book, beside the tooltip and the tabs")
			assert_gt(fr.get_index(), f.get_index(), "the frame draws over the photograph")
			assert_same(f.texture, [data.photo, data.photo_live][i])
			assert_same(fr.texture, left.frame_texture)
			assert_eq(f.texture_filter, CanvasItem.TEXTURE_FILTER_LINEAR, "a photograph, not pixel art")
			assert_eq(fr.texture_filter, CanvasItem.TEXTURE_FILTER_NEAREST, "the frame IS pixel art")
			for fl: JournalPhotoFloat in [f, fr]:
				assert_eq((fl.material as ShaderMaterial).shader.resource_path,
					"res://assets/shaders/photo_warp.gdshader", "bent with the page")
			assert_eq(prs[i].size, Vector2i(54, 54), "the window is what the page lays out")
			assert_eq(frrs[i].size, Vector2i(68, 79), "the frame sprite at 1:1")
			assert_eq(prs[i].position, frrs[i].position + Vector2i(7, 7),
				"the photo sits in the frame's window")
			assert_eq(JournalBlocks.spans(frrs[i].position.y, frrs[i].size.y, BLOCK),
				JournalBlocks.min_spans(frrs[i].size.y, BLOCK),
				"the frame spans the fewest blocks it can")
			# The floats' unpadded rects are the page rects carried into book space.
			assert_eq(f.photo_rect_in_book(), Rect2i(origin + prs[i].position, prs[i].size))
			assert_eq(fr.photo_rect_in_book(), Rect2i(origin + frrs[i].position, frrs[i].size))


func test_the_photo_floats_follow_the_plate() -> void:
	journal.show_species(&"frailejon")
	for f: JournalPhotoFloat in left.photo_floats() + left.frame_floats() + right.photo_floats():
		assert_true(f.visible, "on the bitacora the polaroids show")
	journal.show_spread(&"run")
	for f: JournalPhotoFloat in left.photo_floats() + left.frame_floats() + right.photo_floats():
		assert_false(f.visible, "and leave with the spread")
	journal.show_spread(&"bitacora")
	assert_true(left.photo_floats()[0].visible)


func test_the_page_is_cut_in_four_and_each_quadrant_holds_one_thing() -> void:
	# Four 78x79 quadrants from row 54: a polaroid fills its quadrant exactly,
	# and the two rows reach row 212 of 213. The arrangement is drawn per
	# species — stable for one, different between them — with the note always
	# on the bottom row.
	var seen: Dictionary = {}
	for plate: JournalSpeciesPlate in [left, right]:
		for id: String in _species_ids():
			_put(plate, id)
			var w: int = int(plate.size.x)
			for q: int in 4:
				var r := plate.quadrant_rect(q)
				assert_eq(r.size.y, 79, "a quadrant row is the frame's height")
				assert_eq(r.size.x, w / 2 if q % 2 == 0 else w - w / 2)
				assert_eq(r.position.x, 0 if q % 2 == 0 else w / 2)
				assert_eq(r.position.y, 54 + 79 * (q / 2))
			assert_lte(plate.quadrant_rect(3).end.y, PAGE_ROWS, "the bottom row stays on the page")
			var arr := plate.arrangement()
			assert_eq(arr.size(), 4)
			for kind: JournalSpeciesPlate.Kind in [JournalSpeciesPlate.Kind.FACTS,
					JournalSpeciesPlate.Kind.SHEET, JournalSpeciesPlate.Kind.FIELD,
					JournalSpeciesPlate.Kind.NOTE]:
				assert_eq(arr.count(kind), 1, "%s: %d appears once" % [id, kind])
			seen[str(arr)] = true
			assert_gte(plate.quadrant_of(JournalSpeciesPlate.Kind.NOTE), 2,
				"%s: the field note is on the bottom row" % id)
			# The polaroids fill their quadrants; the text areas are the others.
			var qs := plate.photo_quadrants()
			assert_eq(qs, [plate.quadrant_of(JournalSpeciesPlate.Kind.SHEET),
					plate.quadrant_of(JournalSpeciesPlate.Kind.FIELD)] as Array[int])
			var frrs := plate.frame_rects()
			for i: int in 2:
				var cell := plate.quadrant_rect(qs[i])
				assert_true(cell.encloses(frrs[i]), "%s: polaroid %d inside its quadrant" % [id, i])
				assert_eq(frrs[i].position.y, cell.position.y, "flush with the quadrant's top")
				assert_eq(frrs[i].position.x - cell.position.x,
					cell.end.x - frrs[i].end.x - (cell.size.x - 68) % 2, "centred across it")
			for kind: JournalSpeciesPlate.Kind in [JournalSpeciesPlate.Kind.FACTS,
					JournalSpeciesPlate.Kind.NOTE]:
				var q: int = plate.quadrant_of(kind)
				var cell := plate.quadrant_rect(q)
				assert_gte(plate.text_top_px(q), cell.position.y)
				assert_eq(plate.text_lines_max(q), 8, "%s: eight lines in quadrant %d" % [id, q])
				assert_lte(plate.text_top_px(q) + 8 * plate.line_px(), cell.end.y + 1)
				assert_eq(plate.text_left_px(q), cell.position.x + 4)
				assert_eq(plate.text_width_px(q), cell.size.x - 6)
	assert_gt(seen.size(), 1, "eight species are not all pasted up the same way")
	# Stable: the same species on the same page twice.
	_put(left, "frailejon")
	var a := left.arrangement()
	_put(left, "chusquea")
	_put(left, "frailejon")
	assert_eq(left.arrangement(), a)


func test_the_stages_stand_in_one_row_under_the_binomial() -> void:
	# Packed by INK, 4 columns apart, centred, stood on row 52 as requested —
	# except where a stage's ink cannot be clean there: E. barclayana's third
	# stage is exactly 18 rows, legal only on a block, so its whole row stands
	# on 54 (JournalBlocks.snap_top on the row). The tallest ink of any species
	# clears the binomial's line box, and no row stands below the quadrants.
	for id: String in _species_ids():
		_put(left, id)
		var bottoms: Array[int] = []
		var tops: Array[int] = []
		for run: Dictionary in left.ink_runs():
			if String(run["name"]).begins_with("stage"):
				bottoms.append(int(run["top"]) + int(run["height"]))
				tops.append(int(run["top"]))
		var stand: int = 54 if id == "espeletia_barclayana" else 52
		assert_eq(bottoms, [stand, stand, stand, stand] as Array[int],
			"%s: every stage stands on row %d" % [id, stand])
		assert_eq(left.stage_stand_px(), stand)
		assert_lte(stand, left.quadrants_top_px)
		for t: int in tops:
			assert_gte(t, left.subtitle_top_px + left.line_px(),
				"%s: a stage reaches row %d, into the binomial's line" % [id, t])
		var lefts := left.stage_ink_lefts()
		assert_eq(lefts.size(), 4)
		var data := left.species()
		var total: int = 0
		for i: int in 4:
			var w: int = int(JournalKnownSet.ink_rect(data.variants[i]).size.x)
			if i > 0:
				assert_eq(lefts[i], lefts[i - 1] + int(JournalKnownSet.ink_rect(data.variants[i - 1]).size.x) + 4,
					"%s: stage %d is 4 columns after stage %d's ink" % [id, i, i - 1])
			total += w
		total += 3 * 4
		assert_eq(lefts[0], (int(left.size.x) - total) / 2, "%s: the row is centred" % id)
		assert_lt(total, 120, "%s: the row is compact" % id)


# --- the fore-edge tabs ----------------------------------------------------------

func test_the_tab_hangs_one_texel_off_the_page_on_the_side_its_spread_lies() -> void:
	var pages := journal.get_node("Book/BookArt/Pages")
	assert_gt(edge.get_index(), pages.get_index(),
		"the tab draws after the pages, so it is on top of them")
	assert_eq(edge.position, Vector2.ZERO, "the node is BookArt's own space")
	assert_eq(edge.mouse_filter, Control.MOUSE_FILTER_STOP)
	for extended: bool in [false, true]:
		var bit := edge.tab_rect(edge.tab(&"bitacora"), extended)
		var run := edge.tab_rect(edge.tab(&"run"), extended)
		assert_eq(bit.position.x, 421, "the right page ends at x 420; one texel of air")
		assert_eq(run.end.x, 59, "the left page starts at x 60; one texel of air")
		assert_eq(bit.size.x, edge.frame(extended).size.x, "as wide as its frame")
		assert_eq(run.size.x, edge.frame(extended).size.x)
		for r: Rect2i in [bit, run]:
			var above: int = r.position.y - edge.PAGE_TOP_Y
			var below: int = edge.PAGE_BOTTOM_Y - r.end.y
			assert_true(absi(above - below) <= 1, "centred on the page's rows: %d above, %d below" % [above, below])
	assert_gt(edge.frame(true).size.x, edge.frame(false).size.x, "extended sticks out further")
	assert_false(edge.is_extended(), "at rest the tab is tucked")


func test_only_the_way_to_the_other_spread_shows() -> void:
	assert_eq(journal.spread(), &"run")
	assert_eq(edge.shown().spread, &"bitacora", "on the run spread the tab leads forward")
	assert_eq(edge.shown().side, JournalForeEdge.Side.RIGHT)
	var bit := Rect2(edge.tab_rect(edge.tab(&"bitacora"))).get_center()
	var run := Rect2(edge.tab_rect(edge.tab(&"run"))).get_center()
	assert_true(edge._has_point(bit))
	assert_false(edge._has_point(run), "the run tab is not there to click")
	assert_false(edge._has_point(Vector2(2.0, 2.0)), "the paper is not a button")
	assert_true(edge.handle_click(bit))
	assert_eq(journal.spread(), &"bitacora")
	assert_eq(edge.shown().spread, &"run", "on the bitácora the tab leads back")
	assert_eq(edge.shown().side, JournalForeEdge.Side.LEFT)
	assert_true(edge._has_point(run))
	assert_false(edge._has_point(bit))
	assert_false(edge.handle_click(bit))
	assert_true(edge.handle_click(run))
	assert_eq(journal.spread(), &"run")


func test_the_tab_extends_under_the_pointer_and_tucks_when_it_leaves() -> void:
	var t := edge.shown()
	var tucked := Rect2(edge.tab_rect(t, false))
	var extended := Rect2(edge.tab_rect(t, true))
	var tip := Vector2(extended.end.x - 1.5, tucked.get_center().y)
	assert_false(tucked.has_point(tip), "the tip is only on the extended tab")
	assert_false(edge._has_point(tip), "tucked: the tip is not a button")
	edge.hover(tucked.get_center())
	assert_true(edge.is_extended())
	assert_true(edge._has_point(tip), "extended: the tab is hit as drawn")
	edge.hover(tip)
	assert_true(edge.is_extended(), "it stays out while the pointer is on the wider tab")
	edge.hover(Vector2(extended.end.x + 2, tip.y))
	assert_false(edge.is_extended(), "and tucks when the pointer leaves")
	edge.hover(tucked.get_center())
	assert_true(edge.handle_click(tip), "a click on the extended tab turns the book")
	assert_eq(journal.spread(), &"bitacora")
	assert_false(edge.is_extended(), "the new tab is on the other side, not under the pointer")


func test_the_paper_beside_the_tab_is_the_tabs() -> void:
	var t := edge.shown()
	var tab := Rect2(edge.tab_rect(t, false))
	var reach := Rect2(edge.reach_rect(t, false))
	assert_eq(reach.position.x, 420.0 - edge.REACH_PX, "the reach goes REACH_PX into the right page")
	assert_eq(reach.end.x, tab.end.x, "and no further out than the tab")
	assert_eq(reach.position.y, tab.position.y, "over the tab's own rows")
	assert_eq(reach.size.y, tab.size.y)
	assert_eq(edge.REACH_PX, JournalPageCorners.REACH_PX, "the reach is the corners' strip")
	var beside := Vector2(410, tab.get_center().y)
	assert_true(edge._has_point(beside), "on the paper beside the tab")
	edge.hover(beside)
	assert_true(edge.is_extended(), "the tab comes out for a pointer near it")
	assert_true(edge.handle_click(beside), "and a click there turns the book")
	assert_eq(journal.spread(), &"bitacora")
	# On the bitácora the run tab hangs on the left, and reaches into the left page.
	var run := Rect2(edge.tab_rect(edge.shown(), false))
	var run_reach := Rect2(edge.reach_rect(edge.shown(), false))
	assert_eq(run_reach.end.x, 60.0 + edge.REACH_PX)
	assert_eq(run_reach.position.x, run.position.x)
	assert_false(edge._has_point(Vector2(70, run.position.y - 4)), "above the tab's rows the strip is the corner's")
	assert_true(edge._has_point(Vector2(70, run.get_center().y)))


func test_the_tab_stretches_to_its_label_in_both_locales() -> void:
	for locale: String in LOCALES:
		TranslationServer.set_locale(locale)
		for t: JournalForeEdge.Tab in edge.tabs():
			var along: float = edge.label_length_px(t.key)
			var r := edge.tab_rect(t)
			assert_eq(r.size.y, ceili(along) + 2 * edge.LABEL_PAD_PX,
				"%s/%s: '%s' is %d px along a %d px tab"
					% [t.key, locale, tr(t.key), int(along), r.size.y])
			assert_gte(r.size.y, edge.CAP_TOP_ROWS + edge.CAP_BOTTOM_ROWS + 1,
				"room for both caps and a middle")
			assert_lte(r.end.y, 252, "%s/%s: the tab ends above the page's foot" % [t.key, locale])


func test_the_tab_sprite_and_the_plates_are_authored_palette_colours() -> void:
	for c: Color in [edge.INK, left.text_color, right.text_color]:
		assert_true(Palette.COLORS.has(c), "%s is not a palette entry" % c.to_html(false))
		assert_eq(c.a, 1.0, "journal ink is opaque")
	var img := edge.texture.get_image()
	assert_eq(img.get_size(), Vector2i(16, 16), "BookTab.png: two 8-row frames stacked")
	for fr: Rect2i in [edge.FRAME_TUCKED, edge.FRAME_EXTENDED]:
		assert_eq(fr.size.y, edge.CAP_TOP_ROWS + edge.CAP_BOTTOM_ROWS + 3,
			"a two-row lit cap and a three-row shadowed cap round a three-row middle")
		assert_eq(img.get_region(fr).get_used_rect(), Rect2i(Vector2i.ZERO, fr.size),
			"the frame is its own ink, %s" % fr)
		# The middle rows are all alike, which is what lets them stretch.
		var first: int = fr.position.y + edge.CAP_TOP_ROWS
		for y: int in range(first + 1, fr.end.y - edge.CAP_BOTTOM_ROWS):
			for x: int in range(fr.position.x, fr.end.x):
				assert_eq(img.get_pixel(x, y), img.get_pixel(x, first),
					"row %d differs from the first middle row at x %d" % [y, x])
	for y: int in img.get_height():
		for x: int in img.get_width():
			var px := img.get_pixel(x, y)
			if px.a <= 0.0:
				continue
			assert_true(Palette.COLORS.has(Color(px.r, px.g, px.b, 1.0)),
				"BookTab.png (%d, %d) %s is off palette" % [x, y, px.to_html(false)])
