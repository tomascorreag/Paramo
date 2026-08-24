extends GutTest

# Guards the UI foundation (scripts/ui/core): the layer registry, the Palette
# single-source-of-truth, and the shared PixelUI primitives.
#
# The most important check is layer-drift: .tscn files can't reference the
# UILayers constants, so a scene's authored `layer` can silently diverge from the
# registry. These tests instantiate the scenes WITHOUT adding them to the tree
# (so _ready never runs) and compare the authored value to the constant.

const HUD_SCENE: PackedScene = preload("res://scenes/ui/hud.tscn")
const DEBUG_SCENE: PackedScene = preload("res://scenes/ui/debug_overlay.tscn")
const TITLE_SCENE: PackedScene = preload("res://scenes/ui/title_intro.tscn")
const PAUSE_SCENE: PackedScene = preload("res://scenes/ui/pause_menu.tscn")
const JOURNAL_SCENE: PackedScene = preload("res://scenes/ui/field_journal.tscn")


# --- Layer registry ------------------------------------------------------------

func test_authored_scene_layers_match_registry() -> void:
	var hud: CanvasLayer = autofree(HUD_SCENE.instantiate())
	assert_eq(hud.layer, UILayers.HUD, "hud.tscn layer must match UILayers.HUD")

	var dbg: CanvasLayer = autofree(DEBUG_SCENE.instantiate())
	assert_eq(dbg.layer, UILayers.DEBUG, "debug_overlay.tscn layer must match UILayers.DEBUG")

	var title: CanvasLayer = autofree(TITLE_SCENE.instantiate())
	assert_eq(title.layer, UILayers.TITLE, "title_intro.tscn layer must match UILayers.TITLE")

	var pause: CanvasLayer = autofree(PAUSE_SCENE.instantiate())
	assert_eq(pause.layer, UILayers.PAUSE, "pause_menu.tscn layer must match UILayers.PAUSE")

	var journal: CanvasLayer = autofree(JOURNAL_SCENE.instantiate())
	assert_eq(journal.layer, UILayers.JOURNAL, "field_journal.tscn layer must match UILayers.JOURNAL")


func test_no_two_layers_collide() -> void:
	var layers: Array[int] = [
		UILayers.POST_PROCESS,
		UILayers.FIRE_AURA,
		UILayers.HUD,
		UILayers.TOAST,
		UILayers.RADIAL_MENU,
		UILayers.JOURNAL,
		UILayers.TUTORIAL,
		UILayers.PAUSE,
		UILayers.LOADING,
		UILayers.TITLE,
		UILayers.DEBUG,
	]
	var seen: Dictionary = {}
	for l in layers:
		assert_false(seen.has(l), "duplicate UILayers value: %d" % l)
		seen[l] = true


# --- Palette -------------------------------------------------------------------

func test_palette_has_33_entries() -> void:
	assert_eq(Palette.COLORS.size(), 33)


func test_palette_index_32_duplicates_00() -> void:
	assert_eq(Palette.at(32), Palette.at(0))


func test_palette_at_clamps_out_of_range() -> void:
	assert_eq(Palette.at(-5), Palette.at(0))
	assert_eq(Palette.at(999), Palette.at(32))


func test_palette_with_alpha_keeps_rgb() -> void:
	var c := Palette.with_alpha(Palette.PANEL_BG, 0.5)
	assert_eq(c.r, Palette.PANEL_BG.r)
	assert_eq(c.g, Palette.PANEL_BG.g)
	assert_eq(c.b, Palette.PANEL_BG.b)
	assert_almost_eq(c.a, 0.5, 0.0001)


# --- PixelUI -------------------------------------------------------------------

func test_frame_stylebox_has_unit_margins() -> void:
	var sb := PixelUI.frame_stylebox(Palette.BORDER, Palette.PANEL_BG)
	assert_is(sb, StyleBoxTexture)
	assert_eq(sb.texture_margin_left, 1.0)
	assert_eq(sb.texture_margin_top, 1.0)
	assert_eq(sb.texture_margin_right, 1.0)
	assert_eq(sb.texture_margin_bottom, 1.0)


func test_frame_stylebox_is_cached() -> void:
	var a := PixelUI.frame_stylebox(Palette.ACCENT, Palette.SURFACE)
	var b := PixelUI.frame_stylebox(Palette.ACCENT, Palette.SURFACE)
	assert_same(a, b, "identical (border, fill) must return the cached instance")


func test_atlas_stylebox_margins_and_cache() -> void:
	var region := Rect2(0, 16, 16, 16)
	var a := PixelUI.atlas_stylebox(region, 4, Palette.PANEL_BG)
	assert_is(a, StyleBoxTexture)
	assert_eq(a.texture_margin_left, 4.0)
	assert_eq(a.texture_margin_top, 4.0)
	assert_eq(a.texture_margin_right, 4.0)
	assert_eq(a.texture_margin_bottom, 4.0)
	var b := PixelUI.atlas_stylebox(region, 4, Palette.PANEL_BG)
	assert_same(a, b, "identical (region, margin, tint) must return the cached instance")


func test_make_icon_fill_is_nearest() -> void:
	var tex := PlaceholderTexture2D.new()
	var r: TextureRect = autofree(PixelUI.make_icon_fill(tex))
	assert_eq(r.texture_filter, CanvasItem.TEXTURE_FILTER_NEAREST)
	assert_eq(r.mouse_filter, Control.MOUSE_FILTER_IGNORE)


func test_make_icon_sized_matches_texture_size() -> void:
	var tex := PlaceholderTexture2D.new()
	tex.size = Vector2(16, 16)
	var r: TextureRect = autofree(PixelUI.make_icon_sized(tex))
	assert_eq(r.size, Vector2(16, 16))
	assert_eq(r.texture_filter, CanvasItem.TEXTURE_FILTER_NEAREST)
