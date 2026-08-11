extends SceneTree

## Is turning Y-sort OFF on the south-cliff skirt layers VISUALLY FREE?
##
## The skirt (CliffN8 / CliffN6 / CliffN4, ~980 tiles) is authored with
## y_sort_enabled = true in procedural_base.tscn. Y-sort is expensive — a paired
## A/B measured it at ~0.9 ms / 15% of the web frame across the ground stack, and
## it costs draw calls (518 -> 393) — so switching it off where it buys nothing
## is free performance.
##
## "Buys nothing" is the part that cannot be reasoned out. The skirt sits BELOW
## the playable ground (altitudes -4/-6/-8) and mostly outside the walkable disc,
## which SOUNDS unable to overlap anything. But it descends SOUTH, i.e. TOWARD the
## camera, and a cube closer to the camera is exactly the thing that should draw
## OVER a walker standing behind it. Only 215 of its 982 tiles are more than two
## cells from a walkable cell, so most of it is near ground someone can stand on.
##
## So this renders the same map twice — skirt Y-sort on, then off — and diffs the
## two images pixel for pixel. Identical means the sorting was decorative and can
## go. Any difference is the exact case the reasoning missed, and the tool saves
## a diff mask showing where.
##
## Needs a rendering context — do NOT pass --headless.
##
##   "../Godot_v4.6.1.../Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/verify_cliff_ysort.gd -- --out /tmp/cliff
##
## Args: --out <dir>  --seed <n>  --tol <n>   (tol = max allowed channel delta)
##
## WHAT THIS PROVES, AND WHAT IT DOES NOT. It compares ONE camera framing on ONE
## seed with the crowd wherever the spawner put it. It is evidence, not a proof:
## a walker standing at the one lip cell that does overlap the skirt might simply
## not be there this run. Run it on several seeds before trusting it, which is
## why --seed exists.

const WINDOW_SIZE := Vector2i(960, 540)

var _out: String = "/tmp/cliff"
var _seed: int = 26
var _tol: int = 0

var _frames: int = 0
var _map: Node = null
var _painted: bool = false
var _shot_on: Image = null
var _shot_ctl: Image = null
var _stage: int = 0
var _wait_until: int = 0


func _initialize() -> void:
	var argv := OS.get_cmdline_user_args()
	var i: int = 0
	while i < argv.size():
		match argv[i]:
			"--out": _out = argv[i + 1]; i += 1
			"--seed": _seed = int(argv[i + 1]); i += 1
			"--tol": _tol = int(argv[i + 1]); i += 1
		i += 1


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		if current_scene != null:
			current_scene.queue_free()
		DisplayServer.window_set_size(WINDOW_SIZE)
		_map = load("res://scenes/main.tscn").instantiate()
		root.add_child(_map)
		return false

	if _frames < 3:
		return false

	var pw := root.get_tree().get_first_node_in_group(&"procedural_world")
	if pw == null:
		return false

	# Pin the seed and regenerate — but only AFTER the boot generation has
	# finished. ProceduralWorld._ready starts regenerate_async(), a coroutine
	# that paints across frames, and nothing guards against a second generation
	# starting on top of it: doing so interleaves two paints and the same seed
	# produces a different map every run.
	if _stage == 0:
		if not pw.is_connected(&"generation_finished", _on_painted):
			pw.connect(&"generation_finished", _on_painted)
		if not _painted:
			return false
		_painted = false
		pw.set(&"randomize_seed_on_ready", false)
		pw.set(&"seed_override", _seed)
		pw.call_deferred(&"regenerate")
		_stage = 1
		return false

	if _stage == 1:
		if not _painted:
			return false
		_strip_atmosphere()
		_wait_until = _frames + 45  # let the crowd take a few steps
		_stage = 2
		return false

	if _stage == 2:
		if _frames < _wait_until:
			return false
		_shot_on = _grab()
		_wait_until = _frames + 8
		_stage = 3
		return false

	# A CONTROL DIFF FIRST: two grabs the same distance apart with NOTHING
	# changed. The tile shaders animate on TIME — wind on grass, flow on water —
	# and pausing the game clock does not pause them, so two frames of the SAME
	# scene already differ. Without this the tool blames that on the y-sort:
	# it reported "the skirt's Y-sort IS doing something" at 2600 differing
	# pixels, then 2064 on a repeat. A real sorting change is identical every
	# run; a number that moves is animation.
	if _stage == 3:
		if _frames < _wait_until:
			return false
		_shot_ctl = _grab()
		_set_cliff_ysort(false)
		_wait_until = _frames + 8  # let the layers rebuild their canvas items
		_stage = 4
		return false

	if _stage == 4:
		if _frames < _wait_until:
			return false
		_compare(_shot_on, _shot_ctl, _grab())
		quit(0)
		return true

	return false


