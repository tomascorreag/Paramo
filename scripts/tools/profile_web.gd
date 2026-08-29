extends Node

## Profiles the SHIPPED WEB BUILD, from inside it.
##
## Every other tool in scripts/tools/ is a `--script` SceneTree that cannot exist
## on web: there is no command line, and the export boots `run/main_scene`. So
## this one is a NODE that attaches to the live game (scripts/tools/
## web_profile_boot.gd puts it there when the page is opened with `?profile`),
## measures the real map with the real systems, and prints to the browser console
## — which is where Godot routes `print()`.
##
##   local:   http://localhost:8000/?profile          (serve docs/ over http)
##   desktop: --path . --scene res://scenes/main.tscn -- --profile
##
## Desktop parity is not a nicety: an export-plus-browser round trip is a slow
## way to find a typo, so the harness must be runnable the fast way first.
##
## ----------------------------------------------------------------------------
## WHY IT IS SHAPED LIKE THIS
##
## Two facts about a browser invalidate the measurement style every other tool in
## this repo uses, and both are worked around here rather than assumed away.
##
## 1. THE CLOCK IS COARSE. Browsers quantise performance.now() as a Spectre
##    mitigation — typically to 100 us without cross-origin isolation, which this
##    build deliberately runs without (single-threaded, no COOP/COEP; see
##    CLAUDE.md's web export section). Time.get_ticks_usec() inherits that. So a
##    3.5 us reading — the Player row that profile_systems.gd resolves happily on
##    desktop — is BELOW ONE TICK of the available clock and is pure noise.
##    Phase 1 therefore MEASURES the granularity instead of assuming it, and
##    every later timing loop sizes its own rep count against that number.
##
## 2. THE FRAME RATE IS PINNED. The main loop runs off requestAnimationFrame, so
##    vsync cannot be disabled the way profile_day_boundary.gd disables it on
##    desktop. Every frame reads as the refresh interval until it actually MISSES
##    one. Under that floor "is rain expensive?" is unanswerable — rain on and
##    rain off both measure 16.7 ms.
##
##    The answer to (2) is BALLAST. assets/shaders/profile_ballast.gdshader is a
##    fullscreen pass that costs real fill and changes no pixel. Stacking N of
##    them drives the frame over budget by a linear amount, so:
##      - the SLOPE of frame-time against N prices one fullscreen pass, and
##      - with the baseline already over budget, toggling a real layer moves a
##        number that was previously pinned.
##    Fill is the thing worth measuring here. Desktop cannot resolve this
##    project's canvas fill at all (benchmark_fire.gd; the memo on it), and the
##    web target differs from desktop in fragment cost far more than in script
##    cost — which is also why the CPU census is last and smallest.
##
## OUTPUT goes three places, because reading a canvas is awkward: the browser
## console, an on-screen panel (so a screenshot is sufficient), and
## `window.__paramo_profile` (so it can be lifted out with one console
## expression).

const BALLAST_SHADER := "res://assets/shaders/profile_ballast.gdshader"

## Frames discarded at the top of every block. A configuration change can cost a
## shader compile, a framebuffer reallocation and a GC — none of which is the
## steady-state cost being measured.
const WARMUP_FRAMES: int = 30
## Frames averaged per block. Raised from 60 when the A/B grew to ~16 rows: with
## vsync unlocked a frame is ~5 ms, so 60 frames is a 0.3 s sample and the small
## post/UI layers were losing to the noise floor rather than to being cheap.
const MEASURE_FRAMES: int = 120
## Ballast levels for the calibration sweep. 0 anchors the intercept; the top end
## has to be enough to break a 16.7 ms budget or the whole sweep sits on the
## vsync floor and the fit is meaningless.
## MEASURED: an RTX 3080 at 1440x810 absorbs 8 of these without missing a frame
## (a flat 13.33 ms at every level), which is the same wall CLAUDE.md's fire
## benchmark hit — desktop cannot resolve this project's fill. The top end is set
## for the WEB target, where the budget does break; on desktop the sweep is
## expected to report a zero slope and say so.
const BALLAST_STEPS: Array[int] = [0, 4, 8, 16, 32]
## Ballast held during the layer A/B. Chosen at run time from the sweep — the
## smallest level measured to clear the vsync floor — falling back to this.
const BALLAST_FALLBACK: int = 32

## How far from a walkable cell a tile can be and still be overlapped by an entity
## standing there. Entity sprites are ~2 cells tall in this projection, so 2 is
## the conservative choice; raising it only shrinks the reported ceiling.
const _SORT_MARGIN_CELLS: int = 2

const SETTLE_MIN_FRAMES: int = 60
const GRID_STABLE_FRAMES: int = 60

var fires: int = 40
var visitors: int = 8
## Pin the map so two runs are comparable. -1 leaves level1's shipped
## randomize_seed_on_ready alone (a different mountain every launch).
var map_seed: int = -1
## Paint the ground layers with Y-sort on (default) or off. Applied BEFORE
## generation, then the world is regenerated, because the flag only changes how
## tiles are grouped into CanvasItems at PAINT time.
var ground_ysort: bool = true

var _prepared: bool = false

var _map: Node = null
var _pathfinder: Pathfinder = null
var _spawner: Node = null
var _ballast_layers: Array[CanvasLayer] = []
var _panel: Label = null

var _frames: int = 0
var _grid_stamp: int = 0
var _stable_since: int = 0
var _painted: bool = false
var _loaded: bool = false

var _clock_tick_us: float = 1.0
var _vsync_floor_ms: float = 0.0

## Queue of measurement blocks; each is {name, ballast, apply(bool)}.
var _blocks: Array = []
var _block_i: int = -1
var _block_frames: int = 0
var _samples: Array[float] = []
var _last_us: int = 0
var _results: Array = []

var _lines: Array[String] = []


func _ready() -> void:
	name = "ProfileWeb"
	_build_panel()
	_say("paramo web profiler — settling the map...")


# ----------------------------------------------------------------------------
# Drive
# ----------------------------------------------------------------------------

func _process(_delta: float) -> void:
	_frames += 1

	if not _loaded:
		if not _settled():
			if _frames > 6000:
				_say("FAILED: the map never settled.")
				set_process(false)
			return
		# ONLY NOW, with the BOOT generation finished. ProceduralWorld._ready
		# calls regenerate_async(), a coroutine that paints across many frames,
		# and there is NO guard against a second generation starting while it
		# runs. Calling regenerate() at frame 1 — which is what this did — left
		# two generations interleaving their paints, so the same pinned seed
		# produced 3362 tiles on one run and 2903 on the next. That looked like
		# "the seed is not honoured" and was really a race.
		if not _prepared:
			_prepared = true
			if _prepare():
				# Wait for the SECOND generation the same way as the first.
				_painted = false
				_grid_stamp = 0
				_stable_since = _frames
				return
		_load_the_map()
		_measure_clock()
		_plan()
		_loaded = true
		_last_us = Time.get_ticks_usec()
		return

	# --- one frame of the current block ---
	var now := Time.get_ticks_usec()
	var frame_ms: float = float(now - _last_us) / 1000.0
	_last_us = now

	if _block_i < 0:
		_begin_block(0)
		return

	_block_frames += 1
	if _block_frames > WARMUP_FRAMES:
		_samples.append(frame_ms)

	if _samples.size() < MEASURE_FRAMES:
		return

	_end_block()
	if _block_i + 1 < _blocks.size():
		_begin_block(_block_i + 1)
	else:
		_teardown()
		_report()
		set_process(false)
		# On web the report IS the artefact and the tab has to stay up to be read.
		# On desktop this is a CLI run like every other tool here, so it exits.
		if not OS.has_feature("web"):
			get_tree().quit(0)


