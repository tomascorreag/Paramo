extends GutTest

# Guards the field journal's authored page geometry, the way test_ui_theme guards
# the theme. Everything here is a number traced off Book.png (cream = 254,225,184,
# extents inclusive): the pages are at x 60..216 / 264..419, y 30..242 at a page's
# outer edge and y 21..251 at the spine, so each edge sweeps 9px toward the spine.
#
# The warp shader spends exactly that 9px of vertical slack, which is why these
# have to agree: if a SubViewport stops being (content height + 2 * amplitude), the
# shader starts sampling outside its own texture and the page content clips. The
# alignment ITSELF is checked by rendering — scripts/tools/preview_page_warp.gd —
# because it needs a GPU; this file checks the numbers that feed it.

const JOURNAL_SCENE: PackedScene = preload("res://scenes/ui/field_journal.tscn")

# Book-space rects of the two pages: x, y, width, height (the padded viewport).
const PAGE_RECTS := {
	"PageLeft": Rect2i(60, 21, 157, 231),
	"PageRight": Rect2i(264, 21, 156, 231),
}
## Vertical slack the SubViewport carries above AND below its content. It is the
## FULL sweep of the drawn page edge, and stays 9 whatever the content actually
## follows: the shader has no clamp, so the padding must bound the largest
## amplitude the page could ever be tuned to, not the one it is tuned to today.
const PADDING_PX := 9.0
## What the CONTENT follows, retuned down from the full 9. The warp's stair has one
## step per texel of amplitude and a step landing mid-glyph shears the letter, so
## this trades page-curl fidelity against sheared type: 9 cuts ~1 glyph in 4 on a
## line, 5 about 1 in 7, 0 none at all. 5 is the authored compromise.
const CONTENT_AMPLITUDE_PX := 5.0
## Native em per face, keyed by resource path. MEASURED off the glyph outlines
## (fraction of points landing on a upem/em grid), not read off the specimen or
## guessed from unitsPerEm: Tiny5 is 99.9% on a 128-unit grid of 1024 (8px), Eggmode
## 99.9% on 64 (16px) against only 49% on 128. A size that is not a multiple of the
## em duplicates ~one pixel row per em at a different place in every glyph, and the
## line staggers — which reads as the typeface having character, not as a bug.
const FONT_EM_PX := {
	"res://assets/fonts/Tiny5-Regular.ttf": 8,
	"res://assets/fonts/Eggmode-Pd8g.ttf": 16,
}
## Body copy is the theme's Tiny5; Eggmode is reserved for TITLES.
const BODY_FONT := "res://assets/fonts/Tiny5-Regular.ttf"
const TITLE_FONT := "res://assets/fonts/Eggmode-Pd8g.ttf"
## Every sprite printed on a page goes through this, so it can only ever emit a
## colour one of the four ink ramps contains.
const INK_SHADER := "res://assets/shaders/journal_ink.gdshader"

var journal: CanvasLayer


func before_each() -> void:
	journal = JOURNAL_SCENE.instantiate()
	add_child_autofree(journal)


# The calendar tests drive SeasonManager directly (it is an autoload, so it
# outlives the journal instance); put the run spine back where the other suites
# expect to find it.
func after_each() -> void:
	SeasonManager.phase = SeasonManager.Phase.IDLE
	SeasonManager.season_index = 0
	SeasonManager._day_at_season_start = 0
	SeasonManager.days_per_year = 16
	TimeManager.day_count = 0
	TimeManager.time_of_day = 0.0


func _page(name_: String) -> PageWarp:
	return journal.get_node("Book/BookArt/Pages/" + name_) as PageWarp


func test_book_art_is_the_native_book_size() -> void:
	# 480x270 = Book.png = the logical resolution. It exists so that
	# window/stretch/aspect="expand" (a wider-than-480 logical rect on a non-16:9
	# window) can't slide the page rects off the centred art.
	var art := journal.get_node("Book/BookArt") as Control
	assert_eq(art.size, Vector2(480, 270))
	assert_eq(art.anchor_left, 0.5, "BookArt must be centred, not left-anchored")
	assert_eq(art.anchor_right, 0.5)


func test_book_parks_fully_below_any_viewport() -> void:
	# The park offset must clear BookArt's half-height (135) below the bottom
	# edge at ANY logical viewport height — the old `offset = vp.y` park only
	# hid the book when vp.y >= 270.
	var vp_h: float = journal.get_viewport().get_visible_rect().size.y
	assert_gte(journal._park_offset(), vp_h * 0.5 + 135.0)


func test_pages_sit_on_the_measured_page_rects() -> void:
	for name_: String in PAGE_RECTS:
		var rect: Rect2i = PAGE_RECTS[name_]
		var page := _page(name_)
		assert_not_null(page, name_ + " missing")
		assert_eq(page.position, Vector2(rect.position), name_ + " position")
		var sub := page.get_node("SubViewport") as SubViewport
		assert_eq(sub.size, rect.size, name_ + " viewport size")


