@tool
extends SceneTree
## Bakes each shipped TTF into a bitmap-only FontFile: every glyph the face has,
## rasterised once at the face's native em, with no outline data left in the
## resource. The web engine is built without FreeType (engine/paramo_web.py), so
## it can draw these and cannot draw the TTFs.
##
##   godot --headless --path . --script res://scripts/tools/bake_bitmap_fonts.gd
##
## Re-run after swapping a TTF or changing its import settings, then --import.
##
## The baked font is fixed_size at the em with integer-only scaling, so 16 px
## Tiny5 is the 8 px glyphs doubled. Fixed-size fonts also skip the display's
## oversampling, which is what makes them safe to ship without a rasteriser: the
## text server never asks for a size that was not baked. For a pixel face drawn on
## its em grid with antialiasing off, doubling and rasterising at 16 give the same
## pixels; check with the journal / pause / language-gate previews.
##
## Glyphs are keyed by character code, the way bitmap fonts work in both text
## servers, and kerning is not carried over: the web build's fallback text server
## only ever read the legacy `kern` table, which neither face has.
##
## Exit code 0 on success, 1 if any face failed.

const FACES: Array[Dictionary] = [
	{"src": "res://assets/fonts/Tiny5-Regular.ttf", "em": 8,
		"dst": "res://assets/fonts/bitmap/tiny5_8.res"},
	{"src": "res://assets/fonts/FantasticBoogaloo-GDlq.ttf", "em": 16,
		"dst": "res://assets/fonts/bitmap/fantastic_boogaloo_16.res"},
]


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://assets/fonts/bitmap"))
	var failed := 0
	for face in FACES:
		if not _bake(face["src"], face["em"], face["dst"]):
			failed += 1
	quit(1 if failed > 0 else 0)


func _bake(src_path: String, em: int, dst_path: String) -> bool:
	var src := load(src_path) as FontFile
	if src == null:
		push_error("bake_bitmap_fonts: cannot load %s" % src_path)
		return false
	var size := Vector2i(em, 0)
	var chars := src.get_supported_chars()

	var dst := FontFile.new()
	dst.font_name = src.font_name
	dst.font_style = src.font_style
	dst.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	dst.hinting = TextServer.HINTING_NONE
	dst.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	dst.generate_mipmaps = false
	dst.multichannel_signed_distance_field = false
	dst.allow_system_fallback = false
	dst.fixed_size = em
	dst.fixed_size_scale_mode = TextServer.FIXED_SIZE_SCALE_INTEGER_ONLY

	# Rasterise everything first so every glyph's atlas page exists before copying.
	for c in chars.length():
		src.render_glyph(0, size, src.get_glyph_index(em, chars.unicode_at(c), 0))

	dst.set_cache_ascent(0, em, src.get_cache_ascent(0, em))
	dst.set_cache_descent(0, em, src.get_cache_descent(0, em))
	dst.set_cache_underline_position(0, em, src.get_cache_underline_position(0, em))
	dst.set_cache_underline_thickness(0, em, src.get_cache_underline_thickness(0, em))
	for t in src.get_texture_count(0, size):
		dst.set_texture_image(0, size, t, src.get_texture_image(0, size, t))

	var copied := 0
	for c in chars.length():
		var code := chars.unicode_at(c)
		var g := src.get_glyph_index(em, code, 0)
		if g == 0:
			continue
		dst.set_glyph_advance(0, em, code, src.get_glyph_advance(0, em, g))
		dst.set_glyph_offset(0, size, code, src.get_glyph_offset(0, size, g))
		dst.set_glyph_size(0, size, code, src.get_glyph_size(0, size, g))
		dst.set_glyph_uv_rect(0, size, code, src.get_glyph_uv_rect(0, size, g))
		dst.set_glyph_texture_idx(0, size, code, src.get_glyph_texture_idx(0, size, g))
		copied += 1

	var err := ResourceSaver.save(dst, dst_path)
	if err != OK:
		push_error("bake_bitmap_fonts: cannot save %s (err %d)" % [dst_path, err])
		return false
	print("bake_bitmap_fonts: %s -> %s, %d glyphs at %d px, %d atlas page(s)" % [
		src_path.get_file(), dst_path.get_file(), copied, em, src.get_texture_count(0, size)])
	return true
