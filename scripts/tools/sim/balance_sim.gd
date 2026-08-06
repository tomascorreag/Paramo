@tool
extends SceneTree

# ============================================================================
# balance_sim.gd — headless Monte Carlo balance simulator (CLI entry point).
# ============================================================================
#
# Runs N complete, deterministic game runs against the real simulation stack
# (SimWorld + SimRunner — the same advance/tick/sim_tick functions a game
# frame calls) and writes CSV for external analysis (pandas). Column docs
# live in sim_runner.gd's header; scenarios in sim_scenarios.gd.
#
#   # 100 runs of the default balance, CSVs into sim_out/:
#   Godot --path . --headless --script res://scripts/tools/sim/balance_sim.gd -- --runs 100
#   # a scenario, custom seed range, per-day rows too:
#   ... -- --runs 500 --seed0 1000 --scenario fast_regrowth --per-day --out sim_out/fast
#   # paint parity check (SimWorld vs the game's ProceduralWorld path):
#   ... -- --verify-paint
#
# Sharding: runs are seeded seed0..seed0+runs-1, so several OS processes with
# disjoint --seed0 ranges are embarrassingly parallel; concat the CSVs.
#
# Two hard-won structural rules (see the tool-script-autoload-timing memory):
#  - ALL work happens in _process (first call), never _init — autoload global
#    identifiers aren't registered with the GDScript compiler during SceneTree
#    construction, so load() of any system script would fail there.
#  - Scripts that reference autoload identifiers at compile time (SimRunner,
#    SimWeatherHost, the system scripts) are load()ed at runtime, NEVER named
#    as compile-time identifiers here.
# ============================================================================

const PARITY_SCENE: String = "res://scenes/maps/procedural_test.tscn"
const DEFAULT_OUT: String = "sim_out"

const _AUTOLOADS: Array = [
	["DisplayManager", "res://scripts/systems/display_manager.gd"],
	["TimeManager", "res://scripts/systems/time_manager.gd"],
	["Debug", "res://scripts/systems/debug.gd"],
	["FireManager", "res://scripts/systems/fire_manager.gd"],
	["ResourceLedger", "res://scripts/systems/resource_ledger.gd"],
	["SeasonManager", "res://scripts/systems/season_manager.gd"],
]

var _ran: bool = false


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	var code: int = _run()
	quit(code)
	return true


func _run() -> int:
	var runs: int = 10
	var seed0: int = 1
	var scenario_name: String = "defaults"
	var out_dir: String = DEFAULT_OUT
	var per_day: bool = false
	var quiet: bool = false
	var verify_paint: bool = false
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var i: int = 0
	while i < args.size():
		match args[i]:
			"--runs", "--seeds":
				i += 1
				runs = maxi(1, int(args[i]))
			"--seed0":
				i += 1
				seed0 = int(args[i])
			"--scenario":
				i += 1
				scenario_name = args[i]
			"--out":
				i += 1
				out_dir = args[i]
			"--per-day":
				per_day = true
			"--quiet":
				quiet = true
			"--verify-paint":
				verify_paint = true
			_:
				push_warning("balance_sim: unknown arg '%s'" % args[i])
		i += 1

	_install_autoloads()

	if verify_paint:
		return _verify_paint(mini(runs, 3))

	if not SimScenarios.SCENARIOS.has(scenario_name):
		push_error("balance_sim: unknown scenario '%s'. Known: %s"
				% [scenario_name, SimScenarios.SCENARIOS.keys()])
		return 1
	var scenario: Dictionary = SimScenarios.get_scenario(scenario_name)

	var world: SimWorld = SimWorld.new()
	world.name = "SimWorld"
	root.add_child(world)
	var runner: Node = Node.new()
	runner.set_script(load("res://scripts/tools/sim/sim_runner.gd"))
	runner.name = "SimRunner"
	root.add_child(runner)
	runner.set(&"world", world)

	var run_columns: PackedStringArray = runner.get(&"RUN_COLUMNS")
	var day_columns: PackedStringArray = runner.get(&"DAY_COLUMNS")
	var run_rows: Array = []
	var day_rows: Array = []
	var t_all: int = Time.get_ticks_usec()

	for r in runs:
		var run_seed: int = seed0 + r
		var t0: int = Time.get_ticks_usec()
		var result: Dictionary = runner.call(&"run_one", run_seed, scenario, per_day)
		var ms: float = (Time.get_ticks_usec() - t0) / 1000.0
		var row: Dictionary = result["run"]
		row["sim_ms"] = "%.0f" % ms
		run_rows.append(row)
		day_rows.append_array(result["days"])
		if not quiet:
			print("seed %d: days=%d grass_end=%.2f tokens=%.0f charred=%d  (%.0f ms)" % [
					run_seed, int(row["days"]), float(row["grass_frac_end"]),
					float(row["tokens_final"]), int(row["charred_end"]), ms])

	var total_s: float = (Time.get_ticks_usec() - t_all) / 1_000_000.0

	# --- CSV out -------------------------------------------------------------
	var out_abs: String = _resolve_out_dir(out_dir)
	var err: int = DirAccess.make_dir_recursive_absolute(out_abs)
	if err != OK and err != ERR_ALREADY_EXISTS:
		push_error("balance_sim: cannot create out dir %s (err %d)" % [out_abs, err])
		return 1
	var columns_with_ms: PackedStringArray = run_columns.duplicate()
	columns_with_ms.append("sim_ms")
	_write_csv(out_abs.path_join("runs.csv"), columns_with_ms, run_rows)
	if per_day:
		_write_csv(out_abs.path_join("days.csv"), day_columns, day_rows)

	_print_summary(scenario_name, run_rows, total_s, out_abs, per_day)
	return 0