func test_content_is_inset_by_the_full_edge_sweep() -> void:
	for name_: String in PAGE_RECTS:
		var page := _page(name_)
		var sub := page.get_node("SubViewport") as SubViewport
		var content := sub.get_node("Content") as Control
		assert_eq(content.position.y, PADDING_PX, name_ + " content top inset")
		assert_eq(
			content.size.y, sub.size.y - 2.0 * PADDING_PX,
			name_ + " content height must leave the full sweep top AND bottom")
		assert_eq(content.size.x, float(sub.size.x), name_ + " content spans the page")


func test_warp_amplitudes_fit_the_slack() -> void:
	# The amplitude must FIT the padding, not equal it: the shader clamps nothing, so
	# anything larger samples outside the texture and the page content clips. Smaller
	# is always safe, and is what the retune to 5 relies on.
	for name_: String in PAGE_RECTS:
		var page := _page(name_)
		assert_eq(page.amplitude_top_px, -CONTENT_AMPLITUDE_PX, name_ + " top amplitude")
		assert_eq(
			page.amplitude_bottom_px, CONTENT_AMPLITUDE_PX, name_ + " bottom amplitude")
		assert_lte(
			absf(page.amplitude_top_px), PADDING_PX, name_ + " top exceeds the slack")
		assert_lte(
			absf(page.amplitude_bottom_px), PADDING_PX, name_ + " bottom exceeds the slack")


func test_column_blocks_match_the_body_advance() -> void:
	# The companion to row_block_px, for the other axis: the rounded offset is a stair
	# and a step through a glyph shears it. Snapping the sampled column to Tiny5's 4px
	# advance puts the steps between letters wherever the run is in phase, so page text
	# has to START on that grid too.
	for name_: String in PAGE_RECTS:
		var page := _page(name_)
		assert_eq(page.col_block_px, 4.0, name_ + " column block")
		for label: Label in _labels_on(page):
			assert_eq(
				fmod(label.position.x, page.col_block_px), 0.0,
				"%s/%s: offset_left must land on the column grid" % [name_, label.name])


func test_right_page_is_the_mirrored_one() -> void:
	# One shared curve pair drives both pages; the right page's spine is on its LEFT.
	assert_false(_page("PageLeft").flip_x)
	assert_true(_page("PageRight").flip_x)
	for prop: StringName in [&"curve_top", &"curve_bottom"]:
		assert_same(
			_page("PageLeft").get(prop), _page("PageRight").get(prop),
			"%s must be the SAME resource on both pages, not a per-page clone" % prop)


func test_page_text_is_in_phase_with_the_row_blocks() -> void:
	# row_block_px quantises from Content's top. Text starting off that grid makes
	# every line straddle two blocks, which is exactly the artefact it removes.
	# Every Label on a page has to obey this, not just the run readout.
	for name_: String in PAGE_RECTS:
		var page := _page(name_)
		var block: float = page.row_block_px
		assert_gt(block, 0.0, name_ + " should quantise to its line height")
		for label: Label in _labels_on(page):
			# The block need not BE one line — it must be a whole number of them, so
			# that lines nest inside blocks instead of straddling seams. The journal
			# runs 9px Tiny5 lines in 18px blocks: two body lines per block.
			var line_h: int = label.get_line_height()
			assert_gt(line_h, 0, "%s/%s: no line height" % [name_, label.name])
			assert_eq(
				fmod(block, float(line_h)), 0.0,
				"%s/%s: row_block_px must be a whole number of text lines"
					% [name_, label.name])
			assert_eq(
				fmod(label.position.y, float(line_h)), 0.0,
				"%s/%s: offset_top must land on the line grid" % [name_, label.name])


func _labels_on(page: SubViewportContainer) -> Array[Label]:
	var out: Array[Label] = []
	for child in page.get_node("SubViewport/Content").get_children():
		if child is Label:
			out.append(child as Label)
	return out


func test_body_copy_is_tiny5_and_titles_are_the_written_face() -> void:
	# The split is the point: the handwritten face is for TITLES only, because it is
	# only legal at 16px and a page of 16px handwriting does not fit. Everything a
	# player reads for DATA stays on Tiny5 at 8. Every label carries its override
	# explicitly — theme propagation does not cross a SubViewport.
	# Loops over DIRECT Label children of a page's Content. There are NONE at all
	# now — every piece of type on both pages is drawn (RunCalendar,
	# JournalKnownSet, JournalResources), because the written face cannot be a Label
	# on an 18-texel block (18 % 16 != 0, see the row-block test below). So this is
	# the guard for the next label somebody authors straight onto a page, not a
	# check on current content; the real body copy is asserted through the drawn
	# sections' own faces.
	for name_: String in PAGE_RECTS:
		for label: Label in _labels_on(_page(name_)):
			assert_eq(
				label.get_theme_font(&"font").resource_path, BODY_FONT,
				"%s/%s: page body copy must be Tiny5" % [name_, label.name])

	var res := _resources()
	assert_eq(res.active_font().resource_path, BODY_FONT, "resources counts")
	assert_eq(res.active_header_font().resource_path, TITLE_FONT, "resources title")

	var cal := _cal()
	assert_eq(cal.active_font().resource_path, BODY_FONT, "calendar body")
	assert_eq(cal.active_header_font().resource_path, TITLE_FONT, "calendar title")
	assert_ne(
		cal.active_font(), cal.active_header_font(),
		"the title must not fall back to the body face")


