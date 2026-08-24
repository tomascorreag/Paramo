@tool
extends SceneTree

# ============================================================================
# index_character_sheet.gd — CLI tool
# ============================================================================
#
# Turns an authored character spritesheet into the INDEX sheet the recolour
# shader eats: every opaque texel's colour is looked up in
# VisitorSlots.SOURCE_COLOURS and rewritten as VisitorSlots.encode(slot, step).
#
# Why a tool instead of hand-painting the index sheet: the mapping is
# mechanical, and doing it by hand means the index sheet and the art can drift
# apart with nothing to notice. Re-run this after any repaint — it is one
# command, and an unrecognised colour is a hard failure with coordinates
# rather than a silently dropped body part.
#
# The output looks like a near-black silhouette in any image viewer. That is
# correct; it is data. Use scripts/tools/preview_visitor_palettes.gd to look
# at what it renders as.
#
# Usage:
#   godot --headless --script res://scripts/tools/index_character_sheet.gd
#   godot --headless --script res://scripts/tools/index_character_sheet.gd -- \
#       --in res://assets/sprites/characters/campesino.png \
#       --out res://assets/sprites/characters/campesino_general.png
#
# Args:
#   --in  <res://path>   source sheet   (default: Visitor_1.png)
#   --out <res://path>   index sheet    (default: <in stem>_general.png)
#   --dry-run            report the colour census, write nothing
#
# Exit code 0 on success, 1 if the source uses a colour not in the schema.
#
# NOTE the source is read with Image.load_from_file, NOT load() — the imported
# CompressedTexture2D is the engine's copy, and reading the PNG off disk keeps
# this independent of import settings. The written PNG needs an editor import
# pass before anything can `load()` it (--headless --import, or just open the
# editor once).
#
# ============================================================================

const DEFAULT_IN: String = "res://assets/sprites/characters/Visitor_1.png"


func _initialize() -> void:
	var args := _parse_args()
	var src_path: String = args.get("in", DEFAULT_IN)
	var out_path: String = args.get("out", _default_out(src_path))
	var dry_run: bool = args.has("dry-run")

	var img := Image.load_from_file(ProjectSettings.globalize_path(src_path))
	if img == null:
		push_error("index_character_sheet: could not read '%s'." % src_path)
		quit(1)
		return

	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	print("source  %s  %dx%d" % [src_path, w, h])

	var out := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	var census: Dictionary = {}      # "RRGGBB" -> pixel count
	var unknown: Dictionary = {}     # "RRGGBB" -> first Vector2i seen
	var unknown_total: int = 0

	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			if c.a <= 0.0:
				out.set_pixel(x, y, Color(0.0, 0.0, 0.0, 0.0))
				continue
			var hex := _hex(c)
			census[hex] = int(census.get(hex, 0)) + 1
			if not VisitorSlots.SOURCE_COLOURS.has(hex):
				unknown_total += 1
				if not unknown.has(hex):
					unknown[hex] = Vector2i(x, y)
				out.set_pixel(x, y, Color(0.0, 0.0, 0.0, 0.0))
				continue
			var pair: Array = VisitorSlots.SOURCE_COLOURS[hex]
			var enc := VisitorSlots.encode(pair[0], pair[1])
			enc.a = c.a
			out.set_pixel(x, y, enc)

	_report(census, unknown)

	if unknown_total > 0:
		push_error("index_character_sheet: %d texel(s) in %d unmapped colour(s). " % [unknown_total, unknown.size()]
				+ "Add them to VisitorSlots.SOURCE_COLOURS (and a ramp to VisitorPalette) "
				+ "or repaint them onto an existing slot.")
		quit(1)
		return

	if dry_run:
		print("dry run — nothing written")
		quit(0)
		return

	var err := out.save_png(ProjectSettings.globalize_path(out_path))
	if err != OK:
		push_error("index_character_sheet: save_png('%s') failed with %d." % [out_path, err])
		quit(1)
		return

	print("wrote   %s" % out_path)
	print("Run the editor (or --headless --import) once so Godot imports it.")
	quit(0)


func _report(census: Dictionary, unknown: Dictionary) -> void:
	var hexes: Array = census.keys()
	hexes.sort_custom(func(a: String, b: String) -> bool:
		return int(census[a]) > int(census[b]))
	print("colour census (%d distinct opaque colours):" % hexes.size())
	for hex: String in hexes:
		if VisitorSlots.SOURCE_COLOURS.has(hex):
			var pair: Array = VisitorSlots.SOURCE_COLOURS[hex]
			print("  %s  %7d px  -> %s step %d"
					% [hex, census[hex], VisitorSlots.slot_name(pair[0]), pair[1]])
		else:
			print("  %s  %7d px  -> UNMAPPED, first seen at %s"
					% [hex, census[hex], unknown.get(hex, Vector2i.ZERO)])


static func _hex(c: Color) -> String:
	return "%02X%02X%02X" % [
		int(roundf(c.r * 255.0)),
		int(roundf(c.g * 255.0)),
		int(roundf(c.b * 255.0)),
	]


static func _default_out(src: String) -> String:
	return src.get_basename() + "_general." + src.get_extension()


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
