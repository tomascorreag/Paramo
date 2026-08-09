extends SceneTree
## Renders the indexed visitor sheet through visitor_recolor.gdshader and diffs
## every pixel against the colours GDScript rolled for it. Exit 0 = identical.
##
## Why this exists rather than a unit test: a unit test can only check the
## colours somebody AUTHORED. The recolour has two halves that must agree and
## live in different languages — VisitorSlots' encoding constants in GDScript,
## and the copy of them in the shader — and nothing but a render can see whether
## the second half decodes what the first half wrote. The same pass also proves
## the sampled index values reach the shader untransformed, which the whole
## round()-based decode rests on and which no amount of reading the code
## establishes. (This is the same argument as verify_journal_palette.gd, which
## found a composited colour nobody had authored.)
##
## It checks three things per variant, on the REAL 768x32 sheet:
##   1. every opaque texel renders as the palette colour rolled for its slot/step
##   2. alpha survives (the silhouette is unchanged)
##   3. every emitted RGB is a palette2 entry — so a bad ramp stop in
##      visitor_palette.tres fails here too, not just in the unit test
##
## Needs a rendering context — do NOT pass --headless.
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/verify_visitor_palette.gd
##
## Args:
##   --sheet <res://path>   index sheet to check (default: Visitor_1_general.png)
##   --variants <n>         how many rolls to render (default 8)
##   --seed <n>             RNG seed (default 20260808), for reproducing a failure
##   --verbose              print each variant's resolved colours

const SHEET := "res://assets/sprites/characters/Visitor_1_general.png"
const PALETTE := "res://resources/characters/visitor_palette.tres"
const SHADER := "res://assets/shaders/visitor_recolor.gdshader"

## Rendered vs authored are both 8-bit, so this is really an equality check;
## the tolerance only absorbs the float round-trip through the GPU.
const TOL: float = 1.5 / 255.0

var _sheet_path: String = SHEET
var _variants: int = 8
var _seed: int = 20260808
var _verbose: bool = false

var _vp: SubViewport
var _sprite: Sprite2D
var _mat: ShaderMaterial
var _index: Image                       # the sheet read off disk, for expectations
var _palette: VisitorPalette
var _rng := RandomNumberGenerator.new()
var _expected: PackedColorArray         # current variant's resolved colours
var _step: int = 0
var _frames: int = 0
var _failures: int = 0


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("verify_visitor_palette needs a rendering context. Drop --headless.")
		quit(1)
		return

	var argv := OS.get_cmdline_user_args()
	for i in argv.size():
		match argv[i]:
			"--sheet":
				if i + 1 < argv.size(): _sheet_path = argv[i + 1]
			"--variants":
				if i + 1 < argv.size(): _variants = int(argv[i + 1])
			"--seed":
				if i + 1 < argv.size(): _seed = int(argv[i + 1])
			"--verbose":
				_verbose = true

	if current_scene != null:
		current_scene.queue_free()

	_index = Image.load_from_file(ProjectSettings.globalize_path(_sheet_path))
	if _index == null:
		push_error("could not read '%s' — run index_character_sheet.gd first." % _sheet_path)
		quit(1)
		return
	_index.convert(Image.FORMAT_RGBA8)

	_palette = load(PALETTE) as VisitorPalette
	if _palette == null:
		push_error("could not load %s" % PALETTE)
		quit(1)
		return

	_rng.seed = _seed

	var tex: Texture2D = load(_sheet_path)
	_vp = SubViewport.new()
	_vp.size = Vector2i(_index.get_width(), _index.get_height())
	_vp.transparent_bg = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.disable_3d = true
	_vp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	root.add_child(_vp)

	_mat = ShaderMaterial.new()
	_mat.shader = load(SHADER)

	_sprite = Sprite2D.new()
	_sprite.texture = tex
	_sprite.centered = false
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_sprite.material = _mat
	_vp.add_child(_sprite)

	print("sheet %s  %dx%d   %d variants, seed %d"
			% [_sheet_path, _index.get_width(), _index.get_height(), _variants, _seed])