func test_journal_lines_nest_in_the_warp_blocks() -> void:
	# Both faces print on the same page, so BOTH have to nest in the block or one of
	# them straddles a seam: Tiny5 at 8 is a 9-row line (two per 18px block), Eggmode
	# at 16 is 16 rows and its row rounds up to a whole block.
	var cal := _cal()
	var block: int = int(_page("PageRight").row_block_px)
	var body_line: int = int(cal.active_font().get_height(cal.font_size))
	assert_gt(body_line, 0, "body line height")
	assert_eq(block % body_line, 0, "the block must be a whole number of body lines")
	assert_eq(cal.header_row_px() % block, 0, "the title row must be a whole block")
	assert_eq(cal.text_row_px() % block, 0, "the day-number row must be a whole block")


func test_journal_type_is_on_the_faces_native_em() -> void:
	# The artefact this catches is subtle and easy to misread as the typeface's own
	# character: at a size that is not a multiple of the em, the rasteriser duplicates
	# roughly one pixel row per em, at a different place in every glyph, and the line
	# of text staggers. It looks hand-lettered. It is not — it is the wrong size.
	var used: Array = []  # [font path, size, where]
	for name_: String in PAGE_RECTS:
		for label: Label in _labels_on(_page(name_)):
			# &"font_size", not &"font": the theme item holding a Label's size is named
			# font_size, and asking for &"font" silently returns the THEME default (8)
			# instead of the label's override — which makes a %8 check pass on anything.
			used.append([label.get_theme_font(&"font").resource_path,
				label.get_theme_font_size(&"font_size"), label.name])
	var cal := _cal()
	used.append([cal.active_font().resource_path, cal.font_size, "calendar body"])
	used.append([cal.active_header_font().resource_path, cal.header_font_size, "calendar title"])
	var res := _resources()
	used.append([res.active_font().resource_path, res.font_size, "resources counts"])
	used.append([res.active_header_font().resource_path, res.header_font_size, "resources title"])
	for section: JournalKnownSet in _sections():
		used.append([section.active_header_font().resource_path,
			section.header_font_size, "known set/" + section.name])
	assert_gt(used.size(), 3,
		"expected the calendar, the resources row AND the known sets")
	for entry: Array in used:
		assert_true(FONT_EM_PX.has(entry[0]), "unknown face %s at %s" % [entry[0], entry[2]])
		var em: int = FONT_EM_PX.get(entry[0], 8)
		assert_eq(
			int(entry[1]) % em, 0,
			"%s: %d is not a multiple of %s's %dpx em"
				% [entry[2], entry[1], String(entry[0]).get_file(), em])


func _cal() -> RunCalendar:
	return _page("PageLeft").get_node("SubViewport/Content/RunCalendar") as RunCalendar


func _resources() -> JournalResources:
	return _page("PageRight").get_node("SubViewport/Content/Resources") as JournalResources


func test_resources_are_printed_on_the_right_page() -> void:
	# Stock written INTO the book, so it must go through the page's viewport and bend
	# with the paper — the opposite of the season wheel, which PageSlit keeps out of
	# any viewport precisely so it stays flat.
	#
	# It lives on the RIGHT page (it used to be `Inventory` at the foot of the left
	# one) because the left page is the RUN — the season slot and the calendar — and
	# stock is the state of the moment, not a record of the run.
	var res := _resources()
	assert_gt(res.resource_ids.size(), 0, "the page should carry a supplies row")
	assert_eq(
		res.icons.size(), res.resource_ids.size(),
		"every resource needs its glyph")
	for tex: Texture2D in res.icons:
		assert_not_null(tex, "a resource glyph failed to resolve")
		# The FULL-SIZE icons, unlike the calendar's: here the glyph and its count
		# sit side by side, so the row's 18-texel block need only hold the taller of
		# the two rather than their sum. This is the page's headline figure.
		assert_eq(tex.get_size(), Vector2(16, 16),
			"resource glyphs must be the full-size 16x16 icons")
	assert_eq(res.font_size, 16, "the supplies counts are set large, at 2x Tiny5's em")


func test_resources_row_sits_inside_one_warp_block() -> void:
	# The row is glyph over count; split across a block seam, the shader would shear
	# the glyph away from its number.
	var block: int = int(_page("PageRight").row_block_px)
	var res := _resources()
	assert_eq(res.block_px, block, "the section must quantise like its page")
	assert_eq(int(res.position.y) % block, 0, "the section must start on a block")
	assert_eq(res.header_row_px() % block, 0, "the heading must be whole blocks")
	assert_eq(
		res.section_height_px(), res.header_row_px() + block,
		"the supplies row must be exactly one block tall")


