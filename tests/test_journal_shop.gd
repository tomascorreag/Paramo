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


# A PageRight-local point inside `section`'s swatch cell `idx`.
func _click_point(section: JournalKnownSet, idx: int) -> Vector2:
	var cell := section.entry_rect(idx)
	return shop.content.position + section.position \
			+ cell.position + cell.size * 0.5


# --- hit-testing --------------------------------------------------------------

func test_entry_at_maps_cells_and_misses_gutters() -> void:
	var row: float = buildings.header_row_px() + 5.0
	assert_eq(buildings.entry_at(Vector2(10.0, row)), 0, "first cell")
	assert_eq(buildings.entry_at(Vector2(50.0, row)), 1, "second cell")
	assert_eq(buildings.entry_at(Vector2(10.0, 2.0)), -1, "the title row sells nothing")
	assert_eq(buildings.entry_at(Vector2(95.0, row)), -1, "past the last swatch")


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


func test_entry_ids_align_with_swatches() -> void:
	# The authored swatch order IS the id order — a misalignment here would
	# sell the wrong thing.
	assert_eq(buildings.swatch_textures().size(), 2,
			"both building swatches must resolve from the atlas")
	assert_eq(buildings.entry_id_at(0), &"bridge")
	assert_eq(buildings.entry_id_at(1), &"ladder")
	assert_eq(flora.entry_id_at(0), &"frailejon")


# --- buy flow -----------------------------------------------------------------

func test_clicking_a_locked_entry_buys_it() -> void:
	ResourceLedger.set_amount(TOKENS, 10.0)
	assert_true(shop.handle_click(_click_point(buildings, 0)))
	assert_true(_unlocks.is_unlocked(&"bridge"))
	assert_eq(ResourceLedger.get_amount(TOKENS), 0.0)


func test_clicking_while_broke_buys_nothing() -> void:
	ResourceLedger.set_amount(TOKENS, 9.0)
	assert_false(shop.handle_click(_click_point(flora, 0)))
	assert_false(_unlocks.is_unlocked(&"frailejon"))
	assert_eq(ResourceLedger.get_amount(TOKENS), 9.0)


func test_clicking_an_owned_entry_spends_nothing() -> void:
	ResourceLedger.set_amount(TOKENS, 20.0)
	shop.handle_click(_click_point(buildings, 0))
	assert_eq(ResourceLedger.get_amount(TOKENS), 10.0)
	assert_false(shop.handle_click(_click_point(buildings, 0)))
	assert_eq(ResourceLedger.get_amount(TOKENS), 10.0, "no double charge")


func test_clicking_bare_paper_does_nothing() -> void:
	ResourceLedger.set_amount(TOKENS, 10.0)
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
	assert_eq(ResourceLedger.get_amount(TOKENS), 10.0)


# --- presentation -------------------------------------------------------------

func test_locked_entries_render_dimmed_with_owned_full_ink() -> void:
	ResourceLedger.set_amount(TOKENS, 10.0)
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
	ResourceLedger.set_amount(TOKENS, 10.0)
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
	ResourceLedger.set_amount(TOKENS, 10.0)
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


func test_hover_moves_between_sections() -> void:
	ResourceLedger.set_amount(TOKENS, 10.0)
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
	ResourceLedger.set_amount(TOKENS, 9.0)
	assert_false(shop.handle_click(_click_point(buildings, 0)))
	assert_eq(buildings._denied, 0, "the clicked entry is the one that recoils")
	assert_false(_unlocks.is_unlocked(&"bridge"))
	assert_eq(ResourceLedger.get_amount(TOKENS), 9.0, "a refusal charges nothing")


func test_an_affordable_click_does_not_flash() -> void:
	ResourceLedger.set_amount(TOKENS, 10.0)
	assert_true(shop.handle_click(_click_point(buildings, 0)))
	assert_eq(buildings._denied, -1)


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
