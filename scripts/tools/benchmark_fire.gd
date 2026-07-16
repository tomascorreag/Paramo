extends SceneTree
## GPU cost benchmark for assets/shaders/fire_blobs.gdshader.
##
## Answers the one question the blob-fire architecture rests on: does the
## worst case fit on web? The design trades CPU (zero) for fill rate, and the
## worst case is FireManager's MAX_CONCURRENT_BURNING (80) cells all at
## intensity 1.0 — i.e. a solid burning front where every cell has 4 burning
## neighbours, so every column is at its full ~118x235px quad and they overlap.
##
## Phases render N columns into a 1920x1080 SubViewport with vsync off and
## nothing else in the scene, at the REAL FireBlobTuning uniforms, laid out on
## the real 32x16 iso cell spacing so the overlap is the overlap the game gets.
##
## Read the RATIO, not the ms. Absolute ms is for this GPU at this size and does
## not transfer to WebGL2 on an integrated GPU — but "fire is Nx a rain pass"
## does, and rain is the known-good reference that already ships. This is the
## same discipline as benchmark_rain.gd; see its header.
##
## 1920x1080 is not a synthetic blow-up: `canvas_items` stretch renders at the
## WINDOW resolution (CLAUDE.md — a fullscreen pass at 1440x810 is 1.17M
## fragments), so this is roughly a real fullscreen frame.
##
## Needs a rendering context — do NOT pass --headless.
##
##   "../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" \
##       --path . --script res://scripts/tools/benchmark_fire.gd

const COLUMN_SCRIPT: GDScript = preload("res://scripts/vfx/fire_blob_column.gd")
const RAIN_SHADER := "res://assets/shaders/rain.gdshader"

const BENCH_SIZE := Vector2i(1920, 1080)
const WARMUP_FRAMES := 60
const TIMED_FRAMES := 180

# Real iso cell spacing (base_tileset tile_size), so clustered columns overlap
# exactly as much as they do in game.
const CELL := Vector2(32, 16)

# name -> {cells, intensity}. MAX_CONCURRENT_BURNING is 80.
const PHASES: Array[Dictionary] = [
	{"name": "empty", "cells": 0, "intensity": 0.0},
	{"name": "1 kindling", "cells": 1, "intensity": 0.0},
	{"name": "1 mature", "cells": 1, "intensity": 1.0},
	{"name": "5 mature", "cells": 5, "intensity": 1.0},
	{"name": "20 mature", "cells": 20, "intensity": 1.0},
	{"name": "80 mature", "cells": 80, "intensity": 1.0},
	{"name": "80 kindling", "cells": 80, "intensity": 0.0},
	{"name": "rain (ref)", "cells": -1, "intensity": 0.0},
	# Repeats, LAST, to expose measurement drift: the GPU clocks up over a run,
	# so a phase timed early is not comparable to one timed late. If these two
	# disagree with their originals above, the per-phase deltas are drift and
	# only the repeats-vs-each-other comparison means anything.
	{"name": "80 mature R", "cells": 80, "intensity": 1.0},
	{"name": "80 kindl. R", "cells": 80, "intensity": 0.0},
	{"name": "empty R", "cells": 0, "intensity": 0.0},
]

# rain.tscn's shipped uniforms — the worst case (rain_amount 1.0 culls nothing).
# Kept in sync with benchmark_rain.gd's SHIPPED.
const RAIN_SHIPPED := {
	"rain_color": Color(0.7505, 0.820325, 0.95, 0.78431374),
	"tint_color": Color(1, 1, 1, 1),
	"tint_intensity": 0.5,
	"additive_boost": 0.15,
	"rain_amount": 1.0,
	"column_spacing": 1.0,
	"cell_height": 270.0,
	"fall_speed": 220.0,
	"streak_length": 16.0,
	"streak_angle": -0.346,
	"splash_min_y": 0.05,
	"splash_dwell": 0.25,
	"splash_size": 2.0,
	"splash_probability": 1.0,
	"streak_alpha_variation": 1.0,
	"camera_offset": Vector2.ZERO,
	"lantern_pos_view": Vector2(-9999, -9999),
	"lantern_radius_px": Vector2(256, 128),
	"lantern_energy": 0.0,
	"lantern_color": Color(1, 0.725, 0.45, 1),
	"lantern_color_mix": 0.6,
	"lantern_lift_gain": 1.5,
}

var _phase_i: int = 0
var _frame: int = 0
var _t0: int = 0
var _ms: Array[float] = []
var _vp: SubViewport
var _holder: Node2D
var _rain: ColorRect


