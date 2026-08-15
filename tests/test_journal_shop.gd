extends GutTest

# Guards the journal shop: the unwarped hit-test (click -> entry), the buy flow
# through UnlockState, and the locked/owned presentation switch (the ink
# shader's `dim` uniform — self_modulate is silently ignored by that shader,
# which is exactly the trap the uniform exists to avoid).

const JOURNAL_SCENE: PackedScene = preload("res://scenes/ui/field_journal.tscn")
const TOKENS: StringName = &"tokens"

var journal: CanvasLayer
var shop: JournalShopInput
var buildings: JournalKnownSet
var flora: JournalKnownSet
var _unlocks: UnlockState


func before_each() -> void:
	ResourceLedger.reset()
	_unlocks = UnlockState.new()
	add_child_autofree(_unlocks)
	journal = JOURNAL_SCENE.instantiate()
	add_child_autofree(journal)
	shop = journal.get_node("Book/BookArt/BookHit") as JournalShopInput
	buildings = journal.get_node("%KnownBuildings") as JournalKnownSet
	flora = journal.get_node("%KnownFlora") as JournalKnownSet


func after_each() -> void:
	ResourceLedger.reset()
	# The gate is static, so it is per-PROCESS: a test that narrows it and does
	# not put it back hands the next script a game with the verbs switched off.
	TutorialGate.release()


# A PageRight-local point inside `section`'s swatch cell `idx`.
func _click_point(section: JournalKnownSet, idx: int) -> Vector2:
	var cell := section.entry_rect(idx)
	return shop.content.position + section.position \
			+ cell.position + cell.size * 0.5


# --- hit-testing --------------------------------------------------------------

func test_entry_at_maps_cells_and_misses_gutters() -> void:
	# Probes are DERIVED from entry_rect rather than written as literals. They
	# used to be literals, and they broke the moment the entries stopped being
	# equal widths — x=95 was past the last cell at 24 texels each and inside it
	# at the authored widths. A hit test wants to assert the MAPPING, not the
	# layout the layout tests already cover.
	var row: float = buildings.header_row_px() + 5.0
	for i in buildings._swatches.size():
		var r := buildings.entry_rect(i)
		assert_eq(buildings.entry_at(Vector2(r.get_center().x, row)), i, "cell %d" % i)
	assert_eq(buildings.entry_at(Vector2(10.0, 2.0)), -1, "the title row sells nothing")
	var last := buildings.entry_rect(buildings._swatches.size() - 1)
	assert_eq(buildings.entry_at(Vector2(last.end.x + 8.0, row)), -1, "past the last swatch")


func test_the_whole_drawn_swatch_is_hittable() -> void:
	# The bug this exists for: entry_rect used to return the CELL, while _rebuild
	# draws each swatch at the ART's own size centred in that cell and never scales
	# it. Shrink cell_size below the art — 32px tile swatches in a 24x16 cell — and
	# most of the picture stops responding, which reads in game as "hover only works
	# near the centre".
	#
	# Every other hit-test here aims at a cell CENTRE, so none of them could catch
	# it. This one walks the corners of what is actually on screen.
	for section: JournalKnownSet in [buildings, flora]:
		for i in section._swatches.size():
			var art := Rect2(section._swatches[i].position, section._swatches[i].size)
			var hit := section.entry_rect(i)
			for corner: Vector2 in [
					art.position, Vector2(art.end.x - 1, art.position.y),
					Vector2(art.position.x, art.end.y - 1), art.end - Vector2.ONE]:
				# Horizontally the art may overhang into a NEIGHBOUR's column, which
				# that neighbour keeps — cells abut, so there is nothing to give. The
				# claim is about the swatch's own column and its full height.
				var probe := Vector2(clampf(corner.x, hit.position.x, hit.end.x - 1), corner.y)
				assert_true(hit.has_point(probe),
					"%s entry %d: %s is drawn but not hittable (hit %s)"
						% [section.title, i, probe, hit])


