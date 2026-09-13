@tool
extends SceneTree

# ============================================================================
# bake_flora_photos.gd — CLI tool
# ============================================================================
#
# Shrinks the CC0 herbarium-sheet photographs in assets/photos/flora/ to the
# size the journal's bitacora page prints them at, and writes them as PNGs
# under assets/sprites/flora/photos/. The page prints them AS PHOTOGRAPHS —
# a polaroid stuck into the notebook — over the book at window resolution
# (JournalPhotoFloat), so the bake is FOUR TIMES the polaroid's 54x54 logical
# window: 216x216, one texture pixel per physical pixel at the 4x upscale. The
# JPGs themselves are reference material and are excluded from the export.
#
# Two PICTURES per species, two copies each: `<id>.png` is the herbarium
# sheet (`<id>_dry.jpg`) and `<id>_live.png` the field photograph
# (`<id>_live.jpg`); `<id>_palette.png` and `<id>_live_palette.png` are the
# same pixels SNAPPED to the nearest of the 33 palette2 entries (nearest by
# RGB distance; no dithering). The page currently shows the palette ones — an
# experiment in whether a photograph can sit in the palette without becoming
# an ink print — and `PlantObjectData.photo` / `photo_live` say which.
#
# A species with no field photo (E. barclayana: GBIF holds twelve
# observations with images and every one is CC BY-NC) gets a DETAIL of its
# sheet as the second picture — the central half of the sheet at twice the
# magnification — so both polaroids are always on the page.
#
# The PNGs import LOSSY (compress/mode=1, see the .import beside each): they
# are photographs, not pixel art, and eight lossless 256x288 PNGs would add
# ~0.8 MB to a 1.5 MB pck. A NEW species' PNG gets the project's lossless
# default — copy an existing .import beside it.
#
# Why offline: Godot's importer cannot resize, and a 640px JPEG scaled down on
# the GPU at draw time would be resampled by nearest filtering (the page's
# SubViewport is NEAREST) into aliasing noise. A 16x reduction needs an
# averaging kernel, hence LANCZOS here; the posterising is the ink ramps' job,
# not the resampler's.
#
# The sheet slot prefers `<id>_dry.jpg` (a GBIF herbarium sheet — the page is
# a field notebook and the specimen is what gets pressed into one) and falls
# back to `<id>_live.jpg`; the field slot prefers `_live` and falls back to a
# detail of `_dry`. Species are enumerated from the photo FILENAMES in the
# input directory, not from resources/objects/*.tres: those resources
# reference the baked PNGs, so loading them before the first bake fails on
# the very files this tool exists to write.
#
# Usage:
#   godot --headless --script res://scripts/tools/bake_flora_photos.gd
#   godot --headless --script res://scripts/tools/bake_flora_photos.gd -- --size 216x216
#
# Args:
#   --size <WxH>   print size (default 216x216)
#   --in  <dir>    source directory (default res://assets/photos/flora)
#   --out <dir>    output directory (default res://assets/sprites/flora/photos)
#
# The written PNGs need an import pass before anything can load() them:
#   godot --headless --import
#
# ============================================================================

const DEFAULT_IN: String = "res://assets/photos/flora"
const DEFAULT_OUT: String = "res://assets/sprites/flora/photos"
const PALETTE_PATH: String = "res://assets/palettes/palette2.txt"
## Side fraction kept for a detail crop (0.5: the central quarter, 2x).
const DETAIL_FRACTION: float = 0.5


func _initialize() -> void:
	var args := _parse_args()
	var size := _parse_size(String(args.get("size", "216x216")))
	var in_dir: String = args.get("in", DEFAULT_IN)
	var out_dir: String = args.get("out", DEFAULT_OUT)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))

	var palette := _load_palette()
	if palette.is_empty():
		push_error("bake_flora_photos: no palette at %s" % PALETTE_PATH)
		quit(1)
		return
	var failures: int = 0
	var written: int = 0
	for id: String in _species_ids(in_dir):
		# [output stem, preferred suffix, fallback suffix, detail when falling back]
		for slot: Array in [[id, "_dry.jpg", "_live.jpg", false],
				[id + "_live", "_live.jpg", "_dry.jpg", true]]:
			var src := _pick_source(in_dir, id, slot[1], slot[2])
			if src.is_empty():
				push_warning("bake_flora_photos: no photo for '%s' in %s" % [id, in_dir])
				failures += 1
				continue
			var img := Image.load_from_file(ProjectSettings.globalize_path(src))
			if img == null:
				push_error("bake_flora_photos: could not read '%s'" % src)
				failures += 1
				continue
			img.convert(Image.FORMAT_RGB8)
			var detail: bool = slot[3] and not src.ends_with(slot[1])
			if detail:
				_crop_to_centre(img, DETAIL_FRACTION)
			_crop_to_aspect(img, size)
			img.resize(size.x, size.y, Image.INTERPOLATE_LANCZOS)
			var out := "%s/%s.png" % [out_dir, slot[0]]
			var err := img.save_png(ProjectSettings.globalize_path(out))
			if err != OK:
				push_error("bake_flora_photos: could not write '%s' (%d)" % [out, err])
				failures += 1
				continue
			var snapped := _snap_to_palette(img, palette)
			var out_pal := "%s/%s_palette.png" % [out_dir, slot[0]]
			if snapped.save_png(ProjectSettings.globalize_path(out_pal)) != OK:
				push_error("bake_flora_photos: could not write '%s'" % out_pal)
				failures += 1
				continue
			written += 1
			print("  %-30s %s%s -> %s + %s  %dx%d" % [slot[0], src.get_file(),
					" (detail)" if detail else "", out.get_file(), out_pal.get_file(),
					size.x, size.y])
	print("bake_flora_photos: %d written, %d failed" % [written, failures])
	quit(1 if failures > 0 else 0)