func _begin_block(i: int) -> void:
	_block_i = i
	_block_frames = 0
	_samples.clear()
	var b: Dictionary = _blocks[i]
	_set_ballast(int(b["ballast"]))
	(b["apply"] as Callable).call(true)
	_say("[%d/%d] %s" % [i + 1, _blocks.size(), b["name"]])
	# Re-anchor: the setup above happened INSIDE this frame and its cost belongs
	# to no block. Warmup would absorb it anyway; this makes that explicit.
	_last_us = Time.get_ticks_usec()


func _end_block() -> void:
	var b: Dictionary = _blocks[_block_i]
	(b["apply"] as Callable).call(false)
	_samples.sort()
	var sum: float = 0.0
	for s in _samples:
		sum += s
	_results.append({
		"name": b["name"],
		"kind": b["kind"],
		"ballast": b["ballast"],
		"count": (b["hidden"] as Array).size() if b.has("hidden") else 0,
		"mean": sum / float(_samples.size()),
		"med": _samples[_samples.size() / 2],
		"p95": _samples[int(float(_samples.size()) * 0.95)],
		"min": _samples[0],
	})


# ----------------------------------------------------------------------------
# Phase 1 — what can this clock even see
# ----------------------------------------------------------------------------

## The smallest non-zero step Time.get_ticks_usec() will report, found by hammering
## it. On desktop this comes back at 1 us; in a browser it is the Spectre
## quantum, typically 100 us, and everything downstream is sized against it.
##
## Reported as a RANGE of observed steps rather than just the minimum: a single
## anomalous small step (a clock the browser did not coarsen, a lucky boundary)
## would otherwise claim a precision the next 10000 samples do not have.
func _measure_clock() -> void:
	var steps: Array[int] = []
	var prev: int = Time.get_ticks_usec()
	var spins: int = 0
	while steps.size() < 200 and spins < 4000000:
		spins += 1
		var t: int = Time.get_ticks_usec()
		if t != prev:
			steps.append(t - prev)
			prev = t
	if steps.is_empty():
		_clock_tick_us = 1000.0
		return
	steps.sort()
	_clock_tick_us = float(steps[steps.size() / 2])
	_say("clock granularity: median step %.0f us (min %d, max %d over %d steps)"
			% [_clock_tick_us, steps[0], steps[-1], steps.size()])
	if _clock_tick_us > 10.0:
		_say("  -> COARSE. Anything under ~%.0f us is unmeasurable here; every"
				% (_clock_tick_us * 2.0))
		_say("     loop below is amortised over enough reps to clear it.")


# ----------------------------------------------------------------------------
# Plan
# ----------------------------------------------------------------------------