func test_resources_counts_go_through_the_ink() -> void:
	# The glyphs are UI art (the water icon is blues, the visitor icon a flat black
	# silhouette) and would look pasted on without the ramp. The material must sit on
	# the child ink layer, NOT on the section: a CanvasItem's material covers
	# everything it draws, and the heading and counts must stay flat ink.
	var res := _resources()
	assert_not_null(res.ink_material, "the supplies glyphs need the ink shader")
	assert_eq(
		res.ink_material.shader.resource_path, INK_SHADER,
		"supplies glyphs must go through journal_ink.gdshader")
	assert_null(res.material, "the ink must not be on the section itself")


func test_gauge_is_unwarped_and_drawn_last() -> void:
	# The season wheel is an object sitting in a slot cut into the book, not
	# something printed on the paper: it must not go through a page's viewport, and
	# it must draw over both pages.
	var pages := journal.get_node("Book/BookArt/Pages")
	var gauge := _slit()
	assert_eq(gauge.get_parent(), pages, "gauge must stay out of the page viewports")
	assert_eq(
		gauge.get_index(), pages.get_child_count() - 1,
		"gauge must be the last child of Pages so it draws over the pages")


func _slit() -> PageSlit:
	return journal.get_node("Book/BookArt/Pages/SeasonGaugeHolder") as PageSlit


func test_slit_is_padded_by_the_warp_amplitude() -> void:
	# Same contract as a page's Content: the band sweeps `amplitude` texels and the
	# shader has no clamp, so anything less than that above and below it crops the
	# slot near the spine.
	var slit := _slit()
	assert_not_null(slit, "SeasonGaugeHolder must be a PageSlit")
	assert_eq(slit.slit_inset_px, PADDING_PX, "slit inset must cover the full sweep")
	var sub := slit.get_node("SubViewport") as SubViewport
	assert_eq(
		Vector2(sub.size), slit.size,
		"the container must be exactly its viewport — the shader's UV assumes it")
	assert_gt(slit.visible_height_px(), 0.0, "the band must have some height left")


func test_slit_reads_its_curl_off_the_page_it_cuts() -> void:
	# The point of PageSlit taking a `page` rather than its own curve exports: one
	# edit to page_curl_*.tres re-bends the printed text and re-cuts the slot.
	var slit := _slit()
	var page := _page("PageLeft")
	assert_same(slit.page, page, "the slot must point at the page it is cut into")
	# ...and it has to sit over that page, or the u-range it derives is nonsense.
	assert_between(
		slit.position.x, page.position.x, page.position.x + page.size.x - slit.size.x,
		"the slot must sit within the page's horizontal span")


func _sections() -> Array[JournalKnownSet]:
	var out: Array[JournalKnownSet] = []
	for child in _page("PageRight").get_node("SubViewport/Content").get_children():
		if child is JournalKnownSet:
			out.append(child as JournalKnownSet)
	return out


func test_right_page_carries_the_known_sets() -> void:
	# The right page's whole job after the calendar moved off it. Both sections must
	# be there, and each must actually have resolved something to show — an empty one
	# renders as a bare title, which reads as a layout bug rather than a missing slot.
	var sections := _sections()
	assert_eq(sections.size(), 2, "expected a buildings section and a flora section")
	var keys: Array[String] = []
	for s: JournalKnownSet in sections:
		keys.append(s.title)
		assert_gt(
			s.swatch_textures().size(), 0,
			"%s resolved no swatches" % s.title)
	# `title` holds a translation KEY now, not the printed text — the section
	# heading is drawn as tr(title) so it follows the player's language.
	assert_has(keys, "JOURNAL_KNOWN_BUILDINGS")
	assert_has(keys, "JOURNAL_KNOWN_FLORA")


func test_known_set_tile_kinds_resolve_through_the_tileset() -> void:
	# The point of taking TileSlots NAMES rather than atlas coords: a renamed or
	# unpainted slot has to fail here, not render a silently empty swatch on the
	# page. Bridges and ladders exist ONLY as tiles, so this is their only guard.
	for s: JournalKnownSet in _sections():
		if s.tile_kinds.is_empty():
			continue
		assert_not_null(s.tileset, "%s declares tile_kinds but no tileset" % s.title)
		var index := TileKindIndex.new(s.tileset, s.source_id)
		for kind: String in s.tile_kinds:
			assert_true(
				index.has(StringName(kind)),
				"%s: '%s' is not painted on source %d of %s"
					% [s.title, kind, s.source_id, s.tileset.resource_path])
		# get_tile_texture_region must return the tile's FULL art. These are 1x2
		# tiles on a 32x16 atlas, so a swatch that comes back 32x16 means the
		# size_in_atlas was dropped somewhere and the art is cut in half.
		for tex: Texture2D in s.swatch_textures():
			assert_gt(tex.get_size().y, 16.0, "%s: swatch is a half tile" % s.title)