# Every `<id>` with a `<id>_dry.jpg` or `<id>_live.jpg` in `in_dir`.
func _species_ids(in_dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(in_dir)
	if dir == null:
		return out
	for f: String in dir.get_files():
		for suffix: String in ["_dry.jpg", "_live.jpg"]:
			if f.ends_with(suffix):
				var id := f.trim_suffix(suffix)
				if not out.has(id):
					out.append(id)
	out.sort()
	return out


func _pick_source(in_dir: String, id: String, first: String, second: String) -> String:
	for suffix: String in [first, second]:
		var p := "%s/%s%s" % [in_dir, id, suffix]
		if FileAccess.file_exists(p):
			return p
	return ""


# Keeps the central `fraction` of each side: the sheet's specimen at twice
# the magnification, for a species with no field photo.
static func _crop_to_centre(img: Image, fraction: float) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var cw: int = maxi(1, int(roundf(float(w) * fraction)))
	var ch: int = maxi(1, int(roundf(float(h) * fraction)))
	var cropped := img.get_region(Rect2i((w - cw) / 2, (h - ch) / 2, cw, ch))
	img.copy_from(cropped)


# Centre-crops the image to the target's aspect so the resize never squashes.
static func _crop_to_aspect(img: Image, size: Vector2i) -> void:
	var w := img.get_width()
	var h := img.get_height()
	var target: float = float(size.x) / float(size.y)
	var cw: int = w
	var ch: int = h
	if float(w) / float(h) > target:
		cw = int(roundf(float(h) * target))
	else:
		ch = int(roundf(float(w) / target))
	var x: int = (w - cw) / 2
	var y: int = (h - ch) / 2
	var cropped := img.get_region(Rect2i(x, y, cw, ch))
	img.copy_from(cropped)


# The 33 palette entries, from the human-readable mirror of palette2.aseprite
# ("NN: RRGGBB" lines; comments start with #).
static func _load_palette() -> Array[Color]:
	var out: Array[Color] = []
	var f := FileAccess.open(PALETTE_PATH, FileAccess.READ)
	if f == null:
		return out
	var re := RegEx.new()
	re.compile("^\\s*\\d+:\\s*([0-9A-Fa-f]{6})\\s*$")
	while not f.eof_reached():
		var m := re.search(f.get_line())
		if m != null:
			out.append(Color.html(m.get_string(1)))
	return out


# Every pixel replaced by the nearest palette entry, by squared RGB distance.
# Plain RGB rather than a perceptual space, deliberately: this is an
# experiment in what the palette does to a photograph, and the simplest
# mapping is the one whose result can be reasoned about.
static func _snap_to_palette(img: Image, palette: Array[Color]) -> Image:
	var out := Image.create(img.get_width(), img.get_height(), false, Image.FORMAT_RGB8)
	for y: int in img.get_height():
		for x: int in img.get_width():
			var c := img.get_pixel(x, y)
			var best := palette[0]
			var best_d: float = INF
			for pc: Color in palette:
				var dr := c.r - pc.r
				var dg := c.g - pc.g
				var db := c.b - pc.b
				var d := dr * dr + dg * dg + db * db
				if d < best_d:
					best_d = d
					best = pc
			out.set_pixel(x, y, best)
	return out


static func _parse_size(s: String) -> Vector2i:
	var parts := s.to_lower().split("x")
	if parts.size() != 2:
		return Vector2i(216, 216)
	return Vector2i(maxi(1, int(parts[0])), maxi(1, int(parts[1])))


## `--key value` pairs plus bare `--flag`s, from everything after `--`.
static func _parse_args() -> Dictionary:
	var out: Dictionary = {}
	var raw := OS.get_cmdline_user_args()
	var i := 0
	while i < raw.size():
		var a: String = raw[i]
		if not a.begins_with("--"):
			i += 1
			continue
		var key := a.substr(2)
		if i + 1 < raw.size() and not raw[i + 1].begins_with("--"):
			out[key] = raw[i + 1]
			i += 2
		else:
			out[key] = true
			i += 1
	return out