# --- per-entry cell sizes -----------------------------------------------------

func test_each_entry_gets_its_authored_cell_width() -> void:
	# The three building swatches are deliberately different widths: the art is
	# cut from the atlas and does not fill it, so a ladder (14 texels of ink) and
	# a fence (24) need different room. One shared width either crowds one or
	# leaves a hole beside the other.
	# Against cell_size_for, not entry_rect: the latter is the HIT rect, which
	# deliberately grows past the cell by hit_padding_px and by whatever the art
	# overhangs.
	for i in buildings.cell_sizes.size():
		assert_eq(buildings.cell_size_for(i), buildings.cell_sizes[i],
				"entry %d must get the cell it was authored" % i)
		assert_true(buildings.entry_rect(i).size.x >= float(buildings.cell_sizes[i].x),
				"entry %d's hit rect must cover its cell" % i)


func test_entries_past_the_override_list_fall_back_to_cell_size() -> void:
	# flora authors no overrides at all, so every entry takes the shared size.
	assert_eq(flora.cell_size_for(0), flora.cell_size)
	assert_eq(flora.cell_size_for(99), flora.cell_size,
			"an index past the end must not read off the array")


func test_a_zeroed_override_falls_back_rather_than_collapsing() -> void:
	var original := buildings.cell_sizes.duplicate()
	buildings.cell_sizes = [Vector2i.ZERO]
	assert_eq(buildings.cell_size_for(0), buildings.cell_size)
	buildings.cell_sizes = original


func test_cells_abut_without_overlapping() -> void:
	# Cells are laid end to end, so a wider one has to PUSH its neighbours along.
	# The bug this catches is `index * pitch` arithmetic, which silently stacks
	# entries on top of each other the moment the widths stop being equal.
	for i in range(1, buildings.entry_ids.size()):
		var prev := buildings.entry_rect(i - 1)
		var cur := buildings.entry_rect(i)
		assert_almost_eq(cur.position.x, prev.end.x, 4.0,
				"entry %d must start where entry %d ends (hit padding aside)" % [i, i - 1])


func test_drawn_swatches_do_not_collide() -> void:
	# The claim the cell widths exist to support, checked on what is actually
	# INKED rather than on the cells. Each swatch is a 32px texture whose art may
	# sit anywhere inside it — the ladder's ink is entirely in the right half —
	# so cells that clear each other are no guarantee the pictures do.
	var boxes: Array[Rect2] = []
	for i in buildings._swatches.size():
		var r: TextureRect = buildings._swatches[i]
		var ink := JournalKnownSet._ink_rect(r.texture)
		boxes.append(Rect2(r.position + ink.position, ink.size))
	for i in range(1, boxes.size()):
		assert_true(boxes[i].position.x >= boxes[i - 1].end.x,
				"swatch %d's art (%s) overlaps swatch %d's (%s)"
					% [i, boxes[i], i - 1, boxes[i - 1]])


func test_entry_ids_align_with_swatches() -> void:
	# The authored swatch order IS the id order — a misalignment here would
	# sell the wrong thing.
	assert_eq(buildings.swatch_textures().size(), 3,
			"every building swatch must resolve from the atlas")
	# Cost order, cheapest first — the page reads as a price ladder.
	assert_eq(buildings.entry_id_at(0), &"ladder")
	assert_eq(buildings.entry_id_at(1), &"bridge")
	assert_eq(buildings.entry_id_at(2), &"fence")
	var prices: Array[float] = []
	for i in buildings.entry_ids.size():
		prices.append(_unlocks.unlock_cost_for(buildings.entry_id_at(i)))
	for i in range(1, prices.size()):
		assert_gte(prices[i], prices[i - 1],
				"swatch %d (%s) is cheaper than the one before it"
				% [i, buildings.entry_id_at(i)])
	assert_eq(flora.entry_id_at(0), &"frailejon")


# --- buy flow -----------------------------------------------------------------