# Two frames per variant: push the uniforms, let the viewport draw, read it back.
func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 3:
		return false
	if _step >= _variants:
		_finish()
		return true
	if (_frames % 2) == 1:
		var choices := VisitorAppearance.roll(_palette, _rng)
		_expected = VisitorAppearance.resolve(_palette, choices)
		VisitorAppearance.apply(_mat, _expected)
		if _verbose:
			_print_choices(_step, choices)
		return false
	_check(_step, _vp.get_texture().get_image())
	_step += 1
	return false


func _check(variant: int, got: Image) -> void:
	var bad_colour: int = 0
	var bad_alpha: int = 0
	var off_palette: Dictionary = {}
	var first_bad := ""

	for y in _index.get_height():
		for x in _index.get_width():
			var idx := _index.get_pixel(x, y)
			var out := got.get_pixel(x, y)
			if idx.a <= 0.0:
				if out.a > 0.0:
					bad_alpha += 1
				continue
			var pair := VisitorSlots.decode(idx)
			if pair[0] < 0:
				push_error("variant %d: sheet texel (%d,%d) does not decode — "
						% [variant, x, y] + "the sheet was not written by index_character_sheet.gd.")
				_failures += 1
				return
			var want: Color = _expected[VisitorSlots.uniform_index(pair[0], pair[1])]
			if absf(out.r - want.r) > TOL or absf(out.g - want.g) > TOL or absf(out.b - want.b) > TOL:
				bad_colour += 1
				if first_bad.is_empty():
					first_bad = "(%d,%d) %s step %d: want %s got %s" % [
						x, y, VisitorSlots.slot_name(pair[0]), pair[1],
						want.to_html(false), out.to_html(false)]
			if absf(out.a - idx.a) > TOL:
				bad_alpha += 1
			if not _in_palette(out):
				off_palette[out.to_html(false)] = int(off_palette.get(out.to_html(false), 0)) + 1

	if bad_colour == 0 and bad_alpha == 0 and off_palette.is_empty():
		print("variant %d  OK" % variant)
		return

	_failures += 1
	printerr("variant %d  FAIL" % variant)
	if bad_colour > 0:
		printerr("  %d texel(s) wrong colour; first: %s" % [bad_colour, first_bad])
		printerr("  -> the shader's decode disagrees with VisitorSlots. Check that")
		printerr("     visitor_recolor.gdshader still mirrors SLOT_R_STEP / STEP_G_*.")
	if bad_alpha > 0:
		printerr("  %d texel(s) wrong alpha — the silhouette changed." % bad_alpha)
	for hex: String in off_palette:
		printerr("  off-palette output %s x%d — fix the ramp stop in %s"
				% [hex, off_palette[hex], PALETTE])


static func _in_palette(c: Color) -> bool:
	for p in Palette.COLORS:
		if absf(c.r - p.r) <= TOL and absf(c.g - p.g) <= TOL and absf(c.b - p.b) <= TOL:
			return true
	return false


func _print_choices(variant: int, choices: Array) -> void:
	var parts: PackedStringArray = PackedStringArray()
	for slot in VisitorSlots.SLOT_COUNT:
		var ramps := _palette.slot_ramps(slot)
		var pick: Array = choices[slot]
		var label: String = "?" if pick[0] < 0 or pick[0] >= ramps.size() \
				else String(ramps[pick[0]].name)
		parts.append("%s=%s@%d" % [VisitorSlots.slot_name(slot), label, pick[1]])
	print("  variant %d  %s" % [variant, " ".join(parts)])


func _finish() -> void:
	if _failures == 0:
		print("\nall %d variant(s) identical to the rolled palette." % _variants)
		quit(0)
	else:
		printerr("\n%d of %d variant(s) failed." % [_failures, _variants])
		quit(1)
