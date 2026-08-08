extends SceneTree
## Renders a built FENCE on real terrain, which is the only way to check the one
## thing about it that no test can see: whether the sprite's posts actually stand
## ON the floor.
##
## A fence tile is authored with a `texture_origin`, and that number decides where
## the 32x32 art lands relative to the 32x16 diamond it is painted on. Get it
## wrong by one half-step and the fence floats 8px above the ground or sinks 8px
## into it — a mistake that is invisible in the tileset editor (where there is no
## ground under the tile to compare against) and invisible to the validator (which
## only ever reasons about cells). So: build one run per AXIS on a handcrafted map,
## point the camera at them, and look.
##
## What to look for, i.e. the failures it exists to catch:
##   - Each post's base must sit on the tile's surface, not hover over it and not
##     sink below it. Compare against the floor tiles either side of the run.
##   - Consecutive tiles of a run must JOIN — the wire is parallel to the run, so
##     one tile's far post and the next tile's near post occupy the same point. A
##     visible seam or a doubled post means `kind_at` picked the wrong variant
##     for that axis.
##   - The two runs must use DIFFERENT art (FENCE_NE for the (0,±1) axis,
##     FENCE_NW for (±1,0)). Two identical-looking runs means the axis test in
##     `kind_at` collapsed.
##   - At the JUNCTION shot, the crossed cell must keep the FIRST run's variant.
##     Orientation is derived from the neighbourhood every time it changes, and
##     the only thing stopping a later line from stealing an established one is
##     the build_index comparison. The tool prints the junction's variant before
##     and after the crossing run so a flip is caught even if the still is
##     ambiguous.
##   - Nothing may sort in front of a fence that is behind it. y_sort_origin is
##     -16 on both tiles; a player or frailejon punching through is that number.
##
## Needs a rendering context — do NOT pass --headless.
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/preview_fence.gd -- --out /tmp/fence
##
## Args:
##   --out <dir>    output directory (default: user://)
##   --scene <res>  map to build on (default: the handcrafted tileset test map)
##   --len <n>      cells per run (default 4)
##
## This tool shows the fence IN CONTEXT; it cannot MEASURE the authoring. A
## neighbouring tile drawing over the fence changes its apparent extent — the
## same tile read 11 texels shorter at one y_sort_origin than at another — so the
## `texture_origin` question belongs to scripts/tools/measure_tile_ink.gd, which
## renders one tile alone with nothing available to occlude it.

const DEFAULT_SCENE := "res://scenes/tools/tileset_test.tscn"

const WINDOW_SIZE := Vector2i(960, 540)
const PIXEL_SCALE := 2
## Centre crop kept from each capture, before the upscale. Wide enough to hold a
## 4-cell run (4 * 32 = 128px along the x axis) plus the floor either side.
const CROP_SIZE := Vector2i(480, 300)

## Frames to let the scene settle before looking at the grid. StructureLayerManager
## spawns its layers in _ready and rebuilds the pathfinder once at the end, so the
## grid does not exist on frame 0.
const SETTLE_FRAMES: int = 20
## Frames between building the fences and grabbing the image — the paint goes in
## immediately but the camera tween and one rebuild still need to land.
const RENDER_FRAMES: int = 10

var _out_dir: String = "user://"
var _scene_path: String = DEFAULT_SCENE
var _run_len: int = 4
var _frames: int = 0
## Shots still to take: each is [name, camera cell]. Filled by _build_fences.
var _shots: Array[Array] = []
var _shot: int = -1
var _pathfinder: Pathfinder
var _placer: StructurePlacer
var _world: Node
var _map: Node


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("preview_fence needs a rendering context. Drop --headless.")
		quit(1)
		return

	var argv := OS.get_cmdline_user_args()
	for i in argv.size():
		match argv[i]:
			"--out":
				if i + 1 < argv.size(): _out_dir = argv[i + 1]
			"--scene":
				if i + 1 < argv.size(): _scene_path = argv[i + 1]
			"--len":
				if i + 1 < argv.size(): _run_len = maxi(2, int(argv[i + 1]))
	if not _out_dir.ends_with("/"):
		_out_dir += "/"
	DirAccess.make_dir_recursive_absolute(_out_dir)

	DisplayServer.window_set_size(WINDOW_SIZE)
	# SceneTree instantiates the project's main scene for us; it would render on
	# top of the map we actually want to look at.
	# current_scene lives on the SceneTree, not on root (which is the Window).
	if current_scene != null:
		current_scene.queue_free()
	_map = load(_scene_path).instantiate()
	root.add_child(_map)


