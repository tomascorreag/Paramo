extends SceneTree
## GPU + batching cost of assets/shaders/wind_plant.gdshader, priced against
## the same plants with no material at all.
##
## Why this exists rather than profile_scene.gd on level1: that scene is not
## deterministic frame to frame (visitors spawn, fire spreads, the day moves),
## and the same arm measured 383-481 draw calls and 4.8-6.3 ms across runs.
## The wind delta is smaller than that, so it cannot be read there. Here the
## only thing on screen is plants, the count is fixed, and the two arms are
## timed in separate phases so they never contend for the GPU.
##
## It spawns REAL Frailejon instances with the real species data, so what is
## measured is the shipped thing — including the clumped cells, whose extra
## individuals are drawn by the node's own _draw() and therefore need the
## material on a second CanvasItem.
##
## Defaults are sized from report_flora_scatter + the display path: at a 1440x810
## window DisplayManager locks 4x, so the logical viewport is 360x202 and a
## 32px plant covers a real fraction of it. ~95 windy cells is what level1 puts
## on screen at once (calamagrostis + chusquea + cortaderia are ~75% of ~125
## visible plant cells).
##
## Absolute ms is this GPU at this window size and does NOT transfer — desktop
## cannot resolve this project's canvas fill at all (dev-notes/performance.md).
## What transfers is the RATIO and the DRAW CALL delta.
##
## Needs a rendering context — do NOT pass --headless (draw calls read 0 under
## the headless driver, which makes every number here meaningless).
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/benchmark_wind_plant.gd \
##       -- --plants 95 --frames 240

const PLANT_SCENE := "res://scenes/tools/frailejon.tscn"
# Species used by the SCENE arm (the draw-call / batching measurement). Kept as
# a fixed list so that arm's cost is comparable across runs.
const SPECIES := [
	"res://resources/objects/calamagrostis.tres",
	"res://resources/objects/chusquea.tres",
	"res://resources/objects/cortaderia.tres",
]
const DEFAULT_PLANTS: int = 95
const WARMUP_FRAMES: int = 120
const DEFAULT_TIMED: int = 240
const PLACEMENT_SEED: int = 20260828

const FILL_SIZE := Vector2i(1920, 1080)
## The tile wind shader, priced in the same run so the plant variant's saving
## (no 32-iteration alpha probe, noise per vertex not per fragment) is a
## measured number rather than a claim about the source.
const TILE_WIND_MATERIAL := "res://resources/materials/wind_light.tres"

var _plants: int = DEFAULT_PLANTS
var _timed: int = DEFAULT_TIMED
var _fill: bool = false
var _verify: bool = false
# Overlapping full-size quads. One is not enough to leave the CPU frame floor
# behind on a desktop GPU: at 2 Mpx all three arms measured ~0.45 ms, i.e. the
# per-frame overhead, and the SHADED arms came out faster than the plain one.
# Fragments scale linearly with this, so raise it until the sweep responds.
var _passes: int = 32
var _host: Node2D


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var i: int = 0
	while i < args.size():
		match args[i]:
			"--plants":
				i += 1
				_plants = int(args[i])
			"--frames":
				i += 1
				_timed = int(args[i])
			"--fill":
				_fill = true
			"--passes":
				i += 1
				_passes = int(args[i])
			"--verify":
				_verify = true
		i += 1
	_run.call_deferred()


func _run() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	await process_frame
	if _verify:
		await _run_verify()
		return
	if _fill:
		await _run_fill()
		return
	print("\nwind_plant benchmark")
	print("  device:  %s" % RenderingServer.get_video_adapter_name())
	print("  window:  %s  logical: %s" % [DisplayServer.window_get_size(), root.get_visible_rect().size])
	print("  plants:  %d cells (real Frailejon instances, real species data)" % _plants)

	var with_wind: Dictionary = await _phase(true)
	var without: Dictionary = await _phase(false)

	print("\n  %-14s %10s %10s %12s %12s" % ["arm", "ms/frame", "fps", "draw calls", "objects"])
	for row in [["wind ON", with_wind], ["wind OFF", without]]:
		var d: Dictionary = row[1]
		print("  %-14s %10.3f %10.1f %12d %12d"
			% [row[0], d["ms"], 1000.0 / maxf(d["ms"], 0.001), d["draws"], d["objects"]])
	var delta: float = with_wind["ms"] - without["ms"]
	print("\n  delta        %+.3f ms/frame  (x%.3f)"
		% [delta, with_wind["ms"] / maxf(without["ms"], 0.001)])
	print("  draw calls   %+d" % (with_wind["draws"] - without["draws"]))
	print("  per plant    %+.4f ms" % (delta / maxf(float(_plants), 1.0)))
	quit()


# One arm: build the plants, let the driver settle (the shader compiles on the
# frame the first plant is drawn — that bill must land in the warm-up, not in
# the timed window; same reason FireShaderWarmup exists), then wall-clock a
# fixed number of frames.
func _phase(wind: bool) -> Dictionary:
	_clear()
	_spawn(wind)
	for f in WARMUP_FRAMES:
		await process_frame
	var t0: int = Time.get_ticks_usec()
	for f in _timed:
		await process_frame
	var elapsed: float = float(Time.get_ticks_usec() - t0) / 1000.0
	return {
		"ms": elapsed / float(maxi(_timed, 1)),
		"draws": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"objects": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
	}


