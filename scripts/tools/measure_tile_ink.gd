extends SceneTree
## Measures where a tile's ART lands relative to the CELL it is painted on, in
## texels, by rendering that one tile alone on an empty TileMapLayer.
##
## What it is for: every tile in base_tileset.tres carries a `texture_origin`,
## and for the 1x2 (32x32 art on a 32x16 cell) tiles that number is the whole
## difference between a structure standing ON the ground and one floating over
## it or sunk into it. There is nothing in the editor to check it against — the
## tileset panel shows the art with no ground under it — and nothing in a
## gameplay screenshot either, because neighbouring tiles occlude the answer
## (measured: the same fence tile reads 11 texels shorter at one y_sort_origin
## than another, purely from what draws over it).
##
## So: one tile, one empty layer, no neighbours, no camera, no atmosphere. The
## reported box is ground truth about the authoring and nothing else.
##
## Read the numbers against the diamond, which is 32x16 and therefore spans
## x -16..+16 and y -8..+8 from the cell centre, with its four apexes at
## (0, ±8) and (±16, 0). Useful landmarks on that diamond:
##
##   y = +8   the S apex — the lowest point of the cell's own floor
##   y = ±4   the midpoints of the four edges, i.e. where a cell's boundary
##            with a diagonal neighbour crosses
##   y = 0    the E and W apexes, and the visual centre
##
## Needs a rendering context — do NOT pass --headless.
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/measure_tile_ink.gd
##
## Args:
##   --kinds A,B,C   tile_kind names to measure (default: the structure set)
##   --source <n>    atlas source id (default 1, the wood/structures source)

const TILESET := "res://resources/tiles/base_tileset.tres"

## Big enough that a 32x32 tile centred in it can never touch an edge, which
## would silently clip the box being measured.
const VIEW := Vector2i(128, 128)

var _kinds: PackedStringArray = PackedStringArray([
	"FLAT", "HALF_STAIR_NE", "LADDER_NE", "FENCE_NE", "FENCE_NW",
])
var _source: int = 1
var _vp: SubViewport
var _layer: TileMapLayer
var _index: TileKindIndex
var _cell := Vector2i.ZERO
var _origin: Vector2
var _step: int = 0
var _frames: int = 0
var _blank: Image


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("measure_tile_ink needs a rendering context. Drop --headless.")
		quit(1)
		return

	var argv := OS.get_cmdline_user_args()
	for i in argv.size():
		match argv[i]:
			"--kinds":
				if i + 1 < argv.size(): _kinds = argv[i + 1].split(",")
			"--source":
				if i + 1 < argv.size(): _source = int(argv[i + 1])

	if current_scene != null:
		current_scene.queue_free()

	var tile_set: TileSet = load(TILESET)
	_index = TileKindIndex.new(tile_set, _source)

	_vp = SubViewport.new()
	_vp.size = VIEW
	_vp.transparent_bg = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.disable_3d = true
	_vp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	root.add_child(_vp)

	_layer = TileMapLayer.new()
	_layer.tile_set = tile_set
	# Park the cell in the middle of the viewport. map_to_local gives the cell's
	# CENTRE in layer space, which is the origin every number is reported against.
	_layer.position = Vector2(VIEW) * 0.5 - _layer.map_to_local(_cell)
	_vp.add_child(_layer)
	_origin = Vector2(VIEW) * 0.5


# One kind per pair of frames: draw nothing (or the previous kind erased) and
# capture the blank, then paint and capture. Diffing against a freshly captured
# blank rather than a constant means a tile with a MATERIAL (the water and wind
# tiles animate) is still measured against the right background.
func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 3:
		return false
	if _step >= _kinds.size():
		quit(0)
		return true
	if (_frames % 2) == 1:
		_blank = _vp.get_texture().get_image()
		var kind := StringName(_kinds[_step])
		var coord := _index.coord(kind)
		if TileKindIndex.is_unset(coord):
			printerr("%-16s not painted on source %d." % [kind, _source])
			_step += 1
			return false
		_layer.set_cell(_cell, _source, coord)
		return false
	_report(StringName(_kinds[_step]), _vp.get_texture().get_image())
	_layer.erase_cell(_cell)
	_step += 1
	return false


func _report(kind: StringName, img: Image) -> void:
	var box := Rect2i()
	var any := false
	for y in img.get_height():
		for x in img.get_width():
			# Alpha, not colour: the viewport is transparent, so any inked texel
			# of the tile is the only thing that can be opaque.
			if img.get_pixel(x, y).a <= 0.0:
				continue
			var p := Vector2i(x, y)
			box = Rect2i(p, Vector2i.ONE) if not any else box.expand(p)
			any = true
	if not any:
		printerr("%-16s painted but drew nothing." % kind)
		return
	print("%-16s x %+5.1f .. %+5.1f    y %+5.1f .. %+5.1f" % [
		kind,
		box.position.x - _origin.x, box.end.x - 1 - _origin.x,
		box.position.y - _origin.y, box.end.y - 1 - _origin.y,
	])