func _plan() -> void:
	_blocks.clear()

	# Calibration: same picture, N extra fullscreen passes. The slope prices one
	# pass; the intercept is everything that is NOT fill.
	for k in BALLAST_STEPS:
		_blocks.append({
			"name": "ballast x%d" % k, "kind": "sweep", "ballast": k,
			"apply": func(_on: bool) -> void: pass,
		})

	# A/B of the real layers, all at the same ballast so they are comparable.
	# Each entry HIDES its layer for the block and restores it afterwards, so the
	# baseline row is "everything on" and a row reading LOWER than baseline is
	# that layer's cost.
	# THREE FAMILIES, each with its aggregate AND its parts. The aggregate is not
	# redundant: parts that do not sum to their whole means something is shared,
	# double-counted, or drifting, and that is worth seeing.
	#
	# NOTE every toggle is typed as Node and driven through set(&"visible"), NOT
	# cast to CanvasItem. Most of the post/UI entries are CanvasLayer, which is
	# NOT a CanvasItem — the cast returns null and the row DISAPPEARS FROM THE
	# REPORT rather than erroring, so the run looks clean while measuring nothing.
	# That is exactly what the first desktop run of this tool did.
	# EVERY ENTRY IS A CALLABLE, resolved when its block STARTS, never here.
	# Visitors spawn on the spawner's stagger over the seconds after the map
	# loads, so a list captured at plan time is EMPTY and the row silently
	# skipped itself — which is how the first decomposed run reported no visitor
	# cost at all. Flora and the runtime-added structure layers have the same
	# shape. Resolving late also makes the printed count the count that was
	# actually hidden.
	var world: Node = _node("World")
	var ab: Array = [
		# --- world: what "55.8% of the frame" is actually made of --------------
		["world ALL", func() -> Array: return _one(world)],
		["world: terrain layers", func() -> Array: return _of_type(world, "TileMapLayer")],
		# The terrain row split three ways, because "terrain is half the frame"
		# has two completely different answers hiding in it. StructureLayerManager
		# spawns TWO TileMapLayers PER ALTITUDE (a structure layer and a preview
		# layer) over the whole altitude range, so most of these are EMPTY: the
		# previews hold tiles only while a placement ghost is on screen. If the
		# cost tracks the LAYER COUNT rather than the painted tiles, the fix is
		# deleting nodes; if it tracks the ground layers, it is a real rendering
		# problem. Only splitting them can tell the two apart.
		["world:   ground layers", func() -> Array:
			return _of_type(world, "TileMapLayer").filter(
				func(n: Node) -> bool: return n.name.begins_with("Ground"))],
		["world:   structure layers", func() -> Array:
			return _of_type(world, "TileMapLayer").filter(
				func(n: Node) -> bool: return n.name.begins_with("Structures"))],
		["world:   preview layers (empty)", func() -> Array:
			return _of_type(world, "TileMapLayer").filter(
				func(n: Node) -> bool: return n.name.begins_with("PreviewStructures"))],

		# THE DISCRIMINATING PROBE. "Ground layers cost 44% of the frame" has two
		# candidate mechanisms wanting OPPOSITE fixes:
		#   (a) OVERDRAW  — 18 layers each painting across the visible area. Fix
		#                   by not drawing what a higher layer occludes.
		#   (b) Y-SORT    — y_sort_enabled makes a TileMapLayer submit its tiles
		#                   as individually depth-sorted items instead of batching
		#                   them, so cost tracks TILE COUNT, not pixels. Fix by
		#                   sorting less, not by drawing less.
		# Turning y-sort off is visually wrong, but it separates the two in one
		# block: if the cost collapses it is (b), if it barely moves it is (a).
		["world:   ground y_sort OFF", func() -> Array: return _ground_layers(),
			&"y_sort_enabled", false],
		# And a coarse per-band split. Overdraw is spread roughly evenly across
		# layers that all cover the screen; per-tile cost concentrates in the few
		# layers that actually hold most of the mountain.
		# THE TILE-SHADER PROBE. base_tileset.tres assigns materials PER TileData
		# (wind on grass, flow on water, waterfall), which costs twice: a shader
		# runs on every fragment of every such tile, AND a material change breaks
		# the batch, so interleaved shaded/unshaded tiles cannot draw together.
		# Nulling the materials keeps every tile drawn — same geometry, same
		# pixels, same count — so what this isolates is the SHADER, not the tile.
		["world:   tile materials OFF", func() -> Array: return _shaded_tile_datas(),
			&"material", null],
		["world:   ground band low", func() -> Array: return _ground_band(0, 6)],
		["world:   ground band mid", func() -> Array: return _ground_band(6, 12)],
		["world:   ground band high", func() -> Array: return _ground_band(12, 99)],
		# THE GLOBAL SORT. `World` itself is y_sort_enabled, which merges EVERY
		# descendant's canvas items into ONE sorted list — thousands of tiles plus
		# every entity sprite. That is invisible to the per-LAYER y_sort probe
		# above (which is why that probe's negative did not clear sorting), costs
		# no extra draw calls, and scales with ITEM COUNT rather than pixels,
		# which is the shape the ground-layer cost actually has.
		# Visually wrong for a block; that is the point of a probe.
		["world: World.y_sort OFF", func() -> Array: return _one(world),
			&"y_sort_enabled", false],

		# NOT `procedural_object` — that group is what ObjectPainter PAINTED, which
		# on this map is overwhelmingly ROCKS. Frailejones are PLAYER-PLACED, so a
		# row labelled "flora" that reads the group is really measuring rocks. Both
		# are matched by script instead, and the census below prints the counts so
		# a row cannot be silently mislabelled again.
		["world: objects (painted)", func() -> Array:
			return get_tree().get_nodes_in_group(&"procedural_object")],
		# THE PLANT SWAY. Same shape as the tile-materials probe above and for
		# the same reason: nulling the material keeps every plant drawn — same
		# geometry, same pixels, same count — so what this isolates is the
		# shader. It has to be measured HERE rather than by exporting twice and
		# diffing, because sequential web runs are not paired: two runs of the
		# same seed came back at 5.0 and 11.2 ms with 150 canvas items between
		# them. Both CanvasItems of a clumped plant carry the material (the
		# Sprite2D holds the frontmost individual, the node's own _draw holds
		# the rest), so both have to be nulled.
		["world: plant sway OFF", func() -> Array: return _swaying_plant_items(),
			&"material", null],
		["world: frailejones", func() -> Array: return _by_script(world, "frailejon")],
		["world:   frailejon sprites", func() -> Array:
			return _named_under(_by_script(world, "frailejon"), "Sprite2D")],
		# EVERY shadow in the world — frailejones, the player, the crowd — matched
		# by SHADER, not by node name.
		#
		# Name matching does not work here and fails SILENTLY. Frailejon and
		# GridWalker both REPARENT their `Shadow` to World, so the shadow y-sorts
		# against the terrain on its own instead of inheriting its owner's sort
		# key. Godot renames colliding names on reparent, so exactly ONE node in
		# the whole scene still answers to "Shadow" — a `name == "Shadow"` probe
		# reports 1 shadow on a map covered in them, which is what this tool did
		# until a human said "I do see the frailejon shadows though".
		["world: ALL shadows", func() -> Array: return _shadow_nodes()],
		["world: visitors", func() -> Array: return _by_script(world, "visitor")],
		["world: player", func() -> Array: return _one(_node("Player"))],
		# VFXContainer is a CHILD OF World, so "world ALL" contains it. That
		# confound is why this row exists next to it rather than off in its own
		# family — the first web run reported world at 42% without noting it.
		["world: fire vfx", func() -> Array: return _one(_node("VFXContainer"))],

		# --- post: the fullscreen stack ---------------------------------------
		# The rows most likely to behave differently on the real target. Each of
		# these is a fullscreen pass, and on a tile-based GPU (Apple Silicon, i.e.
		# the MacBook Neo this is aimed at) a pass that samples the screen texture
		# forces a tile resolve rather than being nearly free the way it is on an
		# immediate-mode desktop GPU.
		["post: grade", func() -> Array: return _one(_node("PostProcessLayer"))],
		["post: rain", func() -> Array: return _one(_node("RainLayer"))],
		["post: fire aura", func() -> Array: return _one(_node("FireAuraLayer"))],
		["post: background", func() -> Array: return _one(_node("BackgroundLayer"))],
		["post: ambient modulate", func() -> Array: return _one(_node("AmbientModulate"))],

		# --- ui ---------------------------------------------------------------
		["ui: hud", func() -> Array: return _one(_node("HUD"))],
		["ui: field journal", func() -> Array: return _one(_node("FieldJournal"))],
		["ui: ux overlay", func() -> Array: return _one(_node("UXOverlay"))],
		["ui: tile debug overlay", func() -> Array: return _one(_node("TileDebugOverlay"))],
		["ui: debug overlay", func() -> Array: return _one(_node("DebugOverlay"))],
	]
	# EVERY A/B ROW IS PAIRED WITH ITS OWN BASELINE, measured immediately before
	# it. This doubles the block count and is worth it.
	#
	# MEASURED, and the reason it changed: with three baselines spread across 22
	# blocks the run DRIFTED — 5.40, 5.30, then 7.10 ms for the identical
	# configuration — which inflated the noise floor to +/-1.80 ms and buried every
	# row under half a millisecond. Worse, that floor fed the responsiveness check
	# and made a run whose frame moved +3.10 ms under ballast report itself as
	# UNRESPONSIVE. Drift is not noise to be averaged out; it is a trend, and the
	# standard answer to a trend is to pair each measurement with a control taken
	# next to it in time.
	var placed: int = 0
	for pair in ab:
		_blocks.append(_baseline_block("A/B baseline"))
		var label: String = pair[0]
		var resolve: Callable = pair[1]
		# `hidden` is captured per row and filled in when the block STARTS, so the
		# same list that was hidden is the list that gets restored — resolving
		# twice could pick up a visitor that spawned mid-block and leave it
		# invisible for the rest of the run.
		# Most rows HIDE their nodes; a row may instead name a property and the
		# value to force during the block (the y-sort probe). Originals are stored
		# and restored rather than assumed, so a layer that was already off does
		# not come back on.
		var prop: StringName = &"visible"
		var off_value: Variant = false
		if pair.size() >= 4:
			prop = pair[2]
			off_value = pair[3]
		var originals: Array = []
		var hidden: Array = []
		_blocks.append({
			"name": "A/B minus %s" % label, "kind": "ab", "ballast": -1,
			# An Array is a reference in GDScript, so the block keeps a live view
			# of what its closure actually hid — that is where the count comes
			# from, rather than from a guess made at plan time.
			"hidden": hidden,
			"apply": func(on: bool) -> void:
				if on:
					hidden.assign((resolve.call() as Array).filter(
							func(n: Variant) -> bool: return n != null))
					originals.clear()
					# Object, NOT Node: the tile-shader probe toggles a property
					# on TileData, which is a Resource. Typing this loop as Node
					# makes that row fail at run time.
					for n: Object in hidden:
						originals.append(n.get(prop))
					for n: Object in hidden:
						n.set(prop, off_value)
				else:
					for i in hidden.size():
						if is_instance_valid(hidden[i]):
							hidden[i].set(prop, originals[i]),
		})
		placed += 1
	# One trailing baseline so the last row has a control after it too, and so the
	# run's total drift is still visible end to end.
	_blocks.append(_baseline_block("A/B baseline"))


func _baseline_block(label: String) -> Dictionary:
	return {
		"name": label, "kind": "ab", "ballast": -1,
		"apply": func(_on: bool) -> void: pass,
	}