func _on_painted() -> void:
	_painted = true


## The crowd and the fires move every frame, so anything animated has to stop or
## the diff measures the animation instead of the sorting. This is the same
## stripping preview_fence.gd does, plus freezing the systems that tick.
func _strip_atmosphere() -> void:
	for n in ["TitleIntro", "RainLayer", "PostProcessLayer", "HUD",
			"FireAuraLayer", "DebugOverlay"]:
		var found: Node = _map.find_child(n, true, false)
		if found != null:
			found.free()
	for group in [&"fire_manager", &"visitor_spawner"]:
		var g := root.get_tree().get_first_node_in_group(group)
		if g != null:
			g.set_process(false)
	var clock := root.get_node_or_null(^"/root/TimeManager")
	if clock != null:
		clock.set(&"paused", true)
	# FREEZE SHADER TIME. Pausing the game clock does NOT stop the tile shaders —
	# wind on grass and flow on water animate off the TIME built-in, which Godot
	# scales by Engine.time_scale. Without this the control diff is non-zero
	# (5352 px on seed 7, 1784 on seed 99) and swamps the signal, so the tool
	# cannot tell a sorting change from a ripple.
	Engine.time_scale = 0.0
	# Every walker: stop it where it stands, so the two frames are the same scene.
	for n in _all_nodes(_map):
		if n.has_method(&"set_process"):
			var s: Script = n.get_script() as Script
			if s != null and s.resource_path.get_file().get_basename() in [
					"visitor", "player", "grid_walker"]:
				n.set_process(false)
				n.set_physics_process(false)


func _set_cliff_ysort(on: bool) -> void:
	var n: int = 0
	for node in _all_nodes(_map):
		if node is TileMapLayer and String(node.name).begins_with("Cliff"):
			(node as TileMapLayer).y_sort_enabled = on
			n += 1
	print("cliff layers set to y_sort=%s: %d" % [str(on), n])


func _all_nodes(under: Node) -> Array[Node]:
	var out: Array[Node] = []
	var stack: Array[Node] = [under]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


## No `await process_frame` here: that would make this a coroutine and _process()
## returns a bool, so it cannot await. Reading the viewport texture inside
## _process yields the LAST presented frame, which is why each stage waits
## several frames after changing anything before grabbing.
func _grab() -> Image:
	return root.get_texture().get_image()


func _compare(a: Image, ctl: Image, b: Image) -> void:
	if a == null or b == null or ctl == null:
		print("FAILED: could not grab all three frames")
		return
	DirAccess.make_dir_recursive_absolute(_out)
	a.save_png("%s/0_ysort_on.png" % _out)
	b.save_png("%s/1_ysort_off.png" % _out)
	var control: Array = _diff(a, ctl, "%s/3_control.png" % _out)
	var test: Array = _diff(a, b, "%s/2_diff.png" % _out)
	var total: int = a.get_width() * a.get_height()
	print("\n=== cliff y_sort visual equivalence (seed %d) ===" % _seed)
	print("  control (same scene, nothing changed): %6d px, worst delta %d"
			% [control[0], control[1]])
	print("  test    (skirt y_sort turned off):     %6d px, worst delta %d"
			% [test[0], test[1]])
	print("  of %d px total. wrote %s/{0_ysort_on,1_ysort_off,2_diff,3_control}.png"
			% [total, _out])
	# The control is the FLOOR: animated tile shaders move between any two
	# frames. Only a test diff clearly above that floor is attributable to
	# the y-sort.
	if test[0] <= control[0]:
		print("  NO EFFECT — the test diff is at or under the animation floor, so")
		print("  the skirt's Y-sort is not doing anything visible here.")
	else:
		print("  ABOVE THE FLOOR by %d px — some of that IS the y-sort."
				% (test[0] - control[0]))
		print("  Compare 2_diff.png against 3_control.png.")


## Pixels differing by more than --tol, plus the worst channel delta. Writes a
## mask: red where changed, the source dimmed elsewhere for context.
func _diff(a: Image, b: Image, path: String) -> Array:
	var diff := Image.create(a.get_width(), a.get_height(), false, Image.FORMAT_RGB8)
	var changed: int = 0
	var worst: int = 0
	for y in a.get_height():
		for x in a.get_width():
			var ca: Color = a.get_pixel(x, y)
			var cb: Color = b.get_pixel(x, y)
			var d: int = int(round(maxf(maxf(
					absf(ca.r - cb.r), absf(ca.g - cb.g)), absf(ca.b - cb.b)) * 255.0))
			worst = maxi(worst, d)
			if d > _tol:
				changed += 1
				diff.set_pixel(x, y, Color(1, 0, 0))
			else:
				diff.set_pixel(x, y, Color(ca.r * 0.25, ca.g * 0.25, ca.b * 0.25))
	diff.save_png(path)
	return [changed, worst]

