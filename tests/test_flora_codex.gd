extends GutTest

# ===========================================================================
# Flora discovery: inspect a plant -> FloraCodex -> the journal's known flora
# ===========================================================================
# Three seams, and the middle one is the whole feature:
#   ActionInspect      identifies the plant standing on a cell (and nothing else
#                      — it no longer reads out CellData for any walkable tile)
#   FloraCodex         records it for the run
#   JournalKnownSet    draws only what the codex holds, when require_discovery
#
# The trap this guards is the third: hiding an entry has to close the row up.
# Everything index-based on that node (cell sizes, ink runs, hit rects, the shop
# id a click buys) counts through the DRAWN entries, so an off-by-one there sells
# the player the wrong plant rather than rendering visibly wrong.

const JOURNAL_SCENE: PackedScene = preload("res://scenes/ui/field_journal.tscn")
const _ICON: Texture2D = preload("res://icon.svg")


# Grid stub: occupant_at over an injected dict. Subclasses TileGrid so it
# satisfies Pathfinder.grid()'s static type; set_occupant would need painted
# terrain, which this test has no use for.
class _StubGrid extends TileGrid:
	var occupants: Dictionary = {}
	func occupant_at(cell: Vector2i) -> Node2D:
		return occupants.get(cell)


class _StubPathfinder extends Pathfinder:
	var stub_grid: _StubGrid = _StubGrid.new()
	func grid() -> TileGrid:
		return stub_grid
	func is_walkable(_cell: Vector2i) -> bool:
		return true


var _codex: FloraCodex


func before_each() -> void:
	_codex = FloraCodex.new()
	add_child_autofree(_codex)


# A plant node of `kind`, off the tree (its _ready wants a Sprite2D and
# TimeManager). occupant_kind() reads data.id, which is all inspect asks.
func _plant(kind: StringName) -> Frailejon:
	var p := autofree(Frailejon.new()) as Frailejon
	p.data = ObjectPainter.data_for(kind) as PlantObjectData
	return p


func _ctx(cell: Vector2i, occupants: Dictionary, codex: Node = null) -> ActionContext:
	var pf := autofree(_StubPathfinder.new()) as _StubPathfinder
	for c: Vector2i in occupants:
		pf.stub_grid.occupants[c] = occupants[c]
	var ctx := ActionContext.new()
	ctx.cell = cell
	ctx.player_cell = cell
	ctx.pathfinder = pf
	ctx.flora_codex = codex
	return ctx


# --- FloraCodex ---------------------------------------------------------------

func test_discover_records_once() -> void:
	assert_false(_codex.is_known(&"chusquea"))
	assert_true(_codex.discover(&"chusquea"), "first sighting is new")
	assert_true(_codex.is_known(&"chusquea"))
	assert_false(_codex.discover(&"chusquea"), "a second look adds nothing")


func test_discover_emits_only_for_the_first_sighting() -> void:
	watch_signals(_codex)
	_codex.discover(&"hypericum")
	_codex.discover(&"hypericum")
	assert_signal_emit_count(_codex, "discovered", 1)


func test_known_ids_reports_discovery_order() -> void:
	_codex.discover(&"cortaderia")
	_codex.discover(&"frailejon")
	assert_eq(_codex.known_ids(), PackedStringArray(["cortaderia", "frailejon"]))


func test_empty_species_is_not_recorded() -> void:
	assert_false(_codex.discover(&""))
	assert_eq(_codex.known_ids().size(), 0)


# --- ActionInspect ------------------------------------------------------------

func test_inspect_applies_only_where_a_plant_stands() -> void:
	var a := ActionInspect.new()
	var cell := Vector2i(4, 4)
	assert_false(a.is_available(_ctx(cell, {}, _codex)),
		"bare ground has nothing to identify — the CellData readout is gone")
	assert_true(a.is_available(_ctx(cell, {cell: _plant(&"calamagrostis")}, _codex)))


func test_inspect_ignores_occupants_that_are_not_plants() -> void:
	var a := ActionInspect.new()
	var cell := Vector2i(2, 2)
	var rock := autofree(Rock.new()) as Rock
	rock.data = ObjectPainter.data_for(&"rock")
	assert_false(a.is_available(_ctx(cell, {cell: rock}, _codex)),
		"a rock is not a journal entry")


func test_inspect_reaches_the_cell_the_player_stands_on() -> void:
	# Plants don't block movement, so standing ON the tussock is the closest the
	# player can get. The default Chebyshev == 1 rule refuses exactly there.
	var a := ActionInspect.new()
	var cell := Vector2i(7, 3)
	var ctx := _ctx(cell, {cell: _plant(&"chusquea")}, _codex)
	ctx.player_cell = cell
	assert_true(a.is_available(ctx), "distance 0")
	ctx.player_cell = cell + Vector2i(1, 1)
	assert_true(a.is_available(ctx), "distance 1")
	ctx.player_cell = cell + Vector2i(2, 0)
	assert_false(a.is_available(ctx), "distance 2")