func test_known_sets_are_in_phase_with_the_row_blocks() -> void:
	# Same contract as the calendar: the warp translates each block rigidly, so a
	# section starting off the grid puts every title and swatch across a seam.
	var block: float = _page("PageRight").row_block_px
	for s: JournalKnownSet in _sections():
		assert_eq(
			fmod(s.position.y, block), 0.0,
			"%s: top must be a multiple of row_block_px" % s.title)
		assert_eq(
			float(s.block_px), block,
			"%s: block_px must track the page it is printed on" % s.title)
		assert_eq(
			fmod(float(s.cell_size.y), block), 0.0,
			"%s: swatch cell height must be a multiple of row_block_px" % s.title)
		assert_eq(
			s.header_row_px() % int(block), 0,
			"%s: the title row must be a whole block" % s.title)


func test_known_set_swatches_carry_the_ink_material() -> void:
	# The swatches are the only place world art is printed on the paper. Unshaded
	# they read as live game sprites pasted into the notebook, which is exactly what
	# the ink ramp exists to prevent — so a missing material is a visual regression
	# no geometry test would catch.
	#
	# Each swatch carries its OWN duplicate of the material, not the section's
	# instance, because hover and lock drive the `dim` uniform per entry — one
	# shared material would fade and brighten the whole section together. The
	# duplicate is shallow, so the shader and all four ramp textures are still the
	# same objects and retuning the ink stays a single resource edit. That is what
	# this asserts: same SHADER, not same material.
	for s: JournalKnownSet in _sections():
		assert_not_null(s.ink_material, "%s: no ink material" % s.title)
		# Every TextureRect the section owns. That is the swatches and nothing
		# else now — the price coin used to be one, until the price left the page
		# for the tag it is charged by (JournalTooltip).
		var inked := 0
		for child in s.get_children():
			if child is TextureRect:
				inked += 1
				var mat := (child as TextureRect).material as ShaderMaterial
				assert_not_null(
					mat, "%s: a swatch is not going through the ink shader" % s.title)
				assert_same(
					mat.shader, s.ink_material.shader,
					"%s: a swatch is on the wrong shader" % s.title)
				assert_eq(
					(child as TextureRect).texture_filter,
					CanvasItem.TEXTURE_FILTER_NEAREST,
					"%s: swatches must stay hard-edged" % s.title)
		assert_eq(
			s._swatches.size(), s.swatch_textures().size(),
			"%s: a resolved texture did not get a node" % s.title)
		assert_eq(
			inked, s._swatches.size(),
			"%s: an inked child that is not a swatch" % s.title)


## The four hue-family ramps journal_ink.gdshader picks between, by shader uniform.
const INK_RAMPS := {
	"ramp_warm": "res://resources/ui/journal_ink_warm.tres",
	"ramp_green": "res://resources/ui/journal_ink_green.tres",
	"ramp_cool": "res://resources/ui/journal_ink_cool.tres",
	"ramp_neutral": "res://resources/ui/journal_ink_neutral.tres",
}
## No ink stop may be darker than this. The ramps are deliberately low contrast:
## their shadows are LIFTED off near-black so a swatch reads as drawn on the paper
## rather than as a hole punched through it. P07 (0.212) and P29/P30 (0.215 and
## below) are the entries this exists to keep out.
const MIN_INK_LUMINANCE := 0.24


func test_ink_ramps_are_palette_legal() -> void:
	# The reason these are CONSTANT-interpolation Gradients rather than a desaturate:
	# every colour they can emit must be one of the 33 palette2 entries (see the
	# Color Palette rule in CLAUDE.md). This checks the SAMPLED image, not the
	# authored stops — flipping interpolation_mode back to LINEAR would leave the
	# stops palette-legal while putting blends of them on the page.
	for uniform_: String in INK_RAMPS:
		var ramp: GradientTexture1D = load(INK_RAMPS[uniform_])
		assert_not_null(ramp, "%s ramp must exist" % uniform_)
		assert_eq(
			ramp.gradient.interpolation_mode, Gradient.GRADIENT_INTERPOLATE_CONSTANT,
			"%s: LINEAR would emit blends between stops, which are in no palette"
				% uniform_)
		var img := ramp.get_image()
		for x: int in range(img.get_width()):
			var c := img.get_pixel(x, 0)
			assert_true(
				_is_palette_color(c),
				"%s texel %d is %s, which is not a palette2 entry"
					% [uniform_, x, c.to_html(false)])


func test_ink_ramps_are_low_contrast() -> void:
	# "Low contrast" is a property of the AUTHORED stops, not of anything in the
	# shader, so this is the only place it can be guarded. Swapping a stop for a
	# darker palette entry is a one-character edit that would silently reintroduce
	# the punchy look the ramps were retuned away from.
	for uniform_: String in INK_RAMPS:
		var ramp: GradientTexture1D = load(INK_RAMPS[uniform_])
		var darkest := 1.0
		for c: Color in ramp.gradient.colors:
			darkest = minf(darkest, _luminance(c))
		assert_gte(
			darkest, MIN_INK_LUMINANCE,
			"%s: darkest stop is at luminance %.3f — shadows must stay lifted"
				% [uniform_, darkest])