func test_clicking_a_locked_entry_buys_it() -> void:
	# Exactly that entry's own price — read from UnlockState rather than typed
	# here, so a retune moves the test with the game.
	var id: StringName = buildings.entry_id_at(0)
	ResourceLedger.set_amount(TOKENS, _unlocks.unlock_cost_for(id))
	assert_true(shop.handle_click(_click_point(buildings, 0)))
	assert_true(_unlocks.is_unlocked(id))
	assert_eq(ResourceLedger.get_amount(TOKENS), 0.0)


func test_clicking_while_broke_buys_nothing() -> void:
	# One token under the FRAILEJON's own price. Prices are per type now
	# (ladder 10, bridge 20, fence 30), so "broke" only means anything relative
	# to the entry being clicked.
	var short: float = _unlocks.unlock_cost_for(&"frailejon") - 1.0
	ResourceLedger.set_amount(TOKENS, short)
	assert_false(shop.handle_click(_click_point(flora, 0)))
	assert_false(_unlocks.is_unlocked(&"frailejon"))
	assert_eq(ResourceLedger.get_amount(TOKENS), short)


func test_clicking_an_owned_entry_spends_nothing() -> void:
	var cost: float = _unlocks.unlock_cost_for(buildings.entry_id_at(0))
	ResourceLedger.set_amount(TOKENS, 40.0)
	shop.handle_click(_click_point(buildings, 0))
	assert_eq(ResourceLedger.get_amount(TOKENS), 40.0 - cost)
	assert_false(shop.handle_click(_click_point(buildings, 0)))
	assert_eq(ResourceLedger.get_amount(TOKENS), 40.0 - cost, "no double charge")


func test_clicking_bare_paper_does_nothing() -> void:
	ResourceLedger.set_amount(TOKENS, 20.0)
	# The sections now abut (KnownBuildings 54..126, KnownFlora 126..198 in CONTENT
	# space) because each heading grew a block for its rule, so there is no
	# inter-section gap left to aim at. These are the bare-paper regions that remain.
	#
	# NOTE the argument is PAGE space, not content space — Content sits 9 texels
	# down, and handle_click subtracts that itself. Content's 198 is page 207, so
	# aiming at "205" lands inside KnownFlora's cell row and BUYS a frailejon.
	assert_false(shop.handle_click(Vector2(20.0, 20.0)), "the supplies row sells nothing")
	assert_false(shop.handle_click(Vector2(20.0, 215.0)), "the foot of the page")
	# A section's own TITLE band is paper too — inside the node, above its cells.
	assert_false(shop.handle_click(
			shop.content.position + buildings.position + Vector2(20.0, 4.0)),
		"a section's heading sells nothing")
	assert_eq(ResourceLedger.get_amount(TOKENS), 20.0)


# --- presentation -------------------------------------------------------------

func test_locked_entries_render_dimmed_with_owned_full_ink() -> void:
	ResourceLedger.set_amount(TOKENS, 20.0)
	shop._refresh_states()
	var locked_mat := buildings._swatches[0].material as ShaderMaterial
	assert_almost_eq(float(locked_mat.get_shader_parameter(&"dim")),
			JournalKnownSet.LOCKED_ALPHA, 0.001,
			"a locked swatch fades through the shader's dim uniform")

	shop.handle_click(_click_point(buildings, 0))
	# dim back to 1, NOT the material swapped back: every swatch carries its own
	# duplicate now, because hover drives the same uniform per entry.
	var owned_mat := buildings._swatches[0].material as ShaderMaterial
	assert_almost_eq(float(owned_mat.get_shader_parameter(&"dim")), 1.0, 0.001,
			"an owned swatch goes back to full ink")
	var still_locked := buildings._swatches[1].material as ShaderMaterial
	assert_almost_eq(float(still_locked.get_shader_parameter(&"dim")),
			JournalKnownSet.LOCKED_ALPHA, 0.001,
			"the neighbour is still locked and stays faded")


