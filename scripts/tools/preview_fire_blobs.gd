extends SceneTree
## Renders assets/shaders/fire_blobs.gdshader to a PNG so the blob fire can be
## eyeballed without launching the game and waiting for an ignition.
##
## Spawns a row of FireBlobColumns spanning kindling (left) -> wildfire (right)
## at the real FireBlobTuning values, on the palette's darkest background, then
## saves N frames spaced in time so the animation can be read as a strip.
##
## The output is upscaled with NEAREST by PIXEL_SCALE. That is not cosmetic: the
## whole point of this effect is that its faux-pixels are locked to the tile
## texel grid, and at 1:1 you cannot see whether that's true. Any smoothing or
## sub-pixel drift is immediately obvious at 4x.
##
## Needs a rendering context — do NOT pass --headless.
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/preview_fire_blobs.gd
##
## Args:
##   --out <dir>        output directory (default: user://)
##   --frames <n>       how many PNGs to save (default 3)
##   --interval <n>     engine frames between saves (default 20)
##   --ceiling <f>      heat_ceiling: 1.0 fire, 0.55 burning down, 0.2 smoke only
##   --wind <f>         sets the wind_lean (mean) global; +/-0.11 (MAX_WIND_MEAN) is a
##                      full storm. Pair with --debug 3 to confirm leaning tips stay in-quad.
##   --gust <f>         sets the wind_gust amplitude global; 0.07 (MAX_WIND_GUST) is a full
##                      storm. Animated (needs --frames >1 to see it sway across the noise field).
##   --debug <n>        sets the shader_debug global (1 stages, 2 world snap, 3 quad)

const COLUMN_SCRIPT: GDScript = preload("res://scripts/vfx/fire_blob_column.gd")

const VIEW_SIZE := Vector2i(320, 240)
const PIXEL_SCALE := 4
const COLUMN_COUNT := 5
const SPACING := 64.0
# Palette P30 #14233A — the darkest entry, and what the game actually sits on at
# night. Fire on white would flatter the bright stages and hide the char one.
const BG := Color(0.078431375, 0.13725491, 0.22745098, 1.0)
const WARMUP_FRAMES := 30

var _out_dir: String = "user://"
var _want_frames: int = 3
var _interval: int = 20
var _ceiling: float = 1.0
var _frame: int = 0
var _saved: int = 0
var _vp: SubViewport


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("preview_fire_blobs needs a rendering context. Drop --headless.")
		quit(1)
		return

	var argv := OS.get_cmdline_user_args()
	var debug_mode := 0
	var wind_lean := 0.0
	var wind_gust := 0.0
	for i in argv.size() - 1:
		match argv[i]:
			"--out": _out_dir = argv[i + 1]
			"--frames": _want_frames = int(argv[i + 1])
			"--interval": _interval = int(argv[i + 1])
			"--ceiling": _ceiling = float(argv[i + 1])
			"--wind": wind_lean = float(argv[i + 1])
			"--gust": wind_gust = float(argv[i + 1])
			"--debug": debug_mode = int(argv[i + 1])
	if not _out_dir.ends_with("/"):
		_out_dir += "/"
	RenderingServer.global_shader_parameter_set(&"shader_debug", debug_mode)
	RenderingServer.global_shader_parameter_set(&"wind_lean", wind_lean)
	RenderingServer.global_shader_parameter_set(&"wind_gust", wind_gust)

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	_vp = SubViewport.new()
	_vp.size = VIEW_SIZE
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.disable_3d = true
	root.add_child(_vp)

	var bg := ColorRect.new()
	bg.size = Vector2(VIEW_SIZE)
	bg.color = BG
	_vp.add_child(bg)

	for i in COLUMN_COUNT:
		var t: float = float(i) / float(COLUMN_COUNT - 1)
		var col: FireBlobColumn = COLUMN_SCRIPT.new()
		# Columns rise from their origin, so sit them near the bottom.
		col.position = Vector2(
			float(VIEW_SIZE.x) * 0.5 + (float(i) - float(COLUMN_COUNT - 1) * 0.5) * SPACING,
			float(VIEW_SIZE.y) - 20.0)
		col.set_cell_seed(FireBlobColumn.seed_for_cell(Vector2i(i * 13, 7)))
		_vp.add_child(col)
		col.set_intensity(t)
		col.set_heat_ceiling(_ceiling)

	print("fire_blobs preview")
	print("  device:      %s" % RenderingServer.get_video_adapter_name())
	print("  columns:     %d, intensity 0.0 -> 1.0 left to right" % COLUMN_COUNT)
	print("  heat_ceiling: %.2f" % _ceiling)
	print("  wind_lean:    %.3f" % wind_lean)
	print("  wind_gust:    %.3f" % wind_gust)
	print("  shader_debug: %d" % debug_mode)
	print("  out:         %s (%dx upscaled, NEAREST)" % [_out_dir, PIXEL_SCALE])
	print("")


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < WARMUP_FRAMES:
		return false
	if (_frame - WARMUP_FRAMES) % _interval != 0:
		return false

	var img: Image = _vp.get_texture().get_image()
	# NEAREST — see the header. A smoothing resize here would hide the exact
	# defect this tool exists to catch.
	img.resize(VIEW_SIZE.x * PIXEL_SCALE, VIEW_SIZE.y * PIXEL_SCALE, Image.INTERPOLATE_NEAREST)
	var path: String = "%sfire_blobs_%02d.png" % [_out_dir, _saved]
	var err: int = img.save_png(path)
	if err != OK:
		push_error("save_png failed (%d) for %s" % [err, path])
		quit(1)
		return true
	print("  saved %s" % path)

	_saved += 1
	if _saved >= _want_frames:
		quit(0)
		return true
	return false