# gameplay_base ships the full atmospheric stack: a title screen over the map, a
# night-tinted CanvasModulate driven by DayNightController, per-altitude fog
# tinting every TileMapLayer, rain, and the post-process grade. Every one of them
# is doing its job, and every one of them hides the thing this tool exists to
# measure — where a fence post meets the floor, to within a couple of texels.
#
# The two CONTROLLERS are freed rather than hidden: they re-apply their tint
# every frame (and on season signals), so anything short of removing them puts
# the night back the frame after. Run this AFTER the scene has settled, or their
# _ready re-registers what was just torn out.
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
	# AltitudeFogController tints the layers themselves, and freeing it leaves
	# whatever tint it last wrote.
	for node in _map.find_children("*", "TileMapLayer", true, false):
		(node as TileMapLayer).modulate = Color.WHITE
	# The Player spawns in the middle of the map and idles there; it is the one
	# thing likely to be standing on top of whatever run gets picked.
	for path: String in ["Player", "VFXContainer"]:
		var n := _map.find_child(path, true, false)
		if n is CanvasItem:
			(n as CanvasItem).visible = false


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < SETTLE_FRAMES:
		return false
	if _frames == SETTLE_FRAMES:
		_strip_atmosphere()
		if not _build_fences():
			quit(1)
			return true
		_shot = 0
		_aim_camera(_pathfinder, _shots[0][1])
		return false
	# One shot every RENDER_FRAMES: aim, let the frame draw, grab, aim the next.
	if (_frames - SETTLE_FRAMES) % RENDER_FRAMES != 0:
		return false
	_save(_shots[_shot][0])
	_shot += 1
	if _shot >= _shots.size():
		quit(0)
		return true
	_aim_camera(_pathfinder, _shots[_shot][1])
	return false


# ----------------------------------------------------------------------------
# Building
# ----------------------------------------------------------------------------

# Lay one run per axis and aim the camera between them. False if the map has no
# room for either (a scene with no open flat ground).
func _build_fences() -> bool:
	var pf := root.get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	var slm := root.get_tree().get_first_node_in_group(
		StructureLayerManager.GROUP_NAME
	) as StructureLayerManager
	if pf == null or slm == null:
		push_error("preview_fence: scene has no Pathfinder / StructureLayerManager.")
		return false
	var grid := pf.grid()
	if grid == null:
		push_error("preview_fence: pathfinder grid is not built.")
		return false

	_pathfinder = pf
	_placer = StructurePlacer.new(slm)
	_world = pf.get_parent().find_child("World", false, false)

	# Keep the two runs apart so neither's cells block the other's validate.
	var ne_run := _find_run(grid, Vector2i(0, 1), {})
	if ne_run.is_empty():
		push_error("preview_fence: no room for a run on the (0, 1) axis.")
		return false
	var taken: Dictionary = {}
	for i in range(-1, _run_len + 1):
		taken[ne_run[0] + Vector2i(0, 1) * i] = true
		taken[ne_run[0] + Vector2i(1, 0) + Vector2i(0, 1) * i] = true
		taken[ne_run[0] + Vector2i(-1, 0) + Vector2i(0, 1) * i] = true
	var nw_run := _find_run(grid, Vector2i(1, 0), taken)

	if not _place_run(ne_run[0], ne_run[1]):
		return false
	_shots.append(["ne", (ne_run[0] + ne_run[1]) / 2])
	if not nw_run.is_empty():
		if _place_run(nw_run[0], nw_run[1]):
			_shots.append(["nw", (nw_run[0] + nw_run[1]) / 2])
	else:
		push_warning("preview_fence: no room for a (1, 0) run — only one axis shown.")

	_place_junction(ne_run)
	return true


# Lay a run as N independent one-cell fences, in order, exactly as the placement
# controller does — the ORDER is load-bearing, since build_index is what breaks
# the tie where two lines cross.
func _place_run(from: Vector2i, to: Vector2i) -> bool:
	var grid := _pathfinder.grid()
	var result := Fence.validate(from, to, grid)
	if result != Fence.Result.OK:
		push_error("preview_fence: run %s -> %s is %s." % [from, to, Fence.result_name(result)])
		return false
	var alt: int = grid.get_tile(from).altitude_low
	var cells := Fence.plan_cells(from, to)
	for c in cells:
		var inst: Fence = load("res://scenes/traversals/fence.tscn").instantiate()
		_world.add_child(inst)
		Fence.configure(inst, c, alt, _placer, _pathfinder)
		if not inst.build():
			push_error("preview_fence: build() failed at %s." % c)
			inst.queue_free()
	# Read the kinds back only once the WHOLE run is down. A fence's orientation
	# comes from its neighbours, so the first cell of a run is placed with none
	# and takes the default; it is the second cell's build that turns it. Printing
	# each kind at its own build time reports that transient state and makes a
	# correct run look broken.
	var kinds: Array[String] = []
	var blocked: int = 0
	var after := _pathfinder.grid()
	for c in cells:
		var f := after.occupant_at(c) as Fence
		kinds.append(String(f.kind()).replace("FENCE_", "") if f != null else "-")
		# The barrier is the point of the structure, and it only exists if the
		# occupant claim took. Cheap end-to-end check the unit tests cannot make:
		# they never put a fence on a live grid.
		if not after.is_walkable(c):
			blocked += 1
	print("preview_fence: run %s -> %s laid %d fences [%s]; %d/%d cells block movement."
		% [from, to, cells.size(), ", ".join(kinds), blocked, cells.size()])
	return true


