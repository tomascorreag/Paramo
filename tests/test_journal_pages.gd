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
	# Loops over DIRECT Label children of a page's Content. There are none today —
	# the pages draw their type (RunCalendar, JournalKnownSet) or nest it a level
	# down (the inventory rows) — so this is the guard for the next label somebody
	# authors straight onto a page, not a check on current content. The count
	# assertion below therefore rides on the inventory, which is real body copy.
	for name_: String in PAGE_RECTS:
		for label: Label in _labels_on(_page(name_)):
			assert_eq(
				label.get_theme_font(&"font").resource_path, BODY_FONT,
				"%s/%s: page body copy must be Tiny5" % [name_, label.name])
	var found := 0
	for inv: Label in _inventory_labels():
		found += 1
		assert_eq(
			inv.get_theme_font(&"font").resource_path, BODY_FONT,
			"inventory/%s: page body copy must be Tiny5" % inv.get_parent().name)
	assert_gt(found, 0, "the left page should carry the supplies list")

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
	for inv: Label in _inventory_labels():
		used.append([inv.get_theme_font(&"font").resource_path,
			inv.get_theme_font_size(&"font_size"), "inventory/" + inv.get_parent().name])
	assert_gt(used.size(), 3, "expected page labels, the calendar AND the inventory")
	for entry: Array in used:
		assert_true(FONT_EM_PX.has(entry[0]), "unknown face %s at %s" % [entry[0], entry[2]])
		var em: int = FONT_EM_PX.get(entry[0], 8)
		assert_eq(
			int(entry[1]) % em, 0,
			"%s: %d is not a multiple of %s's %dpx em"
				% [entry[2], entry[1], String(entry[0]).get_file(), em])


func _cal() -> RunCalendar:
	return _page("PageLeft").get_node("SubViewport/Content/RunCalendar") as RunCalendar


func _inventory() -> JournalInventory:
	return _page("PageLeft").get_node("SubViewport/Content/Inventory") as JournalInventory


func _inventory_labels() -> Array[Label]:
	var out: Array[Label] = []
	for row in _inventory().get_children():
		var count := (row as Node).get_node_or_null(^"Count") as Label
		if count != null:
			out.append(count)
	return out


func test_inventory_is_printed_on_the_left_page() -> void:
	# It is stock written INTO the book, so it must go through the page's viewport and
	# bend with the paper — the opposite of the season wheel, which PageSlit keeps out
	# of any viewport precisely so it stays flat.
	var rows := _inventory_labels()
	assert_eq(rows.size(), 2, "expected a water row and a money row")
	for row: Label in rows:
		var icon := row.get_parent().get_node(^"Icon") as TextureRect
		assert_not_null(icon, "every row needs its glyph")
		assert_gte(
			row.position.x, icon.position.x + icon.size.x,
			"the count must sit to the RIGHT of its icon, clear of it")


func test_inventory_rows_sit_inside_one_warp_block() -> void:
	# A row is icon + count on one line; split across a block seam, the shader would
	# shear the glyph away from its number.
	var block: float = _page("PageLeft").row_block_px
	var inv := _inventory()
	for row: Label in _inventory_labels():
		var group := row.get_parent() as Control
		var top: float = inv.position.y + group.position.y
		assert_eq(fmod(top, block), 0.0, "row %s must start on a block" % group.name)
		assert_lt(group.size.y, block + 1.0, "row %s must not outgrow its block" % group.name)


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
	var titles: Array[String] = []
	for s: JournalKnownSet in sections:
		titles.append(s.title)
		assert_gt(
			s.swatch_textures().size(), 0,
			"%s resolved no swatches" % s.title)
		assert_eq(
			s.title, s.title.to_lower(),
			"%s: UI copy is lowercase, per the project convention" % s.title)
	assert_has(titles, "known buildings")
	assert_has(titles, "known flora")


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
	for s: JournalKnownSet in _sections():
		assert_not_null(s.ink_material, "%s: no ink material" % s.title)
		var swatches := 0
		for child in s.get_children():
			if child is TextureRect:
				swatches += 1
				assert_same(
					(child as TextureRect).material, s.ink_material,
					"%s: a swatch is not going through the ink shader" % s.title)
				assert_eq(
					(child as TextureRect).texture_filter,
					CanvasItem.TEXTURE_FILTER_NEAREST,
					"%s: swatches must stay hard-edged" % s.title)
		assert_eq(
			swatches, s.swatch_textures().size(),
			"%s: a resolved texture did not get a node" % s.title)


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
	var cal := _cal()
	var checked: Array[Array] = [
		[cal.rule_color, "RunCalendar.rule_color"],
		[cal.border_color, "RunCalendar.border_color"],
		[cal.text_color, "RunCalendar.text_color"],
		[cal.stamp_color, "RunCalendar.stamp_color"],
	]
	for s: JournalKnownSet in _sections():
		checked.append([s.text_color, "%s.text_color" % s.title])
	for label: Label in _inventory_labels():
		checked.append([
			label.get_theme_color(&"font_color"),
			"inventory/%s font_color" % label.get_parent().name])
	for name_: String in PAGE_RECTS:
		for label: Label in _labels_on(_page(name_)):
			checked.append([
				label.get_theme_color(&"font_color"),
				"%s/%s font_color" % [name_, label.name]])

	assert_gt(checked.size(), 6, "expected the calendar, both sections and the supplies")
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


func test_inventory_icons_go_through_the_ink() -> void:
	# The supplies glyphs are world-palette sprites like the swatches are, so they
	# need the same treatment — a full-colour coin and water drop beside inked
	# swatches is the exact mismatch the ramps exist to remove. They cannot be fixed
	# by authoring a colour the way type can; the shader is the only route.
	var inv := _inventory()
	var icons := 0
	for row in inv.get_children():
		var icon := (row as Node).get_node_or_null(^"Icon") as TextureRect
		if icon == null:
			continue
		icons += 1
		assert_not_null(
			icon.material, "inventory/%s: glyph is not going through the ink" % row.name)
		assert_true(
			icon.material is ShaderMaterial and
				(icon.material as ShaderMaterial).shader.resource_path
					== "res://assets/shaders/journal_ink.gdshader",
			"inventory/%s: wrong material on the glyph" % row.name)
	assert_gt(icons, 0, "expected the supplies rows to carry glyphs")


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