func test_hover_lifts_the_entry_under_the_pointer() -> void:
	ResourceLedger.set_amount(TOKENS, 20.0)
	shop._refresh_states()
	var rest: Vector2 = buildings._swatches[0].position
	shop.handle_hover(_click_point(buildings, 0))
	assert_eq(buildings._swatches[0].position,
			rest - Vector2(0, JournalKnownSet.HOVER_LIFT_PX),
			"a hovered swatch lifts a whole texel off the paper")
	# Whole texels only: this sits in a 1:1 nearest-filtered viewport, where a
	# fractional offset resamples the pixel art.
	assert_eq(buildings._swatches[0].position.round(), buildings._swatches[0].position)
	shop.handle_hover(Vector2(20.0, 205.0))
	assert_eq(buildings._swatches[0].position, rest, "leaving puts it back down")


func test_hover_brightens_a_locked_entry() -> void:
	ResourceLedger.set_amount(TOKENS, 20.0)
	shop._refresh_states()
	shop.handle_hover(_click_point(buildings, 0))
	var mat := buildings._swatches[0].material as ShaderMaterial
	assert_almost_eq(float(mat.get_shader_parameter(&"dim")),
			JournalKnownSet.HOVER_ALPHA, 0.001,
			"pointing at a locked entry inks it up toward owned")
	# Its NEIGHBOUR must stay faded — the whole reason each swatch owns its
	# material rather than sharing the section's.
	var neighbour := buildings._swatches[1].material as ShaderMaterial
	assert_almost_eq(float(neighbour.get_shader_parameter(&"dim")),
			JournalKnownSet.LOCKED_ALPHA, 0.001,
			"hover must not brighten the whole section")


func test_an_unaffordable_entry_does_not_react_to_hover() -> void:
	# 20 tokens: the fence (30) is out of reach. Lifting and inking it up would
	# advertise a purchase that cannot happen, so the refusal only arrives on the
	# click — the price beside the swatch is already the reason, printed.
	ResourceLedger.set_amount(TOKENS, 20.0)
	shop._refresh_states()
	var rest: Vector2 = buildings._swatches[2].position
	assert_false(buildings.reacts_to_hover(2), "the fence is out of budget")
	shop.handle_hover(_click_point(buildings, 2))
	assert_eq(buildings._swatches[2].position, rest, "an unaffordable swatch stays put")
	var mat := buildings._swatches[2].material as ShaderMaterial
	assert_almost_eq(float(mat.get_shader_parameter(&"dim")),
			JournalKnownSet.LOCKED_ALPHA, 0.001,
			"and stays faded rather than inking up toward owned")
	# The pointer is still resolved to it — the refusal is about the RESPONSE, not
	# about where the input node thinks the cursor is.
	assert_eq(buildings._hovered, 2)


func test_an_entry_starts_reacting_once_it_is_affordable() -> void:
	ResourceLedger.set_amount(TOKENS, 20.0)
	shop._refresh_states()
	var rest: Vector2 = buildings._swatches[2].position
	shop.handle_hover(_click_point(buildings, 2))
	assert_eq(buildings._swatches[2].position, rest)
	# Earning the difference must wake it up under a pointer that never moved.
	ResourceLedger.set_amount(TOKENS,
			_unlocks.unlock_cost_for(buildings.entry_id_at(2)))
	assert_true(buildings.reacts_to_hover(2))
	assert_eq(buildings._swatches[2].position,
			rest - Vector2(0, JournalKnownSet.HOVER_LIFT_PX),
			"affording it mid-hover lifts it without a mouse move")


func test_an_owned_entry_still_reacts_to_hover() -> void:
	# Owned is not BLOCKED, it is done. The section is a reference list as well as
	# a shop, so pointing at something you have still gets an answer.
	ResourceLedger.set_amount(TOKENS, 40.0)
	shop.handle_click(_click_point(buildings, 0))
	var rest: Vector2 = buildings._swatches[0].position
	shop.handle_hover(_click_point(buildings, 0))
	assert_true(buildings.reacts_to_hover(0))
	assert_eq(buildings._swatches[0].position,
			rest - Vector2(0, JournalKnownSet.HOVER_LIFT_PX))


