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


func test_clicking_the_paper_between_sections_does_nothing() -> void:
	ResourceLedger.set_amount(TOKENS, 10.0)
	# y = 95 sits in the gap between KnownBuildings (ends 90) and KnownFlora
	# (starts 108) in content space.
	assert_false(shop.handle_click(Vector2(20.0, 95.0)))
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
	assert_eq(buildings._swatches[0].material, buildings.ink_material,
			"an owned swatch goes back to the shared full-ink material")
	var still_locked := buildings._swatches[1].material as ShaderMaterial
	assert_almost_eq(float(still_locked.get_shader_parameter(&"dim")),
			JournalKnownSet.LOCKED_ALPHA, 0.001,
			"the neighbour is still locked and stays faded")


func test_without_an_unlock_state_the_page_is_inert() -> void:
	# Preview tools and layout tests instance the journal with no economy in
	# the scene: everything must render owned and clicks must do nothing.
	_unlocks.remove_from_group(&"unlocks")
	shop._unlocks = null
	shop._refresh_states()
	assert_eq(buildings._swatches[0].material, buildings.ink_material)
	assert_false(shop.handle_click(_click_point(buildings, 0)))