# ----------------------------------------------------------------------------
# Ballast
# ----------------------------------------------------------------------------

func _set_ballast(n: int) -> void:
	if n < 0:
		n = _ab_ballast()
	while _ballast_layers.size() < n:
		var layer := CanvasLayer.new()
		# Above the post-process grade (100) and the fire aura (105) so the
		# stacked screen reads see a finished frame, as a real post pass would.
		layer.layer = 200 + _ballast_layers.size()
		var rect := ColorRect.new()
		rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var mat := ShaderMaterial.new()
		mat.shader = load(BALLAST_SHADER)
		rect.material = mat
		layer.add_child(rect)
		add_child(layer)
		_ballast_layers.append(layer)
	for i in _ballast_layers.size():
		_ballast_layers[i].visible = i < n


## How much ballast the A/B rows carry — and the answer is usually NONE.
##
## Ballast exists to lift the frame off the vsync floor, because a pinned frame
## cannot get shorter when a layer is hidden. If the frame is ALREADY free to
## move (the browser was launched with --disable-gpu-vsync, so the x0 sweep row
## sits well under the refresh interval), ballast buys nothing and costs
## precision: 32 stacked screen-reads add their own jitter to every row.
##
## MEASURED: the A/B ran at x32 on the first real web run and reported a +/-0.90 ms
## noise floor, against a 5.7 ms unballasted frame — enough to swallow rain, post
## and the aura whole. The ballast was fighting a floor that had already been
## removed at the browser.
##
## So: unpinned -> 0. Pinned -> the cheapest swept level that clears the floor,
## because there some ballast is better than an unmeasurable row.
func _ab_ballast() -> int:
	var floor_ms: float = _vsync_floor_ms
	var free_running: float = -1.0
	for r: Dictionary in _results:
		if r["kind"] == "sweep" and int(r["ballast"]) == 0:
			free_running = float(r["med"])
	if floor_ms <= 0.0:
		return 0
	if free_running > 0.0 and free_running < floor_ms * 0.85:
		return 0  # frame time is free to move; do not add noise to it
	for r: Dictionary in _results:
		if r["kind"] == "sweep" and float(r["med"]) > floor_ms * 1.25:
			return int(r["ballast"])
	return BALLAST_FALLBACK


# ----------------------------------------------------------------------------
# Report
# ----------------------------------------------------------------------------

func _report() -> void:
	_lines.clear()
	_say("")
	_say("=== paramo web profile ===")
	_say("%s | %s | %s" % [OS.get_name(), _gl_renderer(),
			"threads" if OS.has_feature("threads") else "single-threaded"])
	if _software_rasterizer():
		_say("*** SOFTWARE RASTERIZER. Every fill number below is INVALID: a CPU")
		_say("*** rasterizer's fragment cost has no relation to a GPU's, and fill")
		_say("*** is the only thing this tool exists to measure. The script census")
		_say("*** at the bottom is still good. Re-run with a real GPU context")
		_say("*** (headful browser) before quoting anything from the fill tables.")
	var win: Vector2i = get_window().size
	_say("render target %dx%d (%.2f Mpx), scale x%d, clock tick %.0f us"
			% [win.x, win.y, float(win.x * win.y) / 1e6,
			int(DisplayManager.current_scale), _clock_tick_us])
	_say("load: %d fires, %d visitors" % [_burning(), _crowd()])
	# THE RUN'S OWN CONFIGURATION, re-stated here because _report() clears _lines
	# before building the blob that gets POSTed — so the setup messages printed
	# during _prepare() reach the browser console and NOT the report. Two arms of
	# an A/B that do not record which arm they are cannot be compared, and that
	# is exactly what the first y-sort A/B produced.
	var g: Array = _ground_layers()
	var sorted_layers: int = g.filter(
			func(l: Node) -> bool: return bool(l.get(&"y_sort_enabled"))).size()
	_say("CONFIG: map_seed=%s, ground y_sort ON for %d of %d layers"
			% [("%d (pinned)" % map_seed) if map_seed >= 0 else "random (NOT pinned)",
			sorted_layers, g.size()])
	if map_seed < 0:
		_say("  WARNING: seed not pinned — this run's map is unique and CANNOT be")
		_say("  compared against any other run. Pass seed=N for an A/B.")
	_tile_census()

	# --- fill ---
	_say("")
	_say("--- fill: frame time vs N extra fullscreen passes ---")
	_say("  %-26s %8s %8s %8s" % ["", "med ms", "mean ms", "p95 ms"])
	var xs: Array[float] = []
	var ys: Array[float] = []
	for r: Dictionary in _results:
		if r["kind"] != "sweep":
			continue
		xs.append(float(r["ballast"]))
		ys.append(float(r["med"]))
		_say("  %-26s %8.2f %8.2f %8.2f"
				% [r["name"], r["med"], r["mean"], r["p95"]])

	var slope: float = _slope(xs, ys)
	var base_ms: float = ys[0] if not ys.is_empty() else 0.0
	_say("")
	_say("  one fullscreen pass = %.3f ms at %.2f Mpx  (=> %.3f ms/Mpx)"
			% [slope, float(win.x * win.y) / 1e6,
			slope / maxf(float(win.x * win.y) / 1e6, 0.0001)])
	var response: float = _sweep_response()
	_say("  sweep response: %+.2f ms across x0 -> x%d"
			% [response, BALLAST_STEPS[-1]])
	if not _responsive():
		_say("  WARNING: stacking %d fullscreen passes barely moved the frame."
				% BALLAST_STEPS[-1])
		if absf(ys[0] - _vsync_floor_ms) < _vsync_floor_ms * 0.15:
			_say("  Frame time is sitting ON the %.2f ms refresh interval: PINNED."
					% _vsync_floor_ms)
			_say("  Launch the browser with --disable-gpu-vsync, or raise BALLAST_STEPS.")
		else:
			_say("  Frame time is NOT at the refresh interval either, so fill is")
			_say("  simply not the bottleneck at this load — look at the census.")

	# --- A/B ---
	_say("")
	_say("--- A/B at ballast x%d %s ---" % [_ab_ballast(),
			"(frame runs free; no ballast needed)" if _ab_ballast() == 0
			else "(ballast lifts the frame off the vsync floor)"])
	# The mean of all baselines, for the header line and the share-of-frame
	# denominator only. The DELTAS use each row's own paired control (below).
	var baseline: float = -1.0
	var bsum: float = 0.0
	var bn: int = 0
	for r: Dictionary in _results:
		if String(r["name"]).begins_with("A/B baseline"):
			bsum += float(r["med"])
			bn += 1
	if bn > 0:
		baseline = bsum / float(bn)
	# THE ONE CHECK THAT DECIDES WHETHER ANY OF THIS MEANS ANYTHING. If the
	# baseline never cleared the refresh interval, the GPU finished every frame
	# early and slept — so hiding a layer cannot make the frame shorter, and every
	# delta below is scheduler jitter. Saying so is the whole point: a desktop run
	# of this tool otherwise prints a tidy "0.5% of baseline" column that is pure
	# noise, and that number would get quoted.
	# WHETHER THE DELTAS MEAN ANYTHING IS DECIDED BY MEASUREMENT, NOT BY COMPARING
	# THE BASELINE TO THE REFRESH INTERVAL. The first version of this check asked
	# `baseline <= vsync_floor * 1.1`, which is exactly backwards once the browser
	# is launched with --disable-gpu-vsync: an UNLOCKED 8.2 ms frame is BELOW the
	# 16.7 ms interval, so the check declared it "pinned, nothing measurable" on
	# the very run that produced this tool's first real fill numbers.
	#
	# The honest question is whether frame time RESPONDS to load at all. If 32
	# stacked fullscreen passes move it, the pipeline is measurable and hiding a
	# layer will move it too — whatever the refresh rate happens to be.
	var pinned: bool = not _responsive()
	if pinned:
		_say("  *** UNRESPONSIVE: %d fullscreen passes moved the frame only %+.2f ms,"
				% [BALLAST_STEPS[-1], _sweep_response()])
		_say("  *** so NO delta below measures anything. See the sweep note above.")
	_say("  %-26s %8s %8s   %s" % ["", "med ms", "delta", "share of frame"])
	var control: float = baseline
	for r: Dictionary in _results:
		if r["kind"] != "ab":
			continue
		var med: float = float(r["med"])
		# Each row is measured against the baseline block RUN IMMEDIATELY BEFORE
		# IT, so a slow drift across the run cancels instead of accumulating into
		# the delta.
		if String(r["name"]).begins_with("A/B baseline"):
			control = med
		var d: float = med - control
		var note: String = ""
		if baseline > 0.0 and not String(r["name"]).begins_with("A/B baseline"):
			# A hidden layer should make the frame CHEAPER, so the cost of the
			# layer is -delta. A positive delta means noise swamped it.
			if int(r.get("count", 0)) == 0:
				# The row ran but had nothing to hide, so its delta is a repeat of
				# the baseline. Saying "under noise" here would read as "this layer
				# is free" when the truth is "this layer was not present".
				note = "NOTHING TO HIDE"
			elif pinned:
				note = "(pinned)"
			elif -d < _noise_ms():
				note = "under noise"
			else:
				note = "%.1f%% of baseline" % (-d / baseline * 100.0)
		var n: int = int(r.get("count", 0))
		_say("  %-26s %8.2f %8.2f   %-18s %s"
				% [r["name"], med, d, note, ("x%d" % n) if n > 1 else ""])
	_say("")
	_say("  noise floor: +/- %.2f ms (median gap between adjacent paired baselines)"
			% _noise_ms())

	_census()

	_say("")
	_say("=== end ===")
	_flush()