# --- summary -----------------------------------------------------------------

func _print_summary(scenario_name: String, rows: Array, total_s: float,
		out_abs: String, per_day: bool) -> void:
	print("")
	print("=== %s: %d run(s) in %.1f s (%.1f runs/min) ===" % [
			scenario_name, rows.size(), total_s,
			60.0 * rows.size() / maxf(total_s, 0.001)])
	for col in ["grass_frac_end", "grass_frac_min", "appeal_min", "rain_frac",
			"dryness_mean", "tokens_final", "water_final", "charred_end",
			"fires_ignited", "peak_fires"]:
		var vals: Array = []
		for row: Dictionary in rows:
			vals.append(float(row[col]))
		print("  %-16s mean %8.2f  sd %7.2f  min %8.2f  max %8.2f" % [
				col, _mean(vals), _sd(vals), vals.min(), vals.max()])
	print("csv: %s" % out_abs.path_join("runs.csv"))
	if per_day:
		print("csv: %s" % out_abs.path_join("days.csv"))


static func _mean(vals: Array) -> float:
	var s: float = 0.0
	for v in vals:
		s += v
	return s / maxi(vals.size(), 1)


static func _sd(vals: Array) -> float:
	if vals.size() < 2:
		return 0.0
	var m: float = _mean(vals)
	var acc: float = 0.0
	for v in vals:
		acc += (v - m) * (v - m)
	return sqrt(acc / (vals.size() - 1))


# --- CSV ---------------------------------------------------------------------

func _resolve_out_dir(out_dir: String) -> String:
	if out_dir.is_absolute_path() or out_dir.begins_with("user://"):
		return ProjectSettings.globalize_path(out_dir)
	return ProjectSettings.globalize_path("res://").path_join(out_dir)


func _write_csv(path: String, columns: PackedStringArray, rows: Array) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("balance_sim: cannot write %s (err %d)"
				% [path, FileAccess.get_open_error()])
		return
	f.store_line(",".join(columns))
	for row: Dictionary in rows:
		var cells: PackedStringArray = []
		for col in columns:
			cells.append(str(row.get(col, "")))
		f.store_line(",".join(cells))
	f.close()


# --- paint parity: SimWorld vs the game's ProceduralWorld path ---------------

func _verify_paint(seeds: int) -> int:
	var packed: PackedScene = load(PARITY_SCENE)
	if packed == null:
		push_error("balance_sim: cannot load %s" % PARITY_SCENE)
		return 1
	var scene_root: Node = packed.instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
	var pw: Node = _find_by_script(scene_root, "procedural_world.gd")
	if pw == null:
		push_error("balance_sim: no ProceduralWorld in %s" % PARITY_SCENE)
		scene_root.free()
		return 1

	var world: SimWorld = SimWorld.new()
	world.name = "SimWorldParity"
	root.add_child(world)

	var failures: int = 0
	for s in seeds:
		var run_seed: int = 1000 + s
		pw.set(&"seed_override", run_seed)
		pw.call(&"regenerate")
		var params: TerrainGenerationParams = pw.call(&"_resolve_params")
		var game_census: Dictionary = _census_of(
				pw.get(&"ground_layers"), params.width, params.height)

		world.regenerate(params)
		var sim_census: Dictionary = world.cell_census()

		if sim_census == game_census:
			print("seed %d: paint parity OK %s" % [run_seed, sim_census])
		else:
			failures += 1
			print("seed %d: PARITY MISMATCH\n  game: %s\n  sim:  %s" % [
					run_seed, game_census, sim_census])

	scene_root.free()
	print("--- paint parity: %s ---" % ("PASS" if failures == 0 else "FAIL"))
	return 0 if failures == 0 else 1


func _census_of(layers: Array, w: int, h: int) -> Dictionary:
	var out: Dictionary = {}
	var bounds := Rect2i(0, 0, w, h)
	for l in layers:
		if l == null:
			continue
		for cell: Vector2i in (l as TileMapLayer).get_used_cells():
			if not bounds.has_point(cell):
				continue
			var src: int = (l as TileMapLayer).get_cell_source_id(cell)
			out[src] = int(out.get(src, 0)) + 1
	return out


func _find_by_script(node: Node, script_name: String) -> Node:
	var scr := node.get_script() as Script
	if scr != null and scr.resource_path.ends_with(script_name):
		return node
	for child in node.get_children():
		var found := _find_by_script(child, script_name)
		if found != null:
			return found
	return null


func _install_autoloads() -> void:
	for entry in _AUTOLOADS:
		if root.has_node(NodePath(entry[0])):
			continue
		var scr := load(entry[1]) as Script
		if scr == null:
			push_error("balance_sim: missing autoload script %s" % entry[1])
			continue
		var node := Node.new()
		node.set_script(scr)
		node.name = entry[0]
		root.add_child(node)