func test_ink_material_binds_every_ramp() -> void:
	# The shader samples all four unconditionally. An unbound sampler reads as black
	# in GL Compatibility, so a missing binding would blacken whichever hue family it
	# owns — and only that family, which is easy to mistake for art being wrong.
	var mat: ShaderMaterial = null
	for s: JournalKnownSet in _sections():
		mat = s.ink_material
		break
	assert_not_null(mat, "no section carries an ink material")
	for uniform_: String in INK_RAMPS:
		var bound: Texture2D = mat.get_shader_parameter(uniform_)
		assert_not_null(bound, "ink material does not bind %s" % uniform_)
		assert_eq(
			bound.resource_path, INK_RAMPS[uniform_],
			"%s is bound to the wrong ramp" % uniform_)


# Rec.601, matching the LUMA constant in journal_ink.gdshader.
func _luminance(c: Color) -> float:
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b


## Every colour the four ink ramps can emit — the journal's WHOLE palette. Derived,
## never listed: adding a stop widens what the pages may use, and nothing else can.
func _journal_palette() -> Array[Color]:
	var out: Array[Color] = []
	for path: String in INK_RAMPS.values():
		var ramp: GradientTexture1D = load(path)
		for c: Color in ramp.gradient.colors:
			out.append(c)
	return out


func _in_journal_palette(c: Color) -> bool:
	for p: Color in _journal_palette():
		if is_equal_approx(p.r, c.r) and is_equal_approx(p.g, c.g) \
				and is_equal_approx(p.b, c.b):
			return true
	return false


func test_every_authored_journal_colour_is_in_the_reduced_palette() -> void:
	# The pages are held to a REDUCED palette — the ink ramps' stops — not merely to
	# palette2. Swatches get there through the shader; type and drawn marks cannot,
	# so their colours are authored and this is the only thing checking them.
	#
	# RGB only: alpha is free (the calendar's rules are P06 at 0.7), exactly as the
	# project-wide palette rule has it.
	#
	# Deliberately NOT covered: the season disc and the slot cut around it. The disc
	# is an object mounted BEHIND the book rather than ink on the page, and the cut's
	# shadow is the paper's own edge — neither is drawn ON the page. `Dim` is the
	# scrim behind the whole book, also not on a page.
	#
	# Nor the day STAMP — it has its own test below. It is the one mark on either
	# page that is deliberately not ink.
	var cal := _cal()
	var checked: Array[Array] = [
		[cal.rule_color, "RunCalendar.rule_color"],
		[cal.border_color, "RunCalendar.border_color"],
		[cal.text_color, "RunCalendar.text_color"],
	]
	for s: JournalKnownSet in _sections():
		checked.append([s.text_color, "%s.text_color" % s.title])
	checked.append([_resources().text_color, "JournalResources.text_color"])
	for name_: String in PAGE_RECTS:
		for label: Label in _labels_on(_page(name_)):
			checked.append([
				label.get_theme_color(&"font_color"),
				"%s/%s font_color" % [name_, label.name]])

	# 3 calendar colours (rule, border, text — the stamp has its own test) + one
	# per known set + the supplies row.
	assert_gte(checked.size(), 6,
		"expected the calendar, both known sets and the supplies row")
	for entry: Array in checked:
		var c: Color = entry[0]
		assert_true(
			_in_journal_palette(c),
			"%s is %s, which is not one of the ink ramps' stops"
				% [entry[1], c.to_html(false)])
		# Ink must be OPAQUE, which is stricter than the project-wide palette rule
		# ("alpha is free"). A legal colour at alpha < 1 composites against the cream
		# page into one that is in no palette: the calendar's rules were P06 at 0.7,
		# and every rule pixel rendered as 9D7967 — a colour nobody authored and no
		# RGB check would ever catch. Where a lighter rule is wanted, pick a lighter
		# palette entry (the rules are P10 now), not a lower alpha.
		assert_eq(
			c.a, 1.0,
			"%s has alpha %.2f — semi-transparent ink composites off-palette"
				% [entry[1], c.a])


func test_the_day_stamp_is_red_and_opaque_but_not_ink() -> void:
	# The ONE exception to the reduced-palette rule above, and it is a deliberate
	# one: a stamp is not written on the paper, it is pressed onto it, and the mark
	# only does its job if it reads as a different medium from the record it sits
	# on. So it is held to palette2 and to full opacity, but NOT to the ink ramps —
	# none of whose stops is a red (the ramps are low-contrast by authoring, and
	# their reddest entries are within a shade of the brown body text).
	#
	# If the stamp ever becomes ink, delete this and put stamp_color back in the
	# list above rather than widening a ramp to accommodate it.
	var c: Color = _cal().stamp_color
	assert_true(_is_palette_color(c),
		"the stamp is %s, which is not a palette2 entry" % c.to_html(false))
	assert_eq(c.a, 1.0, "the stamp is pressed at full strength")
	assert_false(_in_journal_palette(c),
		"the stamp must NOT be an ink ramp stop — that is the whole point of it")
	assert_gt(c.r, maxf(c.g, c.b), "the stamp reads as red")