func _clear() -> void:
	if _host != null and is_instance_valid(_host):
		_host.free()
	_host = Node2D.new()
	root.add_child(_host)


func _spawn(wind: bool) -> void:
	var scene: PackedScene = load(PLANT_SCENE)
	var rng := RandomNumberGenerator.new()
	rng.seed = PLACEMENT_SEED
	# Same placement in both arms — the clump roll reads the GLOBAL rng inside
	# Frailejon._ready, so seed that too or the two arms draw different numbers
	# of individuals and the comparison is not paired.
	seed(PLACEMENT_SEED)
	var area: Vector2 = root.get_visible_rect().size
	for i in _plants:
		var data: PlantObjectData = load(SPECIES[i % SPECIES.size()])
		if not wind:
			data = data.duplicate()
			data.wind_material = null
		var inst: Node2D = scene.instantiate()
		inst.data = data
		_host.add_child(inst)
		inst.position = Vector2(
			rng.randf_range(0.0, area.x),
			rng.randf_range(0.0, area.y),
		)


# --- fill mode ---------------------------------------------------------------
#
# One big quad of real plant art, drawn three ways: unshaded, through the plant
# wind shader, and through the TILE wind shader the ground already runs. Cost is
# linear in fragments, so the ratios are the transferable output — the absolute
# ms is this GPU at this quad size and means nothing on web.
func _run_fill() -> void:
	print("
wind_plant fill benchmark  (%d passes x %dx%d = %.1f Mpx)"
		% [_passes, FILL_SIZE.x, FILL_SIZE.y,
			_passes * FILL_SIZE.x * FILL_SIZE.y / 1e6])
	print("  device:  %s" % RenderingServer.get_video_adapter_name())
	var tex: Texture2D = load("res://assets/sprites/objects/ISO_Plants.png")
	var arms: Array = [
		["plain (no material)", null],
		["wind_plant", load("res://resources/materials/wind_plant.tres")],
		["wind.gdshader (tile)", load(TILE_WIND_MATERIAL)],
	]
	var out: Array = []
	for arm in arms:
		out.append(await _fill_phase(tex, arm[1]))
	print("
  %-24s %10s %14s" % ["arm", "ms/frame", "vs plain"])
	for i in arms.size():
		print("  %-24s %10.3f %13.2fx" % [arms[i][0], out[i], out[i] / maxf(out[0], 0.0001)])
	var mpx: float = _passes * FILL_SIZE.x * FILL_SIZE.y / 1e6
	print("
  per Mpx:  plain %.3f ms   wind_plant %.3f ms   tile wind %.3f ms"
		% [out[0] / mpx, out[1] / mpx, out[2] / mpx])
	print("  the plant shader's own cost over a plain draw: %.3f ms/Mpx"
		% ((out[1] - out[0]) / mpx))
	quit()


func _fill_phase(tex: Texture2D, mat: Material) -> float:
	_clear()
	for i in _passes:
		var rect := TextureRect.new()
		rect.texture = tex
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_SCALE
		rect.size = Vector2(FILL_SIZE)
		rect.material = mat
		_host.add_child(rect)
	for f in WARMUP_FRAMES:
		await process_frame
	var t0: int = Time.get_ticks_usec()
	for f in _timed:
		await process_frame
	return float(Time.get_ticks_usec() - t0) / 1000.0 / float(maxi(_timed, 1))


# --- verify mode -------------------------------------------------------------
#
# Renders ONE plant through the shipped material across a span of world_time and
# reports the horizontal travel of its silhouette. A shader that compiles, binds
# and draws correctly can still be motionless — that is exactly what shipped
# first — and no single-frame preview can tell the difference.
func _run_verify() -> void:
	print("
wind_plant motion check")
	print("  churn = source texels redrawn per sample, over the plant's ink.")
	print("  edge = how far the ink's leading edge slid: near zero is CORRECT")
	print("  for a per-fragment ripple, which is what grass should do.
")
	# Derived from the registry, not hardcoded: whichever species author a
	# wind_material are the ones that have to move, so adding or removing one
	# cannot silently escape this check.
	var swaying: Array[String] = []
	for kind in ObjectPainter.kinds():
		var d := ObjectPainter.data_for(kind) as PlantObjectData
		if d != null and d.wind_material != null:
			swaying.append(d.resource_path)
	if swaying.is_empty():
		print("  FAIL: no species authors a wind_material")
		quit(1)
		return
	var ok: bool = true
	for path in swaying:
		for stage in [0, 3]:
			ok = (await _verify_one(path, stage)) and ok
	print("
  %s" % ("PASS" if ok else "FAIL: something is not moving."))
	quit(0 if ok else 1)


func _verify_one(species_path: String, stage: int) -> bool:
	_clear()
	var scene: PackedScene = load(PLANT_SCENE)
	var data: PlantObjectData = load(species_path)
	if data.wind_material == null:
		print("  FAIL: %s authors no wind_material" % species_path)
		return false
	# Seed the GLOBAL rng: Frailejon._roll_clump draws from it in _ready, so
	# without this each run gets a different number of tufts and a different
	# ink area, and the churn percentage swings several points between
	# identical runs. (Calamagrostis read 9% then 5% at the same settings.)
	seed(PLACEMENT_SEED)
	var inst: Node2D = scene.instantiate()
	inst.data = data
	inst.growth_stage = stage
	_host.add_child(inst)
	inst.position = Vector2(120, 90)
	for f in 30:
		await process_frame

	# Drive the clock through WorldClock, NOT by writing the global uniform:
	# the autoload re-pushes `world_time` from its own accumulator every frame,
	# so a direct RenderingServer write is overwritten before anything renders
	# and the whole time axis of this test becomes a lie. (It did, once.)
	var clock: Node = root.get_node_or_null("/root/WorldClock")
	if clock == null:
		print("  FAIL: WorldClock autoload missing; nothing drives world_time")
		return false

	# Crop to the plant. The viewport is opaque, so an alpha test over the whole
	# frame measures the background, not the sprite.
	var scale_n: int = int(round(float(DisplayServer.window_get_size().x)
			/ maxf(float(root.content_scale_size.x), 1.0)))
	var crop := Rect2i(
		Vector2i(int(inst.position.x) - 24, int(inst.position.y) - 40) * scale_n,
		Vector2i(48, 48) * scale_n)

	var ink_area: int = 0
	var centroids: PackedFloat32Array = PackedFloat32Array()
	var changed_total: int = 0
	var prev: Image = null
	for step in 16:
		var t: float = float(step) * 0.35
		clock.call(&"set_seconds", t)
		for f in 3:
			await process_frame
		var im: Image = root.get_texture().get_image().get_region(crop)
		# Ink = anything that is not the background colour, sampled from a
		# corner of the crop.
		var bg: Color = im.get_pixel(0, 0)
		# Centroid of the ink's TOP THIRD, not of all of it. The mask ramps
		# from the base, so the bottom rows are pinned by design and a
		# whole-ink centroid averages the sway away to nearly nothing — which
		# looked like a failure the first time this ran.
		var ink_top: int = im.get_height()
		var ink_bottom: int = -1
		var changed: int = 0
		for y in im.get_height():
			for x in im.get_width():
				var c: Color = im.get_pixel(x, y)
				if c != bg:
					ink_top = mini(ink_top, y)
					ink_bottom = maxi(ink_bottom, y)
				if prev != null and c != prev.get_pixel(x, y):
					changed += 1
		# LEFTMOST ink column of the top third, not its centroid. A rigid
		# shift moves an edge by exactly the offset, while the centroid of a
		# dense symmetric silhouette barely moves at all — mature Chusquea
		# scored 0.83 "texels" of centroid travel while changing 48,940
		# pixels, which is the metric being wrong, not the shader.
		if ink_area == 0:
			for y in im.get_height():
				for x in im.get_width():
					if im.get_pixel(x, y) != bg:
						ink_area += 1
		var cutoff: int = ink_top + int(float(ink_bottom - ink_top + 1) / 3.0)
		var cx: float = float(im.get_width())
		for y in range(ink_top, mini(cutoff + 1, im.get_height())):
			for x in im.get_width():
				if im.get_pixel(x, y) != bg:
					cx = minf(cx, float(x))
					break
		centroids.append(cx)
		changed_total += changed
		prev = im

	var lo: float = centroids[0]
	var hi: float = centroids[0]
	for c in centroids:
		lo = minf(lo, c)
		hi = maxf(hi, c)
	var travel: float = hi - lo
	var texels: float = travel / float(maxi(scale_n, 1))
	# TEXELS REDRAWN is the metric, not how far an edge slid. wind.gdshader
	# samples its noise per fragment, so neighbouring columns of one sprite
	# round to offsets differing by 0 or 1 and the silhouette RIPPLES — mature
	# Chusquea redraws 17k physical pixels while its leading edge never moves
	# at all. An edge-travel bar was written for the rigid one-sample-per-plant
	# version this replaced, and it scores the correct shader as static.
	var px_per_texel: float = float(maxi(scale_n * scale_n, 1))
	var texel_changes: float = float(changed_total) / px_per_texel / 15.0
	var ink_texels: float = float(ink_area) / px_per_texel
	var churn: float = texel_changes / maxf(ink_texels, 1.0)
	# 5% of the ink redrawn per sample is the bar. Below it the sway is
	# rounding to zero and the plant reads as static however alive the other
	# numbers look — the first version shipped at 0%.
	var pass_ok: bool = churn >= 0.05
	print("  %-15s stage %d   %5.1f of %5.1f ink texels/sample = %3.0f%%   edge %4.1f   %s"
		% [species_path.get_file().get_basename(), inst.growth_stage,
			texel_changes, ink_texels, churn * 100.0, texels,
			"ok" if pass_ok else "STATIC"])
	return pass_ok