# Run a second line INTO the middle of the first, which is the case the
# build-order rule exists for. The junction cell already belongs to the older
# line, so it must keep that line's variant; the newcomer is the one that stops
# short. A junction that flips is the regression to look for.
func _place_junction(ne_run: Array[Vector2i]) -> void:
	var mid: Vector2i = (ne_run[0] + ne_run[1]) / 2
	var junction: Fence = _pathfinder.grid().occupant_at(mid) as Fence
	if junction == null:
		push_warning("preview_fence: no fence at the run's midpoint %s." % mid)
		return
	var before := junction.kind()
	# The junction cell is occupied, so the crossing run cannot include it — it
	# stops on the neighbour. That is all the orientation rule needs to see: the
	# junction then has fences on BOTH axes.
	#
	# Both directions and several lengths are tried because the crossing has to
	# land on ground that is flat and LEVEL WITH ITSELF, and on a handcrafted map
	# there is no guarantee the ground beside a run is either. Hardcoding one
	# direction just produced ALTITUDE_MISMATCH and silently skipped the shot.
	var grid := _pathfinder.grid()
	var from := Pathfinder.NO_CELL
	var to := Pathfinder.NO_CELL
	for dir: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0)]:
		for length in range(3, 1, -1):
			var a: Vector2i = mid + dir * length
			var b: Vector2i = mid + dir
			if Fence.validate(a, b, grid) == Fence.Result.OK:
				from = a
				to = b
				break
		if from != Pathfinder.NO_CELL:
			break
	if from == Pathfinder.NO_CELL:
		push_warning(
			"preview_fence: no level ground beside %s for a crossing run — junction shot skipped."
			% mid)
		return
	if not _place_run(from, to):
		return
	var after := junction.kind()
	print("preview_fence: junction %s was %s, now %s — %s."
		% [mid, before, after,
			"kept (correct)" if after == before else "FLIPPED (build order lost)"])
	_shots.append(["junction", mid])


# First `[origin, far]` pair along `dir` that validates as a `_run_len`-cell
# fence and touches none of `avoid`. Cells are scanned in the grid's own order,
# so the same map always yields the same run.
func _find_run(grid: TileGrid, dir: Vector2i, avoid: Dictionary) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for cell: Vector2i in grid.walkable_cells():
		var far: Vector2i = cell + dir * (_run_len - 1)
		if Fence.validate(cell, far, grid, avoid) != Fence.Result.OK:
			continue
		out.append(cell)
		out.append(far)
		return out
	return out


# Park the camera on `cell`. Smoothing is switched off first: it lerps toward a
# target over many frames, and the capture would otherwise catch it in transit.
func _aim_camera(pf: Pathfinder, cell: Vector2i) -> void:
	var cam := _find_camera(root)
	if cam == null:
		push_warning("preview_fence: no current Camera2D — framing is whatever the map set.")
		return
	var tile := pf.grid().get_tile(cell)
	var alt: int = tile.altitude_low if tile != null else 0
	cam.position_smoothing_enabled = false
	cam.global_position = pf.cell_to_world(cell) + Vector2(0.0, -alt * Pathfinder.HALF_STEP_PX)


func _find_camera(node: Node) -> Camera2D:
	if node is Camera2D and (node as Camera2D).is_current():
		return node as Camera2D
	for child in node.get_children():
		var found := _find_camera(child)
		if found != null:
			return found
	return null


# ----------------------------------------------------------------------------
# Capture
# ----------------------------------------------------------------------------

# Grab the WORLD viewport, not the window: that buffer is the low-res one the
# tiles actually rasterize into, so a texel in the PNG is a texel of art. Falls
# back to the window for a scene that predates the SubViewport split.
func _save(name: String) -> void:
	var vp: Viewport = root.find_child("WorldViewport", true, false) as Viewport
	if vp == null:
		vp = root
	var img := vp.get_texture().get_image()
	img.save_png("%sfence_%s.png" % [_out_dir, name])
	# The camera is parked on the run, so a centre crop is the run. Upscale it
	# NEAREST: at 1:1 an 8px sink or float is a couple of screen pixels and you
	# will talk yourself into it being fine.
	var crop := Rect2i(
		(img.get_width() - CROP_SIZE.x) / 2, (img.get_height() - CROP_SIZE.y) / 2,
		CROP_SIZE.x, CROP_SIZE.y
	)
	var sub := img.get_region(crop)
	var big := Image.create(
		sub.get_width() * PIXEL_SCALE, sub.get_height() * PIXEL_SCALE, false, sub.get_format()
	)
	for y in big.get_height():
		for x in big.get_width():
			big.set_pixel(x, y, sub.get_pixel(x / PIXEL_SCALE, y / PIXEL_SCALE))
	big.save_png("%sfence_%s@%dx.png" % [_out_dir, name, PIXEL_SCALE])
	print("preview_fence: wrote fence_%s.png (%dx%d) and its %dx centre crop."
		% [name, img.get_width(), img.get_height(), PIXEL_SCALE])