func test_calendar_stat_glyphs_go_through_the_ink() -> void:
	# The day-stat glyphs are UI sprites like the swatches are, so they need the same
	# treatment — a full-colour coin and water drop stamped over a hand-ruled grid is
	# the exact mismatch the ramps exist to remove. They cannot be fixed by authoring
	# a colour the way type can; the shader is the only route.
	#
	# And it must be on the CHILD layer, not the calendar: a CanvasItem's material
	# covers everything it draws, so putting it here would push the title, the rules
	# and the day numbers through the ramp too.
	var cal := _cal()
	assert_not_null(cal.ink_material, "the stat glyphs need the ink shader")
	assert_eq(
		cal.ink_material.shader.resource_path, INK_SHADER,
		"stat glyphs must go through journal_ink.gdshader")
	assert_null(cal.material, "the ink must not be on the calendar itself")
	# TWO channels, one per stat row. A third would need a 24-texel content stack in
	# a 17-texel cell interior, i.e. a 36-texel cell, and 6 of those overflow the
	# page — see RunCalendar's class comment for the arithmetic.
	assert_eq(cal.stat_icons.size(), 2, "expected the water and token glyphs")
	for tex: Texture2D in cal.stat_icons:
		assert_not_null(tex, "a stat glyph failed to resolve")
		assert_eq(tex.get_size(), Vector2(8, 8),
			"stat glyphs must be the 8x8 _small variants")


func test_day_stats_fit_the_cell() -> void:
	# The cell is the binding constraint on this whole page (see RunCalendar's class
	# comment): three glyph columns over three counts, in whatever the gutter leaves
	# of 157 texels. This is the check that a longer season — or a wider gutter —
	# has not quietly squeezed the columns into each other.
	var cal := _cal()
	var grid := cal.grid_size()
	var usable: int = int(cal.size.x) - cal.label_width_px
	var cell_w: int = cal.cell_size.x
	assert_lte(
		grid.x * cell_w + cal.rule_width, usable,
		"the grid has outgrown the page beside its gutter")
	# The cell splits LEFT/RIGHT: a stamp band, then an 8-texel glyph, 1 of air and
	# an 8-texel number (17). Kept as literals rather than reaching for the private
	# constants — this test exists to notice when those change. The stamp needs a
	# band of its own because it is drawn at FULL opacity: layered under the
	# numbers, as it was while it was faded, a red stroke through an 8px digit makes
	# the digit unreadable.
	assert_gte(cell_w - cal.rule_width, 17 + 8,
		"a cell must hold the yield group AND a band for the stamp")
	# Two stat rows of 8 inside one 18-texel block, leaving interior row 16 bare
	# against the seam. Anything taller puts ink on that seam — and 36, the next
	# legal height, overflows the page at 6 season rows.
	assert_eq(cal.cell_size.y, 18, "a stat cell is exactly one warp block tall")
	assert_gte(cal.cell_size.y - cal.rule_width, 2 * 8 + 1,
		"two 8-texel stat rows must fit with a bare row against the bottom seam")


func _is_palette_color(c: Color) -> bool:
	for p: Color in Palette.COLORS:
		if is_equal_approx(p.r, c.r) and is_equal_approx(p.g, c.g) \
				and is_equal_approx(p.b, c.b):
			return true
	return false


func test_calendar_is_in_phase_with_the_row_blocks() -> void:
	# Same rule as page text (see below): a cell row straddling two warp blocks gets
	# a scanline duplicated straight through the grid ruling. Three offsets stack to
	# put a cell row on screen, so all three have to be in phase.
	var page := _page("PageLeft")
	var block: float = page.row_block_px
	var cal := page.get_node("SubViewport/Content/RunCalendar") as RunCalendar
	assert_not_null(cal, "the left page must carry the run calendar")
	assert_gt(cal.cell_size.y, 0, "cells must have height")
	assert_eq(
		fmod(float(cal.cell_size.y), block), 0.0,
		"calendar cell height must be a multiple of the page's row_block_px")
	assert_eq(
		fmod(cal.position.y, block), 0.0,
		"the calendar's top must be a multiple of row_block_px")
	assert_eq(
		float(cal.block_px), block,
		"the calendar's block_px must track the page it is printed on")
	assert_eq(
		fmod(float(cal.grid_top_px()), block), 0.0,
		"the header block above the grid must be a multiple of row_block_px")


func test_calendar_shape_follows_the_season_config() -> void:
	# Shape is derived, never authored: retuning days_per_year must reshape the grid
	# with no scene edit.
	var cal := _page("PageLeft").get_node("SubViewport/Content/RunCalendar") as RunCalendar
	SeasonManager.days_per_year = 4 * maxi(1, SeasonManager.season_cycle.size())
	assert_eq(cal.grid_size(), Vector2i(4, SeasonManager.season_count))
	SeasonManager.days_per_year = 8 * maxi(1, SeasonManager.season_cycle.size())
	assert_eq(cal.grid_size(), Vector2i(8, SeasonManager.season_count))


