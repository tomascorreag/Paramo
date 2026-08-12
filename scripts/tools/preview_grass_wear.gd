extends SceneTree
## Renders a WEAR RAMP across real terrain: a run of adjacent grass cells set to
## vegetation 1.0 at one end and nearly bare at the other, so the whole
## degradation ladder is visible in one still.
##
## Why a tool at all. Grass length now tracks the vegetation value continuously
## (RegrowthManager + GrassLadder), and the ONLY question that matters about it
## is whether a player reads the intermediate rungs as "this ground is being worn
## down" rather than as tile noise. Nothing in a test can answer that, and
## nothing in normal play shows it either — a cell needs ~15 crossings to reach
## the bottom of its ladder, which is days of game time, and the cells that get
## there are scattered one at a time across a mountain. Laying the whole ramp
## side by side is the only way to see it.
##
## What to look for, i.e. the failures it exists to catch:
##   - The ramp must read as ONE stand of grass getting shorter, not as a row of
##     different ground types. If a step reads as a different plant, the rungs
##     are mis-ordered in base_tileset.tres's `grass_length`.
##   - Grass TONE must not change along the ramp. A cell hopping between the warm
##     and cool art is `grass_tone` mis-authored, and it is the one failure that
##     looks deliberate — two tones both ship, so a wrong one still looks like
##     grass.
##   - The steps must be roughly EVEN. A cell generated tall passes through more
##     rungs than one generated short (that is the design), but within one cell's
##     ramp a rung that is visually indistinguishable from its neighbour is a
##     wasted step, and one that jumps is a gap in the art.
##   - The cells beyond the ramp must be untouched. The ledger only tracks
##     damaged cells, and a neighbour that shortened means something is writing
##     cells it was not handed.
##
## It also prints the table the still cannot carry: each cell's tone, its ceiling
## rung, the value it was set to, the rung that value earned and the coord that
## got painted. Read the table when a still looks wrong — it says whether the
## fault is in the mapping or in the art.
##
## Needs a rendering context — do NOT pass --headless.
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/preview_grass_wear.gd -- --out /tmp/grass
##
## Args:
##   --out <dir>    output directory (default: user://)
##   --scene <res>  map to build on (default: level1, the procedural map — its
##                  generated variant mix is the thing being previewed)
##   --len <n>      cells in the ramp (default 10)
##
## Two shots are saved per run, at 1:1 and 4x NEAREST:
##   0_before   the run untouched — the A/B control, and the only way to tell a
##              worn cell from one that was generated short in the first place
##   1_worn     the same camera after the ramp is applied

const DEFAULT_SCENE := "res://scenes/maps/level1.tscn"

const WINDOW_SIZE := Vector2i(960, 540)
const PIXEL_SCALE := 2
## Wide enough to hold the whole ramp plus untouched ground either side — the
## neighbours are the control, and a crop that clips them turns the A/B into a
## picture of one gradient with nothing to compare it to.
const CROP_SIZE := Vector2i(420, 460)

## Frames to let a HANDCRAFTED map settle. A procedural one is waited on
## properly — see _world_ready. A settled Pathfinder grid does NOT mean the map
## is painted (TerrainPainter lays tiles across frames), and sampling early here
## reads as "there is no grass on this map".
const SETTLE_FRAMES: int = 30
## Give up waiting for generation rather than hanging a tool forever.
const GENERATION_TIMEOUT_FRAMES: int = 6000
const RENDER_FRAMES: int = 6
## Vegetation at the worn end. Deliberately just ABOVE bare_threshold: at 0 the
## last cell is dirt, and a dirt tile at the end of a grass ramp is the one part
## of this that was already visible before the feature existed.
const WORN_END: float = 0.18

## RegrowthManager's group and grass source id, as LITERALS. Naming the class
## makes regrowth_manager.gd a compile-time dependency of this file, it
## references three autoloads, and autoloads do not exist yet when a `--script`
## tool compiles — which does not error usefully, it just unbinds this script and
## reports "scene has no RegrowthManager". Same rule visitor.gd follows for the
## same reason.
const REGROWTH_GROUP: StringName = &"regrowth"
const SOURCE_GRASS: int = 0
const PROCEDURAL_WORLD_GROUP: StringName = &"procedural_world"