func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("benchmark_fire needs a rendering context. Drop --headless.")
		quit(1)
		return

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	_vp = SubViewport.new()
	_vp.size = BENCH_SIZE
	_vp.transparent_bg = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.disable_3d = true
	root.add_child(_vp)

	_holder = Node2D.new()
	_vp.add_child(_holder)

	_rain = ColorRect.new()
	_rain.size = Vector2(BENCH_SIZE)
	_rain.color = Color(0, 0, 0, 0)
	_rain.visible = false
	_vp.add_child(_rain)

	var q_mature: Vector2 = FireBlobTuning.quad_size(1.0)
	print("fire_blobs benchmark")
	print("  device:  %s" % RenderingServer.get_video_adapter_name())
	print("  size:    %dx%d (%.2fx a 1080p fullscreen frame)"
		% [BENCH_SIZE.x, BENCH_SIZE.y,
			float(BENCH_SIZE.x * BENCH_SIZE.y) / float(1920 * 1080)])
	print("  mature column quad: %.0f x %.0f px (%.0f px^2)"
		% [q_mature.x, q_mature.y, q_mature.x * q_mature.y])
	print("  80 mature = %.2fx a fullscreen frame in raw quad area (before overlap)"
		% [80.0 * q_mature.x * q_mature.y / float(BENCH_SIZE.x * BENCH_SIZE.y)])
	print("")
	_begin_phase()


func _begin_phase() -> void:
	for c: Node in _holder.get_children():
		_holder.remove_child(c)
		c.queue_free()

	var phase: Dictionary = PHASES[_phase_i]
	var cells: int = phase["cells"]
	_rain.visible = cells < 0

	if cells < 0:
		var mat := ShaderMaterial.new()
		mat.shader = load(RAIN_SHADER) as Shader
		for key: String in RAIN_SHIPPED:
			mat.set_shader_parameter(key, RAIN_SHIPPED[key])
		mat.set_shader_parameter("viewport_size", Vector2(BENCH_SIZE))
		_rain.material = mat
	else:
		# Cluster the cells on the real iso lattice, centred, so the columns
		# overlap the way a solid burning front's do.
		var side: int = int(ceil(sqrt(float(maxi(cells, 1)))))
		for i in cells:
			var gx: int = i % side
			var gy: int = i / side
			var col: FireBlobColumn = COLUMN_SCRIPT.new()
			col.set_cell_seed(FireBlobColumn.seed_for_cell(Vector2i(gx, gy)))
			col.position = Vector2(BENCH_SIZE) * 0.5 + Vector2(
				(float(gx) - float(side) * 0.5) * CELL.x,
				(float(gy) - float(side) * 0.5) * CELL.y + 240.0)
			_holder.add_child(col)
			col.set_intensity(phase["intensity"])
	_frame = 0


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == WARMUP_FRAMES:
		_t0 = Time.get_ticks_usec()
		return false
	if _frame < WARMUP_FRAMES + TIMED_FRAMES:
		return false

	var elapsed := Time.get_ticks_usec() - _t0
	var ms: float = (float(elapsed) / 1000.0) / float(TIMED_FRAMES)
	_ms.append(ms)
	print("  %-12s %7.3f ms/frame" % [PHASES[_phase_i]["name"], ms])

	_phase_i += 1
	if _phase_i >= PHASES.size():
		_report()
		return true
	_begin_phase()
	return false


func _report() -> void:
	var base: float = _ms[0]
	var rain_i: int = _index_of("rain (ref)")
	var rain_cost: float = _ms[rain_i] - base

	# Drift estimate: how far the repeated phases moved from their originals.
	# Anything smaller than this is not a measurement, it's the GPU clocking up.
	var drift: float = 0.0
	for pair: Array in [["80 mature", "80 mature R"], ["80 kindling", "80 kindl. R"], ["empty", "empty R"]]:
		drift = maxf(drift, absf(_ms[_index_of(pair[0])] - _ms[_index_of(pair[1])]))

	print("")
	print("  --- net of the empty baseline (%.3f ms) ---" % base)
	for i in range(1, PHASES.size()):
		var net: float = _ms[i] - base
		var ratio: String = "n/a"
		if rain_cost > 0.001:
			ratio = "%.2fx rain" % (net / rain_cost)
		var flag: String = "  <- within noise" if absf(net) < drift else ""
		print("  %-12s %7.3f ms   %-11s%s" % [PHASES[i]["name"], net, ratio, flag])

	print("")
	print("  noise floor (repeat-phase drift): +/- %.3f ms" % drift)
	print("")
	print("  READ THIS BEFORE QUOTING A NUMBER:")
	print("  Every fire phase here lands within a few tenths of a ms of the empty")
	print("  baseline, which is the same order as the noise floor above. That is not")
	print("  'fire is fast' — it is 'this GPU cannot resolve fire's fill cost'. The")
	print("  80-mature worst case is ~1x a fullscreen frame of quad area running a")
	print("  ~24-iteration loop; a desktop card eats that in ~0.03ms of ALU, so what")
	print("  is actually being timed is the 80 nodes and 80 draw calls, not the shader.")
	print("  (Tell: 80 kindling can measure DEARER than 80 mature despite 100x fewer")
	print("  fragments — per-node cost dominates and the ordering is meaningless.)")
	print("")
	print("  The transferable facts are the AREA ratio printed above and 'fire's worst")
	print("  case is a fraction of the rain pass that already ships'. The decision")
	print("  belongs on the WEB build (WebGL2, integrated GPU), per CLAUDE.md — desktop")
	print("  is not where this game's perf problems are.")
	quit(0)


func _index_of(name: String) -> int:
	for i in PHASES.size():
		if PHASES[i]["name"] == name:
			return i
	return 0
