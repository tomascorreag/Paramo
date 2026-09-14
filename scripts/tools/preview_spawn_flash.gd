extends SceneTree
## Renders the placement / discovery flash (SpawnFlash) as a strip of stills, one
## per moment of the tween, for a planted plant, a discovered plant and a built
## fence — the three things that flash. Look at it after touching
## flash_common.gdshaderinc, the SpawnFlash timeline, or the y-sort of the
## structure layers.
##
## What to look for:
##   - PLANT PLACED: still 0 is empty ground, then the plant ARRIVES as a 4x4
##     dither gradient sweeping across it at its REAL colours (away from the
##     stand-in player, which is the cell to its south-east here), turns flat
##     white the moment it is whole, and the white fades off; the last still is
##     the plain plant. During the arrival every drawn texel is the sprite's own
##     colour — anything else is a bug.
##   - PLANT DISCOVERED: the plant fades to gold, holds, fades back. Smooth,
##     no dither: this one is a plain alpha-style fade by design.
##   - FENCE BUILT: the run grows post by post from the near end at its real
##     colours (the overlays own the picture; the cells are erased under
##     them), turns flat white once whole, and fades back. If the bright still
##     never comes, the overlays are sorting BEHIND something.
##   - After each row nothing may be left: no overlay node in the tree, the
##     plant back on its shared material. Exits 1 otherwise.
##
## Needs a rendering context — do NOT pass --headless.
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/preview_spawn_flash.gd -- --out preview_out/flash
##
## Args:
##   --out <dir>       output directory (default: user://)
##   --scene <res>     map to build on (default: the handcrafted tileset test map)
##   --species <id>    plant kind to plant (default: frailejon)

const DEFAULT_SCENE := "res://scenes/tools/tileset_test.tscn"
const WINDOW_SIZE := Vector2i(960, 540)
## Crop kept around the camera, before the upscale: a plant and its cell.
const CROP := Vector2i(64, 64)
const PIXEL_SCALE := 4
const SETTLE_FRAMES: int = 20

## Moments (seconds after the flash starts) captured per row.
const PLACED_TIMES: Array[float] = [0.0, 0.1, 0.2, 0.3, 0.42, 0.5, 0.8, 1.1, 1.6]
## A 3-cell run reveals over REVEAL_BASE + 2 * REVEAL_PER_CELL.
const FENCE_TIMES: Array[float] = [0.0, 0.12, 0.24, 0.36, 0.48, 0.58, 0.7, 1.0, 1.3, 1.8]
const DISCOVERED_TIMES: Array[float] = [0.0, 0.08, 0.16, 0.25, 0.35, 0.5, 0.65, 0.85]

var _out_dir: String = "user://"
var _scene_path: String = DEFAULT_SCENE
var _species: StringName = &"frailejon"
var _frames: int = 0
var _map: Node
var _pf: Pathfinder
var _world: Node
var _placer: StructurePlacer
var _plant: Frailejon

## Rows still to shoot: [name, times, start Callable, camera cell, flash colour].
var _rows: Array[Array] = []
var _row: int = -1
var _t: float = 0.0
var _shot: int = 0
var _stills: Array[Image] = []
## The same crop the frame BEFORE the flash starts: the map has its own pixels
## in the flash colours (snow, the gold of a marker), and only pixels that
## CHANGED to the flash colour count.
var _baseline: Image
var _failed: bool = false


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("preview_spawn_flash needs a rendering context. Drop --headless.")
		quit(1)
		return
	var argv := OS.get_cmdline_user_args()
	for i in argv.size():
		match argv[i]:
			"--out":
				if i + 1 < argv.size(): _out_dir = argv[i + 1]
			"--scene":
				if i + 1 < argv.size(): _scene_path = argv[i + 1]
			"--species":
				if i + 1 < argv.size(): _species = StringName(argv[i + 1])
	if not _out_dir.ends_with("/"):
		_out_dir += "/"
	DirAccess.make_dir_recursive_absolute(_out_dir)
	DisplayServer.window_set_size(WINDOW_SIZE)
	if current_scene != null:
		current_scene.queue_free()
	_map = load(_scene_path).instantiate()
	root.add_child(_map)


# Same reasoning as preview_fence._strip_atmosphere: every tint between the
# sprite and the framebuffer would make the "no invented colours" check
# meaningless, so the day/night stack goes.
func _strip_atmosphere() -> void:
	for path: String in [
		"TitleIntro", "RainLayer", "PostProcessLayer", "HUD", "FireAuraLayer",
		"PauseMenu", "FieldJournal", "BackgroundLayer",
	]:
		var n := _map.find_child(path, false, false)
		if n != null:
			n.set("visible", false)
	for path: String in ["DayNightController", "AltitudeFogController"]:
		var n := _map.find_child(path, false, false)
		if n != null:
			n.free()
	for node in _map.find_children("*", "CanvasModulate", true, false):
		(node as CanvasModulate).color = Color.WHITE
	for node in _map.find_children("*", "TileMapLayer", true, false):
		(node as TileMapLayer).modulate = Color.WHITE
	for path: String in ["Player", "VFXContainer"]:
		var n := _map.find_child(path, true, false)
		if n is CanvasItem:
			(n as CanvasItem).visible = false