## What a delta has to beat to mean anything: the gap between the two IDENTICAL
## baseline blocks, taken at opposite ends of the run. That is a direct
## measurement of everything the harness does not control — fires ageing, the
## crowd moving, the clock advancing, the browser's own drift — expressed in the
## same units as the rows it qualifies.
##
## Deliberately NOT the p95-to-median spread: that measures occasional hitches,
## which the median of each block already rejects, and it reported a ±1.4 ms
## floor on a run whose two baselines agreed far closer than that.
func _noise_ms() -> float:
	var b: Array[float] = []
	for r: Dictionary in _results:
		if String(r["name"]).begins_with("A/B baseline"):
			b.append(float(r["med"]))
	# The median gap between CONSECUTIVE baselines — the right scale for a paired
	# comparison, because that is exactly the distance each row sits from its own
	# control. The widest gap across ALL baselines measures the run's total DRIFT
	# instead, which the pairing already cancels; using it here would re-import
	# the error the pairing removed (it read +/-1.80 ms on a run whose adjacent
	# baselines agreed an order of magnitude more closely).
	var gaps: Array[float] = []
	for i in range(1, b.size()):
		gaps.append(absf(b[i] - b[i - 1]))
	if gaps.is_empty():
		return maxf(_clock_tick_us / 1000.0, 0.1)
	gaps.sort()
	return maxf(gaps[gaps.size() / 2], _clock_tick_us / 1000.0)


## The REAL renderer, out of WebGL rather than out of Godot.
##
## MEASURED: on web, RenderingServer.get_video_adapter_name() returns the constant
## string "WebKit WebGL" — the same on an RTX 3080 as it would be on SwiftShader.
## A software-rasterizer guard reading that value can never fire, which is worse
## than no guard at all: it reports "GPU: WebKit WebGL" and looks like it checked.
## WEBGL_debug_renderer_info is the only thing that actually knows.
func _gl_renderer() -> String:
	if not OS.has_feature("web"):
		return RenderingServer.get_video_adapter_name()
	var js := """
		(function () {
			try {
				var c = document.createElement('canvas');
				var g = c.getContext('webgl2') || c.getContext('webgl');
				if (!g) { return 'no-webgl'; }
				var e = g.getExtension('WEBGL_debug_renderer_info');
				return e ? g.getParameter(e.UNMASKED_RENDERER_WEBGL)
						 : g.getParameter(g.RENDERER);
			} catch (err) { return 'unknown'; }
		})()
	"""
	var r: Variant = JavaScriptBridge.eval(js, true)
	return String(r) if r != null else "unknown"


## Is this a CPU rasterizer pretending to be a GPU? Headless Chrome falls back to
## SwiftShader, and it does so SILENTLY — the run completes, the tables are full,
## the numbers are precise, and every fill figure in them is fiction. Read off the
## renderer string rather than off a launch flag, because the flag is what was
## REQUESTED and the string is what was GRANTED; Chrome's `--headless=new` may or
## may not get the real GPU depending on driver and machine.
func _software_rasterizer() -> bool:
	var a: String = _gl_renderer().to_lower()
	for needle in ["swiftshader", "llvmpipe", "software", "basic render", "mesa offscreen"]:
		if a.contains(needle):
			return true
	return false


## How much the frame moved between no ballast and the most ballast. This is the
## instrument's own sensitivity check: if the number is ~0 the pipeline is not
## responding to fill and nothing measured against it can be trusted.
func _sweep_response() -> float:
	var lo: float = -1.0
	var hi: float = -1.0
	for r: Dictionary in _results:
		if r["kind"] != "sweep":
			continue
		if int(r["ballast"]) == 0:
			lo = float(r["med"])
		if int(r["ballast"]) == BALLAST_STEPS[-1]:
			hi = float(r["med"])
	return (hi - lo) if (lo >= 0.0 and hi >= 0.0) else 0.0


## The response has to beat both the run-to-run noise AND a floor of half a
## millisecond — a 0.2 ms move across 32 stacked passes is not a working
## measurement even if it is technically larger than the noise.
func _responsive() -> bool:
	return _sweep_response() > maxf(_noise_ms() * 2.0, 0.5)