func test_the_tutorial_gate_stops_the_page_reacting_at_all() -> void:
	# The FTUE opens the journal a step BEFORE it sells anything: the page is
	# readable, and nothing on it may promise a click will work.
	ResourceLedger.set_amount(TOKENS, 40.0)
	shop._refresh_states()
	var rest: Vector2 = buildings._swatches[0].position
	TutorialGate.restrict_to(0)
	shop.handle_hover(_click_point(buildings, 0))
	assert_eq(buildings._swatches[0].position, rest,
			"a gated shop must not lift anything")
	assert_eq(buildings._hovered, -1)
	TutorialGate.release()
	shop.handle_hover(_click_point(buildings, 0))
	assert_eq(buildings._swatches[0].position,
			rest - Vector2(0, JournalKnownSet.HOVER_LIFT_PX),
			"and must react again once the step grants it")


func test_hover_moves_between_sections() -> void:
	ResourceLedger.set_amount(TOKENS, 20.0)
	shop._refresh_states()
	shop.handle_hover(_click_point(buildings, 0))
	shop.handle_hover(_click_point(flora, 0))
	var left := buildings._swatches[0].material as ShaderMaterial
	assert_almost_eq(float(left.get_shader_parameter(&"dim")),
			JournalKnownSet.LOCKED_ALPHA, 0.001,
			"the entry the pointer LEFT must un-hover")


func test_an_unaffordable_click_flashes_instead_of_buying() -> void:
	# The recoil is the only feedback a refused purchase gives — without it the
	# click is silently swallowed and reads as a dead widget.
	var id: StringName = buildings.entry_id_at(0)
	var short: float = _unlocks.unlock_cost_for(id) - 1.0
	ResourceLedger.set_amount(TOKENS, short)
	assert_false(shop.handle_click(_click_point(buildings, 0)))
	assert_eq(buildings._denied, 0, "the clicked entry is the one that recoils")
	assert_false(_unlocks.is_unlocked(id))
	assert_eq(ResourceLedger.get_amount(TOKENS), short, "a refusal charges nothing")


func test_an_affordable_click_does_not_flash() -> void:
	ResourceLedger.set_amount(TOKENS,
			_unlocks.unlock_cost_for(buildings.entry_id_at(0)))
	assert_true(shop.handle_click(_click_point(buildings, 0)))
	assert_eq(buildings._denied, -1)


# --- the "left click to buy" tag -----------------------------------------------

func _tooltip() -> JournalTooltip:
	return shop._tooltip


func test_the_buy_tag_appears_over_an_affordable_entry() -> void:
	ResourceLedger.set_amount(TOKENS, 20.0)
	shop._refresh_states()
	shop.handle_hover(_click_point(buildings, 0))
	assert_not_null(_tooltip(), "hovering something for sale builds the tag")
	assert_true(_tooltip().visible)


func test_the_glyph_is_anchored_to_the_ink_not_the_cell() -> void:
	# A 20-texel ladder centred in a 36-texel cell leaves blank paper inside it,
	# and entry_rect is grown past the cell again by hit_padding_px. A glyph on
	# THAT corner sits in the neighbour's column with nothing under it.
	for i in buildings._swatches.size():
		var ink := buildings.entry_ink_rect(i)
		var hit := buildings.entry_rect(i)
		assert_true(hit.encloses(ink) or hit.intersects(ink),
				"entry %d: the ink must be inside what the hit rect covers" % i)
		assert_lt(ink.size.x, hit.size.x,
				"entry %d: the ink is narrower than the cell it sits in" % i)