func _process(delta: float) -> bool:
	_frames += 1
	if _frames < SETTLE_FRAMES:
		return false
	if _frames == SETTLE_FRAMES:
		_strip_atmosphere()
		if not _plan():
			quit(1)
			return true
		_start_row(0)
		return false
	if _row >= _rows.size():
		return false
	# Shoot at the first frame at or past each requested moment. Delta-driven,
	# not frame-driven: the tween advances on process delta.
	var times: Array = _rows[_row][1]
	# One frame with the camera parked and nothing flashing yet, for the
	# baseline; the flash starts on the frame after.
	if _baseline == null:
		_baseline = _crop()
		(_rows[_row][2] as Callable).call()
		return false
	if _shot < times.size() and _t >= float(times[_shot]):
		_capture()
		_shot += 1
		if _shot >= times.size():
			_finish_row()
			if _row + 1 >= _rows.size():
				quit(1 if _failed else 0)
				return true
			_start_row(_row + 1)
			return false
	_t += delta
	return false


# ----------------------------------------------------------------------------
# Subjects
# ----------------------------------------------------------------------------

func _plan() -> bool:
	_pf = root.get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	var slm := root.get_tree().get_first_node_in_group(
		StructureLayerManager.GROUP_NAME) as StructureLayerManager
	if _pf == null or slm == null or _pf.grid() == null:
		push_error("preview_spawn_flash: scene has no built Pathfinder / StructureLayerManager.")
		return false
	_world = _pf.get_parent().find_child("World", false, false)
	_placer = StructurePlacer.new(slm)
	var grid := _pf.grid()

	var plant_cell := Pathfinder.NO_CELL
	for c: Vector2i in grid.walkable_cells():
		if grid.occupant_at(c) == null:
			plant_cell = c
			break
	if plant_cell == Pathfinder.NO_CELL:
		push_error("preview_spawn_flash: no free walkable cell.")
		return false
	var plant := _spawn_plant(plant_cell)
	if plant == null:
		return false
	_plant = plant
	# A stand-in for the player: the cell to the south-east.
	var stand_in: Vector2 = _pf.cell_to_world(plant_cell + Vector2i(1, 1))
	_rows.append(["plant_placed", PLACED_TIMES, plant.play_placed_flash.bind(stand_in),
		plant_cell, SpawnFlash.BUILD_COLOR])
	_rows.append(["plant_discovered", DISCOVERED_TIMES, plant.play_discovery_flash,
		plant_cell, SpawnFlash.DISCOVER_COLOR])

	var run := _find_fence_run(grid, plant_cell)
	if run.is_empty():
		push_warning("preview_spawn_flash: no room for a fence run — fence row skipped.")
	else:
		var mid: Vector2i = (run[0] + run[1]) / 2
		_rows.append(["fence_built", FENCE_TIMES, _build_fence.bind(run[0], run[1]), mid,
			SpawnFlash.BUILD_COLOR])
	return true


# Exactly what TileInteractionController.plant_species does, minus the charge.
func _spawn_plant(cell: Vector2i) -> Frailejon:
	var data: WorldObjectData = ObjectPainter.data_for(_species)
	if not (data is PlantObjectData):
		push_error("preview_spawn_flash: '%s' is not a plant kind." % _species)
		return null
	var plant: Frailejon = load("res://scenes/tools/frailejon.tscn").instantiate()
	plant.cell = cell
	plant.data = data
	_world.add_child(plant)
	plant.global_position = _pf.cell_to_world(cell)
	return plant