## How many tiles each ground layer actually holds, and how deep the stacking is.
##
## The A/B says the ground layers are fill-bound, but not WHY there is so much
## fill. This answers that directly: the number of DISTINCT cells is the
## mountain's footprint, and total tiles divided by distinct cells is the average
## STACK DEPTH — i.e. how many cubes are drawn on top of each other at one map
## position. A depth near 1 means there is no stacking to cull and the fill is
## simply the picture; a large depth means most of what is drawn is buried.
func _tile_census() -> void:
	var layers: Array = _ground_layers()
	if layers.is_empty():
		return
	var total: int = 0
	var shaded: int = 0
	var footprint: Dictionary = {}
	var per_layer: Array = []
	for l: TileMapLayer in layers:
		var cells: Array[Vector2i] = l.get_used_cells()
		total += cells.size()
		var l_shaded: int = 0
		for c in cells:
			footprint[c] = true
			# Does THIS tile carry its own material? base_tileset.tres assigns
			# shaders per TileData — wind on grass, flow on water, waterfall —
			# and a per-tile material both costs per-fragment work AND breaks the
			# batch, so the count of shaded tiles is the number that matters.
			if _tile_material(l, c) != null:
				l_shaded += 1
		shaded += l_shaded
		per_layer.append([String(l.name), int(l.get_meta("altitude", 0)),
				cells.size(), l_shaded])
	_say("")
	_say("--- ground layers: %d tiles over %d distinct map cells (avg stack depth %.1f) ---"
			% [total, footprint.size(),
			float(total) / maxf(float(footprint.size()), 1.0)])
	_say("  %d of %d tiles carry their OWN material (%.0f%%)"
			% [shaded, total, float(shaded) / maxf(float(total), 1.0) * 100.0])
	# HOW MANY GROUND TILES CAN NEVER NEED ENTITY SORTING — the ceiling on what a
	# "sort only where entities can be" split could recover.
	#
	# NOT Pathfinder.bounds_clip: that is the 48x48 grid RECT, and every painted
	# tile is inside it (measured: 0 of 2975 outside), so it answers nothing. The
	# playable area is a DISC inside that rect and the skirt is painted at coords
	# within it.
	#
	# WALKABILITY ALONE IS ALSO WRONG. A non-walkable tile still needs sorting if
	# an entity standing NEARBY can overlap it on screen — sprites are taller than
	# one cell, so a cliff tile two cells behind a visitor still draws against it.
	# The test is therefore DISTANCE FROM ANY WALKABLE CELL, with a margin for
	# sprite height.
	var grid: TileGrid = _pathfinder.grid() if _pathfinder != null else null
	if grid != null:
		var walkable: Dictionary = {}
		for c: Vector2i in grid.walkable_cells():
			walkable[c] = true
		var isolated: int = 0
		for l: TileMapLayer in layers:
			for c in l.get_used_cells():
				var near: bool = false
				for dx in range(-_SORT_MARGIN_CELLS, _SORT_MARGIN_CELLS + 1):
					for dy in range(-_SORT_MARGIN_CELLS, _SORT_MARGIN_CELLS + 1):
						if walkable.has(c + Vector2i(dx, dy)):
							near = true
							break
					if near:
						break
				if not near:
					isolated += 1
		_say("  %d of %d tiles (%.0f%%) are >%d cells from ANY walkable cell —"
				% [isolated, total, float(isolated) / maxf(float(total), 1.0) * 100.0,
				_SORT_MARGIN_CELLS])
		_say("  no entity can ever overlap them, so they never need Y-sorting.")

		# THE SKIRT LAYERS, counted separately. CliffN8/N6/N4 are painted at
		# negative altitudes past the playable disc and are authored with
		# y_sort_enabled = true in procedural_base.tscn. If NONE of their tiles
		# comes within reach of a walkable cell, that sorting is buying nothing
		# and can be switched off with no visual consequence at all.
		for l: TileMapLayer in _of_type(_node("World"), "TileMapLayer"):
			if not String(l.name).begins_with("Cliff"):
				continue
			var cells: Array[Vector2i] = l.get_used_cells()
			var far: int = 0
			for c in cells:
				var near2: bool = false
				for dx in range(-_SORT_MARGIN_CELLS, _SORT_MARGIN_CELLS + 1):
					for dy in range(-_SORT_MARGIN_CELLS, _SORT_MARGIN_CELLS + 1):
						if walkable.has(c + Vector2i(dx, dy)):
							near2 = true
							break
					if near2:
						break
				if not near2:
					far += 1
			_say("  %-10s alt %3d  %5d tiles, %d far from walkable, y_sort=%s"
					% [l.name, int(l.get_meta("altitude", 0)), cells.size(), far,
					str(l.y_sort_enabled)])
	for row in per_layer:
		if int(row[2]) == 0:
			continue
		_say("  %-14s alt %3d  %6d tiles  %5d shaded" % [row[0], row[1], row[2], row[3]])
	# Is the terrain cost FILL or SUBMISSION? Compare what those tiles could
	# possibly cost as pixels against what the A/B says they do cost. Tile art is
	# 32x32 on a 32x16 cell, so this is generous — it counts every texel of every
	# tile as if none of it were transparent or offscreen.
	var tile_mpx: float = float(total) * 32.0 * 32.0 / 1e6
	_say("  => %.2f Mpx of tile area (%.1fx the %.2f Mpx screen)"
			% [tile_mpx, tile_mpx / maxf(_screen_mpx(), 0.0001), _screen_mpx()])
	_say("  => draw calls this frame: %d"
			% int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
	# What a y-sorted World actually has to order. NODES are not the unit — a
	# TileMapLayer is one node holding thousands of sortable tiles — so both
	# numbers are reported: the tile total above is the one the sort sees.
	var world: Node = _node("World")
	var items: int = _of_type(world, "CanvasItem").size()
	var shadows: int = _shadow_nodes().size()
	var mats: int = _collect(world, func(n: Node) -> bool:
			return n is CanvasItem and (n as CanvasItem).material != null).size()
	_say("  => World: y_sort=%s, %d CanvasItem nodes (%d shadows, %d with a material)"
			% [str(world.get(&"y_sort_enabled")), items, shadows, mats])


## The material a specific painted cell resolves to, or null. Per-tile materials
## live on TileData in the TileSet, not on the layer, so this has to go through
## (source, atlas coord, alternative) for every cell.
func _tile_material(layer: TileMapLayer, cell: Vector2i) -> Material:
	var ts: TileSet = layer.tile_set
	if ts == null:
		return null
	var sid: int = layer.get_cell_source_id(cell)
	if sid < 0:
		return null
	var src: TileSetAtlasSource = ts.get_source(sid) as TileSetAtlasSource
	if src == null:
		return null
	var coord: Vector2i = layer.get_cell_atlas_coords(cell)
	var alt: int = layer.get_cell_alternative_tile(cell)
	if not src.has_tile(coord):
		return null
	var td: TileData = src.get_tile_data(coord, alt)
	return td.material if td != null else null


## Every TileData that carries a material, across every tileset the ground layers
## use. Collected once; the A/B block nulls them and puts them back.
# Every CanvasItem carrying a plant sway material: the Frailejon nodes whose
# own _draw() renders the extra individuals of a clumped cell, plus their
# Sprite2D children. Matched by "has a material", not by species, so a new
# swaying species is picked up without touching this.
func _swaying_plant_items() -> Array:
	var out: Array = []
	# `world` is a local in the row-building function, not a field.
	for n in _by_script(_node("World"), "frailejon"):
		var ci := n as CanvasItem
		if ci != null and ci.material != null:
			out.append(ci)
		var spr := n.get_node_or_null("Sprite2D") as CanvasItem
		if spr != null and spr.material != null:
			out.append(spr)
	return out


func _shaded_tile_datas() -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for l: TileMapLayer in _ground_layers():
		var ts: TileSet = l.tile_set
		if ts == null or seen.has(ts.get_instance_id()):
			continue
		seen[ts.get_instance_id()] = true
		for i in ts.get_source_count():
			var src: TileSetAtlasSource = ts.get_source(ts.get_source_id(i)) as TileSetAtlasSource
			if src == null:
				continue
			for t in src.get_tiles_count():
				var coord: Vector2i = src.get_tile_id(t)
				for a in src.get_alternative_tiles_count(coord):
					var td: TileData = src.get_tile_data(
							coord, src.get_alternative_tile_id(coord, a))
					if td != null and td.material != null:
						out.append(td)
	return out


func _screen_mpx() -> float:
	var w: Vector2i = get_window().size
	return float(w.x * w.y) / 1e6


func _slope(xs: Array[float], ys: Array[float]) -> float:
	var n: float = float(xs.size())
	if n < 2.0:
		return 0.0
	var sx: float = 0.0
	var sy: float = 0.0
	for i in xs.size():
		sx += xs[i]
		sy += ys[i]
	var mx: float = sx / n
	var my: float = sy / n
	var num: float = 0.0
	var den: float = 0.0
	for i in xs.size():
		num += (xs[i] - mx) * (ys[i] - my)
		den += (xs[i] - mx) * (xs[i] - mx)
	return num / den if den != 0.0 else 0.0


## Script cost, ported from profile_systems.gd's census — LAST and smallest,
## because it is the part least likely to differ from desktop. Reps are chosen
## adaptively against the measured clock tick instead of being hardcoded: the
## fixed 60 that reads fine on desktop returns either 0 or one whole quantum in a
## browser, i.e. noise dressed as a number.
func _census() -> void:
	_say("")
	_say("--- script _process, by script, summed over instances ---")
	# Un-freeze the fire sim, frozen for the fill blocks above: its per-frame cost
	# is the single biggest script row in this project and leaving it out would
	# make the table quietly wrong.
	var fire := get_node_or_null(^"/root/FireManager")
	if fire != null:
		fire.set_process(true)
	var by_script: Dictionary = {}
	var stack: Array[Node] = [get_tree().root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n.get_script() == null or not n.is_processing():
			continue
		if not n.has_method(&"_process"):
			continue
		if n == self:
			continue
		var path: String = (n.get_script() as Script).resource_path
		if not by_script.has(path):
			by_script[path] = []
		(by_script[path] as Array).append(n)

	var rows: Array = []
	var total: float = 0.0
	# Every measurement must span many clock ticks, or it reports the quantum.
	var target_us: float = maxf(_clock_tick_us * 50.0, 2000.0)
	for path: String in by_script:
		var nodes: Array = by_script[path]
		var reps: int = 8
		var us: float = 0.0
		while reps <= 8192:
			var t := Time.get_ticks_usec()
			for r in reps:
				for n: Node in nodes:
					if is_instance_valid(n):
						n.call(&"_process", 1.0 / 60.0)
			var elapsed: float = float(Time.get_ticks_usec() - t)
			us = elapsed / float(reps)
			if elapsed >= target_us:
				break
			reps *= 2
		total += us
		rows.append([path.get_file().get_basename(), us, nodes.size(), reps])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[1] > b[1])
	for r in rows:
		_say("  %-28s %9.1f us  x%-4d (%d reps)" % [r[0], r[1], r[2], r[3]])
	_say("  %-28s %9.1f us  = %.1f%% of a 16.7 ms frame"
			% ["TOTAL", total, total / 16700.0 * 100.0])


# ----------------------------------------------------------------------------
# Map setup
# ----------------------------------------------------------------------------

## Applies the boot-time flags and, if either was given, REGENERATES the world so
## the tiles are painted under the new settings. Returns true if a regeneration
## was started.
##
## Both flags have to act before painting, for different reasons:
##   seed   level1 ships randomize_seed_on_ready, so without pinning it the two
##          arms of an A/B are two different mountains.
##   ysort  the flag changes how TileMapLayer groups tiles into CanvasItems, and
##          that grouping is built as the tiles are painted. Setting it
##          afterwards is what made the in-run probe untrustworthy.
func _prepare() -> bool:
	if map_seed < 0 and ground_ysort:
		return false

	if not ground_ysort:
		var n: int = 0
		for l: TileMapLayer in _ground_layers():
			l.y_sort_enabled = false
			n += 1
		_say("ground y_sort DISABLED on %d layers (before paint)" % n)

	var pw := get_tree().get_first_node_in_group(&"procedural_world")
	if pw == null:
		_say("no ProceduralWorld — flags applied without regenerating")
		return false
	if map_seed >= 0:
		pw.set(&"randomize_seed_on_ready", false)
		pw.set(&"seed_override", map_seed)
		_say("map seed pinned to %d" % map_seed)
	if not pw.has_method(&"regenerate"):
		return false
	_say("regenerating the world under the new settings...")
	pw.call_deferred(&"regenerate")
	return true


func _settled() -> bool:
	_pathfinder = get_tree().get_first_node_in_group(&"pathfinder") as Pathfinder
	if _pathfinder == null:
		return false
	# NOT grid-identity stability alone: TerrainPainter lays tiles across frames,
	# so the graph settles while cells still have no tile under them — which reads
	# as "there is no grass on this map" and makes every fire refuse to ignite.
	# profile_systems.gd learned this the hard way.
	var pw := get_tree().get_first_node_in_group(&"procedural_world")
	if pw != null and not _painted:
		if not pw.is_connected(&"generation_finished", _on_painted):
			pw.connect(&"generation_finished", _on_painted)
		return false
	var grid: Object = _pathfinder.grid()
	if grid == null:
		return false
	var stamp: int = grid.get_instance_id()
	if stamp != _grid_stamp:
		_grid_stamp = stamp
		_stable_since = _frames
		return false
	return _frames >= SETTLE_MIN_FRAMES and (_frames - _stable_since) >= GRID_STABLE_FRAMES


func _on_painted() -> void:
	_painted = true


func _load_the_map() -> void:
	_map = get_tree().current_scene
	# The title intro covers the screen and gates the gameplay UX. It re-applies
	# its own state per frame, so hiding it is not enough — free it, as
	# preview_fence.gd does.
	var intro := _node("TitleIntro")
	if intro != null:
		intro.free()

	var seasons := get_node_or_null(^"/root/SeasonManager")
	if seasons != null:
		seasons.set(&"phase", 1)  # ACTIVE
	var clock := get_node_or_null(^"/root/TimeManager")
	if clock != null:
		clock.set(&"paused", false)
		clock.set(&"time_of_day", 0.45)  # midday, inside opening hours

	_spawner = _node("VisitorSpawner")
	if _spawner != null:
		_spawner.set(&"max_concurrent", maxi(visitors, 1))
		_spawner.set(&"stagger_seconds", 0.2)
		_spawner.call(&"request_visitors", visitors)

	# Rain on: it is one of the layers being A/B'd and a hidden-by-weather rain
	# layer would measure as free.
	var rain := _node("RainLayer")
	if rain != null and rain.has_method(&"set_amount"):
		rain.call(&"set_amount", 1.0)

	_light_fires()
	# FREEZE THE FIELD. Fire spreads, and `_roll_spread` calls `_ignite` directly
	# rather than through `can_ignite`, so MAX_CONCURRENT_BURNING does not bound
	# it (measured: a run of this tool asking for 40 fires reached 199 across its
	# blocks, and the VFX node count doubled with it). A fill A/B whose load
	# changes under it is measuring the load, not the layers.
	#
	# Only the SIMULATION is frozen. Every BurningCellVFX and FireBlobColumn keeps
	# its own _process and keeps animating, so the rendering load — the thing
	# being priced — stays exactly what the game draws, and stays constant.
	# Re-enabled for the census, which has to see the real per-frame cost.
	var fire := get_node_or_null(^"/root/FireManager")
	if fire != null:
		fire.set_process(false)
	_measure_vsync_floor()


func _light_fires() -> void:
	var fire := get_node_or_null(^"/root/FireManager")
	if fire == null or _pathfinder == null:
		return
	var anchor := _start_cell()
	if anchor == Pathfinder.NO_CELL:
		return
	var cells: Array = _pathfinder.compute_reachable_set(anchor).keys()
	if cells.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260810
	var tries: int = 0
	while int(fire.call(&"burning_count")) < fires and tries < 20000:
		tries += 1
		fire.call(&"ignite", cells[rng.randi_range(0, cells.size() - 1)])


## The refresh interval, taken from the engine rather than guessed, so a 120 Hz
## or 144 Hz display does not make every row look "over budget". Falls back to
## 60 Hz when the platform will not say.
func _measure_vsync_floor() -> void:
	var hz: float = DisplayServer.screen_get_refresh_rate(
			DisplayServer.window_get_current_screen())
	if hz <= 0.0:
		hz = 60.0
	_vsync_floor_ms = 1000.0 / hz


func _teardown() -> void:
	_set_ballast(0)


func _start_cell() -> Vector2i:
	if _spawner != null:
		var c: Vector2i = _spawner.call(&"entry_cell")
		if c != Pathfinder.NO_CELL:
			return c
	var player := get_tree().get_first_node_in_group(&"player")
	if player != null and "current_cell" in player:
		return player.current_cell
	return Pathfinder.NO_CELL


func _burning() -> int:
	var fire := get_node_or_null(^"/root/FireManager")
	return int(fire.call(&"burning_count")) if fire != null else 0


func _crowd() -> int:
	return int(_spawner.call(&"live_count")) if _spawner != null else 0


func _node(n: String) -> Node:
	var scene := get_tree().current_scene
	return scene.find_child(n, true, false) if scene != null else null


## One node as a toggle list, or an empty list if it was not found — so a missing
## node skips its row instead of crashing the run 90 seconds in.
func _one(n: Node) -> Array:
	return [n] if n != null else []


## Every node under `under` matching `pred`. Collected by TYPE rather than by name
## prefix on purpose: StructureLayerManager adds TileMapLayers at RUN TIME, and a
## "Ground*" name match would silently miss them and under-report the terrain.
func _collect(under: Node, pred: Callable) -> Array:
	var out: Array = []
	if under == null:
		return out
	var stack: Array[Node] = [under]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if pred.call(n):
			out.append(n)
	return out


## The authored ground stack, in ALTITUDE order. Sorted by the `altitude` meta
## rather than by name: "Ground10" sorts before "Ground2" alphabetically, which
## would scramble the bands the probe is trying to separate.
func _ground_layers() -> Array:
	var out: Array = _of_type(_node("World"), "TileMapLayer").filter(
			func(n: Node) -> bool: return n.name.begins_with("Ground"))
	out.sort_custom(func(a: Node, b: Node) -> bool:
		return int(a.get_meta("altitude", 0)) < int(b.get_meta("altitude", 0)))
	return out


func _ground_band(from_i: int, to_i: int) -> Array:
	var g: Array = _ground_layers()
	return g.slice(mini(from_i, g.size()), mini(to_i, g.size()))


## Every shadow quad in the world, identified by the shader it runs rather than
## by its node name — see the comment on the "ALL shadows" row for why the name
## is unusable after reparenting.
func _shadow_nodes() -> Array:
	return _collect(_node("World"), func(n: Node) -> bool:
		if not (n is CanvasItem):
			return false
		var m: ShaderMaterial = (n as CanvasItem).material as ShaderMaterial
		if m == null or m.shader == null:
			return false
		return m.shader.resource_path.contains("shadow"))


## Every descendant of `under` with this exact node name.
func _named(under: Node, node_name: String) -> Array:
	return _collect(under, func(n: Node) -> bool: return String(n.name) == node_name)


## Same, but rooted at each of a set of nodes (a group's members).
func _named_under(roots: Array, node_name: String) -> Array:
	var out: Array = []
	for r in roots:
		if r is Node:
			out.append_array(_named(r as Node, node_name))
	return out


func _of_type(under: Node, type_name: String) -> Array:
	return _collect(under, func(n: Node) -> bool: return n.is_class(type_name))


## Matched on the SCRIPT FILE rather than on a group or a class_name: visitors
## deliberately do not join `procedural_object` (ObjectPainter frees that group on
## regenerate, which would free a visitor mid-step), and there is no visitor group
## to ask for.
func _by_script(under: Node, basename: String) -> Array:
	return _collect(under, func(n: Node) -> bool:
		var s: Script = n.get_script() as Script
		return s != null and s.resource_path.get_file().get_basename() == basename)


# ----------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------

func _build_panel() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 250  # above the ballast, so the report is never graded away
	_panel = Label.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_theme_color_override(&"font_color", Palette.at(0))
	_panel.add_theme_color_override(&"font_outline_color", Palette.at(30))
	_panel.add_theme_constant_override(&"outline_size", 4)
	layer.add_child(_panel)
	add_child(layer)


## Every line goes to the browser console AND to the on-screen panel. The console
## is the one to read; the panel exists so a screenshot of the tab is a complete
## result when console access is awkward.
func _say(line: String) -> void:
	print(line)
	_lines.append(line)
	if _panel != null:
		# Progress lines would push the report off screen; keep the tail.
		var tail: Array[String] = _lines.slice(maxi(0, _lines.size() - 44))
		_panel.text = "\n".join(tail)


## Three sinks, in order of how much they need a human:
##   window.__paramo_profile   `copy(window.__paramo_profile)` in the console
##   the on-screen panel       a screenshot is a complete result
##   POST to /__profile        NOBODY NEEDS TO BE WATCHING
##
## The POST is what makes an unattended run possible, and it is deliberately the
## dumbest mechanism that works: the page reports ITSELF to the server that served
## it, so driving the run needs no CDP, no WebSocket, no target discovery and no
## "is it finished yet" polling of the browser. scripts/tools/run_web_profile.py
## opens a URL, waits for a file to appear, and reads it.
##
## Same-origin, so no CORS. A failed POST is swallowed on purpose — someone who
## opened the page by hand has no collector listening, and a red console error
## would look like the profile failed when it did not.
func _flush() -> void:
	if not OS.has_feature("web"):
		return
	var blob: String = "\n".join(_lines)
	var payload: Dictionary = {
		"text": blob,
		"adapter": RenderingServer.get_video_adapter_name(),
		"software_rasterizer": _software_rasterizer(),
		"vsync_floor_ms": _vsync_floor_ms,
		"clock_tick_us": _clock_tick_us,
		"results": _results,
	}
	JavaScriptBridge.eval("window.__paramo_profile = %s;" % JSON.stringify(blob), true)
	JavaScriptBridge.eval("""
		console.log('paramo profile ready: copy(window.__paramo_profile)');
		fetch('/__profile', {method: 'POST', body: %s})
			.catch(function (e) { console.log('no collector listening (fine)'); });
		""" % JSON.stringify(JSON.stringify(payload)), true)