var _out_dir: String = "user://"
var _scene_path: String = DEFAULT_SCENE
var _run_len: int = 10
var _frames: int = 0
var _map: Node
var _pathfinder: Pathfinder
var _regrowth: Node
var _ladder: GrassLadder
var _run: Array[Vector2i] = []
var _ready_to_shoot: bool = false
var _generation_done: bool = false
var _generation_hooked: bool = false
var _stage: int = 0


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("preview_grass_wear needs a rendering context. Drop --headless.")
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
				if i + 1 < argv.size(): _run_len = maxi(3, int(argv[i + 1]))
	if not _out_dir.ends_with("/"):
		_out_dir += "/"
	DirAccess.make_dir_recursive_absolute(_out_dir)

	DisplayServer.window_set_size(WINDOW_SIZE)
	if current_scene != null:
		current_scene.queue_free()
	_map = load(_scene_path).instantiate()
	root.add_child(_map)


# True once there is a painted map to look at. On a procedural scene that means
# ProceduralWorld has emitted generation_finished — connected on the first frame
# it is discoverable, since it joins its group in its own _ready. A handcrafted
# scene has no such node and only needs the frame count.
func _world_ready() -> bool:
	if _generation_done:
		return true
	var pw := root.get_tree().get_first_node_in_group(PROCEDURAL_WORLD_GROUP)
	if pw == null:
		return _frames >= SETTLE_FRAMES
	if not _generation_hooked and pw.has_signal(&"generation_finished"):
		pw.connect(&"generation_finished", func() -> void: _generation_done = true)
		_generation_hooked = true
	return false


# Same reasoning as preview_fence: gameplay_base ships a night modulate, altitude
# fog, rain and a post grade, and every one of them shifts the very hue this tool
# is asking the viewer to compare between adjacent cells.
func _strip_atmosphere() -> void:
	for path: String in [
		"TitleIntro", "RainLayer", "PostProcessLayer", "HUD", "FireAuraLayer",
		"PauseMenu", "FieldJournal", "BackgroundLayer", "UXOverlay",
	]:
		# Recursive: several of these are nested under the map's own subtrees, and
		# a non-recursive lookup silently finds nothing rather than erroring —
		# which reads as "the atmosphere was already off".
		var n := _map.find_child(path, true, false)
		if n != null:
			n.set("visible", false)
	for path: String in ["DayNightController", "AltitudeFogController"]:
		var n := _map.find_child(path, true, false)
		if n != null:
			n.free()
	for node in _map.find_children("*", "CanvasModulate", true, false):
		(node as CanvasModulate).color = Color.WHITE
	for node in _map.find_children("*", "TileMapLayer", true, false):
		(node as TileMapLayer).modulate = Color.WHITE
	# The loading overlay is parented to the ROOT, not to the map, and it covers
	# the whole screen — a capture taken while it is up is a picture of it. It
	# fades out on its own, but only after overlay_linger, which is longer than
	# this tool waits.
	for node in root.find_children("*", "LoadingOverlay", true, false):
		node.free()
	for path: String in ["Player", "VFXContainer"]:
		var n := _map.find_child(path, true, false)
		if n is CanvasItem:
			(n as CanvasItem).visible = false


func _process(_delta: float) -> bool:
	_frames += 1
	if not _ready_to_shoot:
		if not _world_ready():
			if _frames > GENERATION_TIMEOUT_FRAMES:
				push_error("preview_grass_wear: the map never finished generating.")
				quit(1)
				return true
			return false
		_strip_atmosphere()
		if not _find_ramp():
			quit(1)
			return true
		_aim_camera(_run[_run.size() / 2])
		_ready_to_shoot = true
		_frames = 0
		return false
	if _frames % RENDER_FRAMES != 0:
		return false
	match _stage:
		0:
			_save("0_before")
			_apply_ramp()
		1:
			_save("1_worn")
			quit(0)
			return true
	_stage += 1
	return false


# ----------------------------------------------------------------------------
# Finding somewhere to look
# ----------------------------------------------------------------------------