func _find_fence_run(grid: TileGrid, avoid_cell: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var avoid: Dictionary = {}
	for dx in range(-2, 3):
		for dy in range(-2, 3):
			avoid[avoid_cell + Vector2i(dx, dy)] = true
	for cell: Vector2i in grid.walkable_cells():
		var far: Vector2i = cell + Vector2i(0, 3)
		if Fence.validate(cell, far, grid, avoid) != Fence.Result.OK:
			continue
		out.append(cell)
		out.append(far)
		return out
	return out


func _build_fence(from: Vector2i, to: Vector2i) -> void:
	var grid := _pf.grid()
	var alt: int = grid.get_tile(from).altitude_low
	var built: Array = []
	for c in Fence.plan_cells(from, to):
		var inst: Fence = load("res://scenes/traversals/fence.tscn").instantiate()
		_world.add_child(inst)
		Fence.configure(inst, c, alt, _placer, _pf)
		if inst.build():
			built.append(inst)
		else:
			push_error("preview_spawn_flash: fence build() failed at %s." % c)
			inst.queue_free()
	SpawnFlash.flash_built(built, _placer, from)


# ----------------------------------------------------------------------------
# Rows
# ----------------------------------------------------------------------------

func _start_row(i: int) -> void:
	_row = i
	_t = 0.0
	_shot = 0
	_stills.clear()
	_aim_camera(_rows[i][3])
	_baseline = null


func _finish_row() -> void:
	var name: String = _rows[_row][0]
	var flash: Color = _rows[_row][4]
	var times: Array = _rows[_row][1]
	var counts: PackedInt32Array = PackedInt32Array()
	for img: Image in _stills:
		counts.append(_count_changed_to(img, _baseline, flash))
	var strip := _strip(_stills)
	strip.save_png("%sflash_%s.png" % [_out_dir, name])
	var moments: PackedStringArray = PackedStringArray()
	for k in times.size():
		moments.append("%.2fs:%d" % [float(times[k]), counts[k]])
	print("preview_spawn_flash: %s — pixels moved toward the flash colour, per still [%s]"
		% [name, ", ".join(moments)])
	# The guards described in the header.
	var peak: int = 0
	for c in counts:
		peak = maxi(peak, c)
	if peak == 0:
		push_error("preview_spawn_flash: %s never showed the flash colour." % name)
		_failed = true
	# Settled: no overlay left in the tree, no plant still on its private
	# material. (The pixel counts cannot say this — a fence that did not exist
	# in the baseline reads as "changed" forever.)
	var left: int = root.get_tree().get_nodes_in_group(SpawnFlash.GROUP).size()
	if left > 0:
		push_error("preview_spawn_flash: %s — %d overlay(s) still alive after the tween." % [name, left])
		_failed = true
	if _plant != null and _plant.is_flashing():
		push_error("preview_spawn_flash: %s — the plant is still flashing after the tween." % name)
		_failed = true


# ----------------------------------------------------------------------------
# Camera / capture
# ----------------------------------------------------------------------------

func _aim_camera(cell: Vector2i) -> void:
	var cam := _find_camera(root)
	if cam == null:
		push_warning("preview_spawn_flash: no current Camera2D — framing is whatever the map set.")
		return
	var tile := _pf.grid().get_tile(cell)
	var alt: int = tile.altitude_low if tile != null else 0
	cam.position_smoothing_enabled = false
	cam.global_position = _pf.cell_to_world(cell) + Vector2(0.0, -alt * Pathfinder.HALF_STEP_PX - 8.0)


func _find_camera(node: Node) -> Camera2D:
	if node is Camera2D and (node as Camera2D).is_current():
		return node as Camera2D
	for child in node.get_children():
		var found := _find_camera(child)
		if found != null:
			return found
	return null


func _capture() -> void:
	_stills.append(_crop())


func _crop() -> Image:
	var img := root.get_texture().get_image()
	# The window rasterizes at its own resolution; the canvas is scaled by the
	# integer DisplayManager picked. Crop in LOGICAL pixels around the centre,
	# then sample every Nth physical pixel so a texel of art is a pixel here.
	var n: int = maxi(1, int(round(float(img.get_width()) / float(root.get_visible_rect().size.x))))
	var cx: int = img.get_width() / 2
	var cy: int = img.get_height() / 2
	var out := Image.create(CROP.x, CROP.y, false, Image.FORMAT_RGBA8)
	for y in CROP.y:
		for x in CROP.x:
			var px: int = cx + (x - CROP.x / 2) * n
			var py: int = cy + (y - CROP.y / 2) * n
			if px >= 0 and py >= 0 and px < img.get_width() and py < img.get_height():
				out.set_pixel(x, y, img.get_pixel(px, py))
	return out


# Pixels that moved a clear step TOWARD the flash colour since the baseline.
# Not exact matches: the flash is a fade, and a captured frame rarely lands on
# the flat colour itself.
func _count_changed_to(img: Image, base: Image, c: Color) -> int:
	var n: int = 0
	for y in img.get_height():
		for x in img.get_width():
			var p := img.get_pixel(x, y)
			var b := base.get_pixel(x, y)
			if _dist(p, c) < _dist(b, c) - 0.15:
				n += 1
	return n


func _dist(a: Color, b: Color) -> float:
	return Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()


func _strip(stills: Array[Image]) -> Image:
	var gap: int = 2
	var w: int = stills.size() * (CROP.x * PIXEL_SCALE + gap)
	var h: int = CROP.y * PIXEL_SCALE
	var big := Image.create(w, h, false, Image.FORMAT_RGBA8)
	big.fill(Palette.PANEL_BG)
	for i in stills.size():
		var s: Image = stills[i]
		var ox: int = i * (CROP.x * PIXEL_SCALE + gap)
		for y in h:
			for x in CROP.x * PIXEL_SCALE:
				big.set_pixel(ox + x, y, s.get_pixel(x / PIXEL_SCALE, y / PIXEL_SCALE))
	return big
