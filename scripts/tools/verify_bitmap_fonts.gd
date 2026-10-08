@tool
extends SceneTree
## Proves the baked bitmap fonts draw the same pixels as the TTFs they replace.
## Every string in paramo.csv (both locales) plus a glyph line is drawn twice,
## once per font, at each size the game uses, at 1x and under 4x display
## oversampling (which the TTFs got and the fixed-size bakes skip). Exit 1 on any
## differing string. Needs a rendering context (no --headless):
##
##   godot --path . --script res://scripts/tools/verify_bitmap_fonts.gd -- --out /tmp/fonts
##
## The web build shapes with the fallback text server; the official editor binaries
## ship only the HarfBuzz one, so this runs there. That is the stricter test: the
## glyph rasters come from the same FreeType either way, and HarfBuzz also applies
## the TTF's GPOS kerning and GSUB, which the bitmap fonts do not carry. If an
## editor with "Fallback (Built-in)" is available, pass --text-driver to use it.
##
## The TTF side has system-font fallback turned off: the web build has no system
## fonts, so a glyph missing from the face is a missing glyph either way.
##
##   --out <dir>   where to write before/after crops of failing strings (default user://)

const CSV := "res://assets/translations/paramo.csv"
const EXTRA := "0123456789 .,:;!?¡¿'\"()-+/%·×—–…ÁÉÍÓÚÜÑáéíóúüñ"
const FACES: Array[Dictionary] = [
	{"ttf": "res://assets/fonts/Tiny5-Regular.ttf", "bmp": "res://assets/fonts/bitmap/tiny5_8.res", "sizes": [8, 16]},
	{"ttf": "res://assets/fonts/FantasticBoogaloo-GDlq.ttf", "bmp": "res://assets/fonts/bitmap/fantastic_boogaloo_16.res", "sizes": [16]},
]
const SCALES: Array[int] = [1, 4]
const PAGE_LINES := 48
const WIDTH := 1100

var _out_dir := "user://"


class Sheet extends Control:
	var font: Font
	var font_size: int
	var lines: PackedStringArray
	var line_h: int

	func _draw() -> void:
		for i in lines.size():
			draw_string(font, Vector2(2, i * line_h + font.get_ascent(font_size)), lines[i],
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)


func _initialize() -> void:
	var argv := OS.get_cmdline_user_args()
	for i in argv.size():
		if argv[i] == "--out" and i + 1 < argv.size():
			_out_dir = argv[i + 1]
	DirAccess.make_dir_recursive_absolute(_out_dir)
	_run.call_deferred()


func _strings() -> PackedStringArray:
	var out := PackedStringArray([EXTRA])
	var f := FileAccess.open(CSV, FileAccess.READ)
	f.get_csv_line()  # header
	while not f.eof_reached():
		var row := f.get_csv_line()
		for c in range(1, row.size()):
			for part in row[c].split("\n"):
				if part.strip_edges() != "" and not out.has(part):
					out.append(part)
	return out


func _run() -> void:
	print("verify_bitmap_fonts: text server '%s'" % TextServerManager.get_primary_interface().get_name())
	var strings := _strings()
	var failures := 0
	var checked := 0
	for face in FACES:
		var ttf := (load(face["ttf"]) as FontFile).duplicate() as FontFile
		ttf.allow_system_fallback = false
		var bmp := load(face["bmp"]) as Font
		for size: int in face["sizes"]:
			for scale in SCALES:
				for start in range(0, strings.size(), PAGE_LINES):
					var page := strings.slice(start, start + PAGE_LINES)
					var a := await _render(ttf, size, scale, page)
					var b := await _render(bmp, size, scale, page)
					# Two blank renders compare equal; white ink must be there.
					if a.get_data().count(255) == 0 or b.get_data().count(255) == 0:
						push_error("verify_bitmap_fonts: blank render (%s, %d px, x%d)" % [face["bmp"], size, scale])
						quit(1)
						return
					if start == 0:
						b.save_png(_out_dir.path_join("sample_%s_%d_x%d.png" % [face["bmp"].get_file().get_basename(), size, scale]))
					var line_px := (size + size / 2) * scale
					for i in page.size():
						checked += 1
						var band := Rect2i(0, i * line_px, a.get_width(), line_px)
						if _differs(a, b, band):
							failures += 1
							var tag := "%s_%d_x%d_%d" % [face["bmp"].get_file().get_basename(), size, scale, start + i]
							a.get_region(band).save_png(_out_dir.path_join(tag + "_ttf.png"))
							b.get_region(band).save_png(_out_dir.path_join(tag + "_bmp.png"))
							if failures <= 20:
								print("DIFF %s  \"%s\"" % [tag, page[i]])
	print("verify_bitmap_fonts: %d string renders compared, %d differ" % [checked, failures])
	quit(1 if failures > 0 else 0)


func _render(font: Font, size: int, scale: int, lines: PackedStringArray) -> Image:
	var line_h := size + size / 2
	var vp := SubViewport.new()
	vp.size = Vector2i(WIDTH * scale, line_h * lines.size() * scale)
	vp.transparent_bg = false
	vp.disable_3d = true
	vp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	vp.oversampling_override = float(scale)
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var sheet := Sheet.new()
	sheet.font = font
	sheet.font_size = size
	sheet.lines = lines
	sheet.line_h = line_h
	sheet.size = Vector2(WIDTH, line_h * lines.size())
	vp.add_child(sheet)
	root.add_child(vp)
	vp.canvas_transform = Transform2D.IDENTITY.scaled(Vector2(scale, scale))  # needs the viewport in the tree
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	vp.queue_free()
	return img


# Bands are full-width rows, so each is one contiguous run of the image's bytes.
func _differs(a: Image, b: Image, band: Rect2i) -> bool:
	var row_bytes := a.get_data_size() / a.get_height()
	var from := band.position.y * row_bytes
	var to := band.end.y * row_bytes
	return a.get_data().slice(from, to) != b.get_data().slice(from, to)