func test_calendar_stamps_one_cell_per_day_lived() -> void:
	var cal := _page("PageLeft").get_node("SubViewport/Content/RunCalendar") as RunCalendar
	SeasonManager.days_per_year = 4 * maxi(1, SeasonManager.season_cycle.size())

	SeasonManager.phase = SeasonManager.Phase.IDLE
	assert_eq(cal.elapsed_days(), 0, "nothing is stamped before the run starts")

	SeasonManager.phase = SeasonManager.Phase.ACTIVE
	SeasonManager.season_index = 2
	SeasonManager._day_at_season_start = 8
	TimeManager.day_count = 11
	assert_eq(cal.elapsed_days(), 2 * 4 + 3, "two whole seasons plus three days")

	# A season cannot stamp into the next one's row even if the clock overshoots —
	# _debug_force_end_season pushes day_count past the boundary before
	# SeasonManager has rolled over, and the row below must stay blank until it has.
	TimeManager.day_count = 999
	assert_eq(cal.elapsed_days(), 2 * 4 + 4, "clamped to the end of the current season")

	# Nor past the run's own length, whatever the season index says.
	SeasonManager.season_index = 99
	var grid := cal.grid_size()
	assert_eq(cal.elapsed_days(), grid.x * grid.y)


# --- Localization ------------------------------------------------------------
#
# The journal is where a second language can break the page rather than merely
# read oddly, in two distinct ways. Both are silent at runtime.

const LOCALES: Array[String] = ["en_GB", "es_CO"]


func test_journal_titles_are_drawable_in_the_title_face() -> void:
	# Eggmode ships 107 glyphs and has NO accented vowel, no ñ, no ¿ — every one
	# of them is a missing glyph, which renders as tofu or falls back to a
	# non-pixel face and breaks the 16px grid. The Spanish headings are therefore
	# written accent-free ON PURPOSE ("construcciones conocidas", not
	# "construcción"). Nothing else enforces that, so this does.
	var face: Font = _cal().active_header_font()
	assert_eq(face.resource_path, TITLE_FONT, "titles must be the Eggmode face")

	var keys: Array[String] = [_cal().header_text]
	for s: JournalKnownSet in _sections():
		keys.append(s.title)

	var previous := TranslationServer.get_locale()
	for locale: String in LOCALES:
		TranslationServer.set_locale(locale)
		for key: String in keys:
			var text := tr(key)
			assert_ne(text, key, "%s has no %s translation" % [key, locale])
			for i: int in text.length():
				assert_true(
					face.has_char(text.unicode_at(i)),
					"%s/%s: Eggmode has no glyph for '%s' — the journal's titles must be accent-free"
						% [key, locale, text[i]])
			assert_eq(text, text.to_lower(),
				"%s/%s: UI copy is lowercase, per the project convention" % [key, locale])
	TranslationServer.set_locale(previous)


func test_season_names_fit_the_calendar_gutter() -> void:
	# The gutter prints "N <season>" right-aligned into label_width_px - 6 texels
	# in the BODY face. Spanish runs longer than English, and draw_string clips
	# silently at that width — the row just loses its tail with no error. The
	# widest row is the largest day number the grid can reach.
	var cal := _cal()
	var face: Font = cal.active_font()
	var grid := cal.grid_size()
	var budget: float = float(cal.label_width_px) - 6.0

	var previous := TranslationServer.get_locale()
	for locale: String in LOCALES:
		TranslationServer.set_locale(locale)
		for r: int in range(grid.y):
			var text := "%d %s" % [r + 1, cal.season_name(r)]
			var w: float = face.get_string_size(
				text, HORIZONTAL_ALIGNMENT_RIGHT, -1, cal.font_size).x
			assert_lte(w, budget,
				"%s: '%s' is %.0fpx in a %.0fpx gutter" % [locale, text, w, budget])
	TranslationServer.set_locale(previous)


func test_journal_titles_fit_their_page() -> void:
	# The failure this catches actually happened: the first Spanish wording for the
	# buildings heading measured 199px in Eggmode-16 against a 156px page.
	# draw_string is given width -1 (no wrap, no clip), so an over-long title does
	# not wrap or ellipsise — it simply runs off the paper and out of the
	# SubViewport, silently. Spanish is ~25% longer than English, so English
	# fitting proves nothing.
	var previous := TranslationServer.get_locale()
	for locale: String in LOCALES:
		TranslationServer.set_locale(locale)

		var cal := _cal()
		var cal_face: Font = cal.active_header_font()
		var cal_w: float = cal_face.get_string_size(
			tr(cal.header_text), HORIZONTAL_ALIGNMENT_LEFT, -1, cal.header_font_size).x
		assert_lte(cal_w, cal.size.x,
			"%s: calendar title '%s' is %.0fpx on a %.0fpx page"
				% [locale, tr(cal.header_text), cal_w, cal.size.x])

		for s: JournalKnownSet in _sections():
			var face: Font = s.active_header_font()
			var w: float = face.get_string_size(
				tr(s.title), HORIZONTAL_ALIGNMENT_LEFT, -1, s.header_font_size).x
			# The heading starts at the section's own left inset, so that inset is
			# not available to the text.
			var budget: float = s.size.x - 8.0
			assert_lte(w, budget,
				"%s: '%s' is %.0fpx in a %.0fpx column"
					% [locale, tr(s.title), w, budget])
	TranslationServer.set_locale(previous)