func test_show_over_tucks_into_the_corner_and_stays_in_bounds() -> void:
	# The placement rule itself, away from the journal's transform chain: the
	# glyph's bottom-left overlaps the art's top-right, on whole pixels, never
	# off the book.
	var tip := JournalTooltip.new()
	add_child_autofree(tip)
	var bounds := Rect2(Vector2.ZERO, Vector2(200, 120))
	var art := Rect2(Vector2(80, 60), Vector2(20, 20))
	tip.show_over(art, bounds, Palette.P06)
	assert_eq(tip.position.x, art.end.x - JournalTooltip.OVERLAP_PX,
			"the glyph's left edge bites into the art's right")
	assert_eq(tip.position.y + tip.size.y,
			art.position.y + JournalTooltip.OVERLAP_PX,
			"and its bottom edge into the art's top")
	assert_eq(tip.position.round(), tip.position, "whole pixels only")
	# The rightmost entry sits near the page edge, and it cannot move to make room.
	tip.show_over(Rect2(Vector2(196, 60), Vector2(20, 20)), bounds, Palette.P06)
	assert_lte(tip.position.x + tip.size.x, bounds.end.x, "clamped to the paper")
	tip.show_over(Rect2(Vector2(80, 2), Vector2(20, 20)), bounds, Palette.P06)
	assert_gte(tip.position.y, bounds.position.y, "and to its top")


func test_the_buy_tag_stays_away_from_what_cannot_be_bought() -> void:
	ResourceLedger.set_amount(TOKENS, 20.0)
	shop._refresh_states()
	# Unaffordable — the same entry the hover itself already declines to lift.
	shop.handle_hover(_click_point(buildings, 2))
	assert_true(_tooltip() == null or not _tooltip().visible,
			"nothing offers to sell the fence at 20 tokens")
	# Bare paper.
	shop.handle_hover(_click_point(buildings, 0))
	shop.handle_hover(Vector2(20.0, 20.0))
	assert_false(_tooltip().visible, "the tag leaves with the pointer")


func test_buying_takes_the_tag_down_without_a_mouse_move() -> void:
	# The pointer does not move when you click, so nothing else would re-ask —
	# and "buy" left floating over a thing you now own reads as a failed click.
	ResourceLedger.set_amount(TOKENS, 40.0)
	shop._refresh_states()
	shop.handle_hover(_click_point(buildings, 0))
	assert_true(_tooltip().visible)
	assert_true(shop.handle_click(_click_point(buildings, 0)))
	assert_false(_tooltip().visible, "an owned entry has nothing left to sell")


func test_the_tutorial_gate_takes_the_buy_tag_with_it() -> void:
	ResourceLedger.set_amount(TOKENS, 40.0)
	shop._refresh_states()
	TutorialGate.restrict_to(0)
	shop.handle_hover(_click_point(buildings, 0))
	assert_true(_tooltip() == null or not _tooltip().visible,
			"a gated shop offers nothing")


func test_the_buy_tag_is_drawn_over_the_pages() -> void:
	# BookHit sits BEFORE Pages in the scene, so a tag parented to it would be
	# painted UNDER the paper — invisible, and invisible in a way no geometry
	# assertion would catch. It goes on BookHit's parent, as the last child.
	ResourceLedger.set_amount(TOKENS, 20.0)
	shop._refresh_states()
	shop.handle_hover(_click_point(buildings, 0))
	var host := shop.get_parent()
	assert_eq(_tooltip().get_parent(), host)
	assert_eq(host.get_child(host.get_child_count() - 1), _tooltip(),
			"the tag must be the last child, i.e. drawn last")
	assert_lt(host.get_children().find(shop),
			host.get_children().find(_tooltip()),
			"and after the hit area it belongs to")


# --- cost icons ----------------------------------------------------------------

func test_a_price_is_printed_only_while_its_entry_is_locked() -> void:
	ResourceLedger.set_amount(TOKENS, 40.0)
	shop._refresh_states()
	assert_eq(buildings._cost_icons.size(), buildings._swatches.size(),
			"every entry carries a coin, shown or not")
	assert_true(buildings._cost_icons[0].visible, "a locked entry prints its price")
	shop.handle_click(_click_point(buildings, 0))
	assert_false(buildings._cost_icons[0].visible,
			"an owned entry has no price, so no coin either")
	assert_true(buildings._cost_icons[1].visible, "the neighbour is still for sale")