# A run of adjacent, same-altitude grass cells with the MOST GRASS TO LOSE —
# scored by summed ceiling rung, not by length.
#
# Length alone is the wrong score, and picking it produced a useless render: the
# first long run in grid order was twelve cool cells that all cap at rung 1, so
# the whole ramp painted two nearly identical tiles and the feature looked
# broken. What is worth looking at is the run whose cells were generated TALL —
# they are the ones with several visible lengths between full and bare.
#
# The whole grid is scanned rather than stopping at the first hit, which costs
# nothing here (a few hundred walkable cells) and makes the choice a property of
# the map instead of a property of iteration order.
func _find_ramp() -> bool:
	var pf := root.get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	var rg := root.get_tree().get_first_node_in_group(REGROWTH_GROUP)
	if pf == null or rg == null or pf.grid() == null:
		push_error("preview_grass_wear: scene has no Pathfinder / RegrowthManager grid.")
		return false
	_pathfinder = pf
	_regrowth = rg

	var grid := pf.grid()
	var best: Array[Vector2i] = []
	var best_score: int = -1
	for cell: Vector2i in grid.walkable_cells():
		var tile = grid.get_tile(cell)
		if tile == null or tile.layer == null:
			continue
		if _ladder == null:
			_ladder = GrassLadder.new(tile.layer.tile_set, SOURCE_GRASS)
		# Both axes: a run along x and one along y read very differently in
		# isometric, and which one a given map can offer is not predictable.
		for dir: Vector2i in [Vector2i(1, 0), Vector2i(0, 1)]:
			var run := _run_from(grid, cell, dir)
			if run.size() < 3:
				continue
			var score: int = 0
			for c: Vector2i in run:
				score += _ladder.top_rung(grid.get_tile(c).layer.get_cell_atlas_coords(c))
			if score > best_score:
				best_score = score
				best = run
	if best.size() < 3:
		push_error("preview_grass_wear: no run of laddered grass on this map.")
		return false
	_run = best
	_census(grid)
	return true


# What generation actually put on the map, per tone and rung. Two things worth
# knowing every run, and one of them is a hard failure:
#
#  - THE BOTTOM RUNG MUST BE EMPTY on a freshly generated map. Those tiles are
#    degradation-only, kept out of the variant draw by selection_weight = -1 in
#    base_tileset.tres. If one is painted here the exclusion has broken, and the
#    symptom in game is subtle in exactly the wrong way: the mountain generates
#    with patches that already look worn, so the wear the player causes stops
#    reading as something they did.
#  - The rung spread is the CEILING on how visible this feature can be. A tone
#    whose cells all generate at rung 1 has one step to lose before dirt, however
#    many rungs the ladder has — which is a fact about the variant weights, not
#    about the wear, and it is the first thing to check when a ramp looks flat.
func _census(grid: TileGrid) -> void:
	var counts: Dictionary = {}
	var leaked: Dictionary = {}
	for cell: Vector2i in grid.walkable_cells():
		var tile = grid.get_tile(cell)
		if tile == null or tile.layer == null:
			continue
		if tile.layer.get_cell_source_id(cell) != SOURCE_GRASS:
			continue
		var coord: Vector2i = tile.layer.get_cell_atlas_coords(cell)
		var tone: int = _ladder.tone_of(coord)
		if tone <= 0:
			continue
		var key: String = "tone %d rung %d/%d" % [
			tone, _ladder.top_rung(coord), _ladder.rung_count(coord) - 1]
		counts[key] = int(counts.get(key, 0)) + 1
		# A single-rung tile sits at rung 0 legitimately — that is its only rung,
		# not a leak. Only a MULTI-rung ladder can be leaked from.
		if _ladder.top_rung(coord) == 0 and _ladder.rung_count(coord) > 1:
			leaked[key] = int(leaked.get(key, 0)) + 1
	var keys: Array = counts.keys()
	keys.sort()
	print("preview_grass_wear: generated grass by tone and rung")
	for k: String in keys:
		print("   %-18s %d" % [k, counts[k]])
	for k: String in leaked:
		push_error(
			"preview_grass_wear: generation painted %d cell(s) at the bottom rung (%s) — "
			% [leaked[k], k]
			+ "selection_weight = -1 is no longer excluding the degradation-only art.")