func test_executing_inspect_records_the_species() -> void:
	var a := ActionInspect.new()
	var cell := Vector2i(1, 1)
	a.execute(_ctx(cell, {cell: _plant(&"cortaderia")}, _codex))
	assert_true(_codex.is_known(&"cortaderia"))


func test_grasses_are_recorded_even_though_the_page_has_no_room_for_them() -> void:
	# The codex is the record of what was SEEN; what the journal prints is a
	# narrower question the page answers for itself.
	var a := ActionInspect.new()
	var cell := Vector2i(9, 9)
	a.execute(_ctx(cell, {cell: _plant(&"calamagrostis")}, _codex))
	assert_true(_codex.is_known(&"calamagrostis"))


func test_icon_marks_an_unrecorded_species() -> void:
	var a := ActionInspect.new()
	var cell := Vector2i(0, 5)
	var ctx := _ctx(cell, {cell: _plant(&"hypericum")}, _codex)
	var unknown_icon: Texture2D = a.icon_for(ctx)
	assert_ne(unknown_icon, a.icon, "an unrecorded plant gets its own glyph")
	_codex.discover(&"hypericum")
	assert_eq(a.icon_for(ctx), a.icon, "and the plain one once it is in the book")


func test_without_a_codex_nothing_is_unrecorded() -> void:
	# Preview tools and bare action tests carry no discovery system.
	var a := ActionInspect.new()
	var cell := Vector2i(3, 0)
	var ctx := _ctx(cell, {cell: _plant(&"frailejon")})
	assert_true(a.is_available(ctx))
	assert_eq(a.icon_for(ctx), a.icon)


func test_every_plant_names_itself() -> void:
	# execute() prints data.name_key; a species without one identifies silently.
	var a := ActionInspect.new()
	for kind: StringName in [&"frailejon", &"espeletia_barclayana",
			&"espeletia_hartwegiana", &"hypericum", &"arcytophyllum",
			&"calamagrostis", &"chusquea", &"cortaderia"]:
		var data: WorldObjectData = ObjectPainter.data_for(kind)
		assert_ne(String(data.name_key), "", "%s needs a name_key" % kind)
	assert_eq(a.id, &"inspect")


# --- The journal page ---------------------------------------------------------

class _JournalHarness:
	var journal: CanvasLayer
	var flora: JournalKnownSet
	var buildings: JournalKnownSet


func _open_journal() -> _JournalHarness:
	var h := _JournalHarness.new()
	h.journal = JOURNAL_SCENE.instantiate()
	add_child_autofree(h.journal)
	h.flora = h.journal.get_node("%KnownFlora") as JournalKnownSet
	h.buildings = h.journal.get_node("%KnownBuildings") as JournalKnownSet
	return h


func test_flora_page_starts_empty_and_fills_in() -> void:
	var h := _open_journal()
	# The codex binds deferred (it joins its group in its own _ready).
	await get_tree().process_frame
	assert_eq(h.flora.swatch_textures().size(), 0,
		"nothing identified yet, nothing printed")
	assert_gt(h.buildings.swatch_textures().size(), 0,
		"the buildings list is what you CAN build, and is complete from page one")

	_codex.discover(&"hypericum")
	await get_tree().process_frame
	assert_eq(h.flora.swatch_textures().size(), 1)
	assert_eq(h.flora.entry_id_at(0), &"hypericum",
		"the drawn entry answers with its own id, not the authored slot's")


func test_hidden_entries_close_the_row_up() -> void:
	var h := _open_journal()
	await get_tree().process_frame
	# arcytophyllum is the LAST authored flora entry; discovered alone it must be
	# the first drawn one, at the row's left edge, and it must be what a click
	# there buys.
	_codex.discover(&"arcytophyllum")
	await get_tree().process_frame
	assert_eq(h.flora.entry_id_at(0), &"arcytophyllum")
	assert_eq(h.flora.entry_at(h.flora.entry_rect(0).get_center()), 0)
	assert_eq(h.flora._swatches.size(), 1, "one swatch drawn, one cell used")


func test_authored_order_survives_the_order_things_were_found_in() -> void:
	var h := _open_journal()
	await get_tree().process_frame
	_codex.discover(&"arcytophyllum")
	_codex.discover(&"frailejon")
	await get_tree().process_frame
	assert_eq(h.flora.entry_id_at(0), &"frailejon",
		"the page keeps its authored layout; only the codex is chronological")
	assert_eq(h.flora.entry_id_at(1), &"arcytophyllum")


func test_the_page_prints_everything_without_a_codex() -> void:
	# What every preview tool and layout test renders — and what test_journal_*
	# assert against, so this is the guard on their premise.
	# Out of the group, not freed: `before_each` still owns it.
	_codex.remove_from_group(FloraCodex.GROUP)
	var h := _open_journal()
	await get_tree().process_frame
	assert_eq(h.flora.swatch_textures().size(), 5)