func test_a_coin_fades_with_its_own_number() -> void:
	# 20 tokens: ladder (10) and bridge (20) affordable, fence (30) not. A coin
	# that stayed bright over a faded price would contradict the price.
	ResourceLedger.set_amount(TOKENS, 20.0)
	shop._refresh_states()
	var affordable := buildings._cost_icons[0].material as ShaderMaterial
	assert_almost_eq(float(affordable.get_shader_parameter(&"dim")), 1.0, 0.001,
			"a price the player can meet prints at full ink")
	var out_of_reach := buildings._cost_icons[2].material as ShaderMaterial
	assert_almost_eq(float(out_of_reach.get_shader_parameter(&"dim")),
			JournalKnownSet.LOCKED_ALPHA, 0.001,
			"an unaffordable price fades, coin and digits together")


func test_a_price_fits_inside_its_own_cell() -> void:
	# The claim the coin puts under pressure: the ladder's cell is 20 texels and
	# the group is 8 + 1 + two digits = 17 of them. Retune a price into three
	# digits or a cell narrower and this is what goes first — and it fails as a
	# silent overlap with the neighbour's picture, not as an error.
	ResourceLedger.set_amount(TOKENS, 0.0)
	shop._refresh_states()
	for section: JournalKnownSet in [buildings, flora]:
		for i in section._swatches.size():
			var group: float = section.cost_group_width(i) \
					+ JournalKnownSet.COST_MARGIN_PX
			assert_lte(group, float(section.cell_size_for(i).x),
					"%s entry %d: a %d-texel price in a %d-texel cell"
						% [section.title, i, group, section.cell_size_for(i).x])


func test_the_coin_sits_beside_its_digits_on_whole_texels() -> void:
	ResourceLedger.set_amount(TOKENS, 0.0)
	shop._refresh_states()
	var face: Font = buildings.get_theme_font(&"font", &"Label")
	for i in buildings._cost_icons.size():
		var g: TextureRect = buildings._cost_icons[i]
		var rect := buildings.entry_rect(i)
		# Whole texels: these sit in the same 1:1 nearest-filtered viewport the
		# swatches do, where a half texel resamples 8px pixel art into mush.
		assert_eq(g.position.round(), g.position, "entry %d's coin is off-grid" % i)
		assert_eq(g.size, Vector2(JournalKnownSet.COST_ICON_PX,
				JournalKnownSet.COST_ICON_PX), "entry %d's coin is not 8x8" % i)
		# Left of the digits, and its baseline is theirs — the two are one label.
		var digits_x: float = rect.end.x - JournalKnownSet.COST_MARGIN_PX \
				- face.get_string_size(str(int(_unlocks.unlock_cost_for(
					buildings.entry_id_at(i)))), HORIZONTAL_ALIGNMENT_LEFT, -1,
					JournalKnownSet.COST_FONT_SIZE).x
		assert_eq(g.position.x + JournalKnownSet.COST_ICON_PX
				+ JournalKnownSet.COST_GAP_PX, digits_x,
				"entry %d's coin must abut its digits" % i)
		assert_eq(g.position.y + JournalKnownSet.COST_ICON_PX,
				rect.end.y - JournalKnownSet.COST_MARGIN_PX,
				"entry %d's coin must sit on the digits' baseline" % i)


func test_without_an_unlock_state_the_page_is_inert() -> void:
	# Preview tools and layout tests instance the journal with no economy in
	# the scene: everything must render owned and clicks must do nothing.
	_unlocks.remove_from_group(&"unlocks")
	shop._unlocks = null
	shop._refresh_states()
	var mat := buildings._swatches[0].material as ShaderMaterial
	assert_almost_eq(float(mat.get_shader_parameter(&"dim")), 1.0, 0.001,
			"with no economy every swatch renders owned")
	assert_false(shop.handle_click(_click_point(buildings, 0)))