func _run_from(grid: TileGrid, start: Vector2i, dir: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var alt: int = -9999
	for i in _run_len:
		var cell: Vector2i = start + dir * i
		var tile = grid.get_tile(cell)
		if tile == null or tile.layer == null:
			break
		if alt == -9999:
			alt = tile.altitude_low
		elif tile.altitude_low != alt:
			break
		if tile.layer.get_cell_source_id(cell) != SOURCE_GRASS:
			break
		if _ladder.top_rung(tile.layer.get_cell_atlas_coords(cell)) < 1:
			break
		out.append(cell)
	return out


# ----------------------------------------------------------------------------
# The ramp
# ----------------------------------------------------------------------------

# Wear each cell through the REAL entry point (trample), so what is rendered is
# what the game does. Setting rec["veg"] directly would render a picture of the
# painter alone and prove nothing about the mapping that drives it.
func _apply_ramp() -> void:
	var grid := _pathfinder.grid()
	print("preview_grass_wear: ramp of %d cells, %s -> %s"
		% [_run.size(), _run[0], _run[_run.size() - 1]])
	print("   cell      tone  top  veg    rung  painted")
	for i in _run.size():
		var cell: Vector2i = _run[i]
		var tile = grid.get_tile(cell)
		var born: Vector2i = tile.layer.get_cell_atlas_coords(cell)
		var t: float = float(i) / float(maxi(_run.size() - 1, 1))
		var veg: float = lerpf(1.0, WORN_END, t)
		_regrowth.call(&"trample", cell, 1.0 - veg)
		var now: Vector2i = tile.layer.get_cell_atlas_coords(cell)
		var src: int = tile.layer.get_cell_source_id(cell)
		print("   %-9s %-5d %-4d %-6.2f %-5s %s" % [
			cell, _ladder.tone_of(born), _ladder.top_rung(born), veg,
			str(_ladder.top_rung(now)) if src == SOURCE_GRASS else "-",
			str(now) if src == SOURCE_GRASS else "dirt",
		])
		if src == SOURCE_GRASS and _ladder.tone_of(now) != _ladder.tone_of(born):
			push_error("preview_grass_wear: %s changed TONE, %d -> %d."
				% [cell, _ladder.tone_of(born), _ladder.tone_of(now)])


# ----------------------------------------------------------------------------
# Capture
# ----------------------------------------------------------------------------

func _aim_camera(cell: Vector2i) -> void:
	var cam := _find_camera(root)
	if cam == null:
		push_warning("preview_grass_wear: no current Camera2D — framing is the map's.")
		return
	var tile = _pathfinder.grid().get_tile(cell)
	var alt: int = tile.altitude_low if tile != null else 0
	cam.position_smoothing_enabled = false
	cam.global_position = _pathfinder.cell_to_world(cell) \
			+ Vector2(0.0, -alt * Pathfinder.HALF_STEP_PX)


func _find_camera(node: Node) -> Camera2D:
	if node is Camera2D and (node as Camera2D).is_current():
		return node as Camera2D
	for child in node.get_children():
		var found := _find_camera(child)
		if found != null:
			return found
	return null


func _save(name: String) -> void:
	var img := root.get_texture().get_image()
	img.save_png("%sgrass_%s.png" % [_out_dir, name])
	var crop := Rect2i(
		(img.get_width() - CROP_SIZE.x) / 2, (img.get_height() - CROP_SIZE.y) / 2,
		CROP_SIZE.x, CROP_SIZE.y
	)
	var sub := img.get_region(crop)
	# NEAREST, because the difference between two adjacent rungs is a few texels
	# of blade height and a smooth upscale averages exactly that away.
	var big := Image.create(
		sub.get_width() * PIXEL_SCALE, sub.get_height() * PIXEL_SCALE, false, sub.get_format())
	for y in big.get_height():
		for x in big.get_width():
			big.set_pixel(x, y, sub.get_pixel(x / PIXEL_SCALE, y / PIXEL_SCALE))
	big.save_png("%sgrass_%s@%dx.png" % [_out_dir, name, PIXEL_SCALE])
	print("preview_grass_wear: wrote grass_%s.png (+@%dx)" % [name, PIXEL_SCALE])
