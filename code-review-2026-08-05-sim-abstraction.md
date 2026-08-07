# Code Review - 2026-08-05

Scope: the headless Monte Carlo balance simulator (`scripts/tools/sim/*`) and the
shared-logic extraction it drove into the game systems. Review mandate: optimized
for both game and simulator, game takes priority. Reviewer: critical-code-architect
agent; the two critical findings were then **empirically confirmed** (see C-verify
below).

## Files Reviewed
- `scripts/tools/sim/balance_sim.gd`, `sim_runner.gd`, `sim_world.gd`,
  `sim_weather_host.gd`, `sim_bot.gd`, `bot_policy.gd`, `sim_scenarios.gd`,
  `benchmark_sim_world.gd`
- `scripts/systems/weather_model.gd`, `day_night_scene_controller.gd`,
  `fire_manager.gd`, `regrowth_manager.gd`, `time_manager.gd`,
  `climate_controller.gd`, `water_cycle.gd`, `visitor_flow.gd`, `tile_grid.gd`,
  `pathfinder.gd`, `object_painter.gd`, `actions/action_extinguish_fire.gd`
- `scripts/player.gd`, `scripts/tools/procedural_world.gd`
- Tests: `test_weather_model.gd`, `test_sim_determinism.gd`, `test_sim_bot.gd`,
  `test_step_duration.gd`, `test_fire_manager.gd`

## Outcome (2026-08-06)
All findings applied except I4 (deliberately skipped: pre-existing allocation
churn already gated behind an is_empty() early-return; a lazy-alloc adds
per-cell branches in the burn loop and desktop cannot measure the difference —
revisit on the web build if it ever shows). Verification: 534/534 GUT tests
(one new position-independence test), seed-3 row byte-identical between shard
positions, cell-for-cell paint parity PASS on 3 seeds (2,343+ stacked-layer
entries per seed), terrain invariants 460 grids clean, level1 median 2.5 ms.

## Summary
- Critical: 2 issues (both **confirmed by experiment** — the determinism contract
  is currently broken for `--seed0` sharding)
- Warning: 4 issues
- Medium: 6 issues
- Info: 7 notes

Overall shape assessment: the extract-the-model/adapter split is sound and the
game pays essentially nothing for it (one call-frame of indirection per system, no
new allocation or group lookups in hot paths, `_SYSTEM_DEFS` order matches
`gameplay_base.tscn` exactly). The failures cluster in the reuse-across-runs seams.

### C-verify (empirical confirmation)
`--runs 3 --seed0 1` vs `--runs 1 --seed0 3`: seed 3's row **differs by shard
position** — water_final 13.82 vs 17.82, douses 416 vs 370, grass_end 0.656 vs
0.694, ignitions 2313 vs 2333. Same seed, same scenario, different outcome ⇒
run outcome depends on position in the process. Sharded sweeps are currently
invalid. No `set_occupant ... already occupied` warnings appeared, consistent
with C2's *silent* variant (stale claims relocating new rocks rather than
colliding).

## Critical Issues

### [C1] `TimeManager._current_period` survives run reset — first run gets an extra weather roll
- **File:** `scripts/systems/time_manager.gd:106` area / `scripts/systems/season_manager.gd:106-108`
- **Description:** `season_manager` resets `day_count` and `time_of_day` but not
  `_current_period`. Fresh process: `_current_period = NOON` (evaluated at boot
  time_of_day 0.5). Run 1's first `advance(0.25)` puts time_of_day in NIGHT →
  period change → `period_changed` emits → `SimWeatherHost` rolls weather →
  **one rng draw consumed** (possibly starting rain). Runs 2..N inherit
  `_current_period = NIGHT` from the previous run's end, so no emit, no roll.
  Seed S as run #1 ≠ seed S as run #5. Also a (mild) game bug: restarting a run
  mid-afternoon fires a spurious period roll on the first frame.
  `test_sim_determinism.gd` passes only because both of its `run_one` calls
  happen after suite state already left the period at NIGHT — a latent flake.
- **Suggested Fix:** shared-layer reset that re-evaluates without emitting:
```gdscript
# time_manager.gd
func reset_clock() -> void:
	time_of_day = 0.0
	day_count = 0
	_current_period = _evaluate_period(time_of_day)
```
  `season_manager.gd` calls `TimeManager.reset_clock()` instead of the two-field
  poke. Strengthen `test_sim_determinism.gd`: run seed S first-in-process and
  again after unrelated runs, assert equality.

### [C2] `SimWorld.regenerate` rebuilds the Pathfinder while the previous run's occupants are still alive — they re-claim cells on the new grid
- **File:** `scripts/tools/sim/sim_world.gd:77-95`, `scripts/objects/rock.gd:109-124`, `scripts/tools/frailejon.gd:115-123`
- **Description:** `pathfinder.rebuild()` (line 87) emits `graph_changed` before
  `ObjectPainter.paint` (line 95) queue-frees last run's rocks. At that moment
  the old rocks are alive and NOT yet queued, so their `graph_changed` handlers
  `set_occupant` on the **new** grid. Inside the single-frame sim loop
  `queue_free` never flushes, so those stale claims persist: cells are
  unwalkable for the bot, and new rocks either collide (refused with a warning,
  spawning claim-less) or are silently displaced by the painter — either way the
  layout differs from a first-run process. Second position-in-process leak;
  confirmed contributor to the C-verify divergence. `frailejon.gd`'s handler
  also lacks the `is_queued_for_deletion()` guard `rock.gd:117` has — a real
  game bug (`remove_frailejon` + same-frame rebuild → dying plant re-claims its
  cell).
- **Suggested Fix:** free synchronously before the rebuild:
```gdscript
# sim_world.gd, top of regenerate()
for child: Node in object_parent.get_children():
	object_parent.remove_child(child)
	child.free()
```
  Plus the missing guard in `frailejon.gd::_on_graph_changed`:
```gdscript
if not is_inside_tree() or is_queued_for_deletion():
	return
```
  This also makes `SimRunner`'s end-of-run occupant sweep redundant for
  procedural objects and halves the rock memory high-water mark.

## Warnings

### [W1] `SimRunner` disables autoload processing and never restores it
- **File:** `scripts/tools/sim/sim_runner.gd:162-164` (setup) vs `:326-342` (cleanup)
- **Description:** `FireManager.set_process(false)` / `TimeManager.set_process(false)`
  are not undone in cleanup (unlike the `autoload_restore` list). Harmless for
  the CLI (process exits); under GUT every test running after a `SimRunner` run
  gets a frozen TimeManager/FireManager.
- **Suggested Fix:** snapshot `is_processing()` per autoload at setup, restore in
  cleanup alongside the balance overrides.

### [W2] Paint parity compares source-id histograms — blind to variant/placement differences
- **File:** `scripts/tools/sim/balance_sim.gd:251-262`, `sim_world.gd:103-112`
- **Description:** Both sides reduce the map to `{source_id: count}`. Two paints
  placing different tiles at different cells pass if per-source totals match.
  The claim being guarded is cell-for-cell parity; the check can't see C2's
  corruption either. Also `SimWorld` hard-codes the layer stack
  (`GROUND_TOP_ALTITUDE`/`CLIFF_ALTITUDES`) that mirrors `procedural_base.tscn`;
  a scene change silently truncates the comparison.
- **Suggested Fix:** compare a `cell -> [altitude, source_id, atlas_coord]`
  dictionary; assert layer-count equality between the two stacks.

### [W3] `SimWeatherHost` and `DayNightSceneController` have already drifted on the frozen-clock gate
- **File:** `scripts/systems/day_night_scene_controller.gd:344-358` vs `scripts/tools/sim/sim_weather_host.gd:45-46`
- **Description:** Game: `seconds_per_game_day <= 0` skips only game-time
  advancement, still runs `evolve_real` (ramps are real-time). Sim: returns
  entirely. Latent (sim never enters that state today) but it is exactly the
  duplication the extraction exists to remove. Related latent game bug:
  controller returns on `_rain_layer == null` **before** advancing the model, so
  on a rain-layer-less map a rolled rain event wedges in RAMPING_UP forever with
  no diagnostic.
- **Suggested Fix:** `WeatherModel.evolve_gated(profile, delta_real, game_day_delta)`
  holding the gate once; both hosts call it. Move the `_rain_layer` null check to
  guard only `_push_rain_to_shader()`, not the model step.

### [W4] Eight private-member reach-ins couple sim + tests to `FireManager` internals
- **File:** `sim_runner.gd:169-172,248,288,328`, `sim_bot.gd:85`, `tests/test_sim_determinism.gd:51-53`, `tests/test_sim_bot.gd:22-31,63-66`
- **Description:** `_wipe_all_fires`, `_pathfinder`, `_attach_to_pathfinder`,
  `_refresh_grid_and_vfx`, `_ignition_accum`, `_burning`, `_grid`,
  `_complete_burn` used from three consumers. Any internal rename silently
  breaks the sim and two test files.
- **Suggested Fix:** small public headless API on FireManager:
  `reset_to_world(pf)` (sync attach + wipe + refresh + accum reset),
  `detach_world()`, `burning_count()`, `burning_view()` (documented
  by-reference read-only — keeps the bot's zero-copy poll).

## Medium

### [M1] Undeclared bot-vs-player divergence in approach selection
- **File:** `scripts/tools/sim/sim_bot.gd:117-131`
- **Description:** Bot picks the stand by Manhattan distance then runs one A*;
  the game's `_best_approach_path` A*s every reachable stand and takes the
  shortest actual path. Around cliffs/water the bot over-pays travel time.
  Defensible perf trade, but the `sim_runner.gd` limitations header (whose rule
  is "limitations are declared") doesn't list it.
- **Suggested Fix:** add to the limitations list (or A* the 2-3 nearest stands).

### [M2] Per-tick dynamic dispatch in the sim hot loop where static typing is available
- **File:** `scripts/tools/sim/sim_runner.gd:232-250`
- **Description:** ~8 `call(&"...")`/`get(&"...")` lookups per tick x 23k ticks/run.
  `sim_runner.gd` is `load()`ed at runtime and already names autoload classes at
  compile time, so typed locals are legal.
- **Suggested Fix:** pull typed references (`var host: SimWeatherHost = ...` etc.)
  once per run; keep `_SYSTEM_DEFS` for construction order/override targeting.

### [M3] `TICKS_PER_DAY` hard-codes the clock a scenario can retune
- **File:** `scripts/tools/sim/sim_runner.gd:57,216`
- **Description:** 960 assumes 240 s/day / 0.25. `TimeManager` is reachable as a
  balance-override target; a scenario changing `seconds_per_game_day` gets a
  wrong tick cap silently.
- **Suggested Fix:** derive from `TimeManager.seconds_per_game_day / DT` at run
  start.

### [M4] `OBJECT_SEED_XOR` authored in three places
- **File:** `sim_world.gd:27`, `procedural_world.gd:371`, `verify_terrain_invariants.gd`
- **Suggested Fix:** `const OBJECT_SEED_XOR := 0xC8FAB0CC` on `ObjectPainter`;
  all three reference it.

### [M5] `benchmark_sim_world.gd` seeded object pass is dead code and the timing lies
- **File:** `scripts/tools/sim/benchmark_sim_world.gd:148-151`
- **Description:** `assign_object_kinds(grid, obj_rng)` is immediately overwritten
  by `paint(grid, world, pathfinder)` (no rng → fresh randomized rng reassigns);
  the phase double-pays assignment and `object_counts` samples mid-flush.
- **Suggested Fix:** pass `obj_rng` to `paint`, delete the redundant call, sample
  counts grid-side.

### [M6] `FireManager._process` computes rain before the gates that discard it
- **File:** `scripts/systems/fire_manager.gd:307-308`
- **Description:** `_rain_intensity()` (instance-valid + has_method + dynamic
  call) is paid every frame on the title screen and through pause/planning,
  where `sim_tick` discards it two lines later. The only game-side cost the
  abstraction added.
- **Suggested Fix:** check `_grid == null` and the paused gate in `_process`
  before evaluating rain (sim_tick keeps its own gates).

## Info / Suggestions

- [I1] `sim_bot.gd:7` header says "Placements land in v2" but `_try_place`
  implements them — stale load-bearing doc.
- [I2] `sim_runner.gd:196` — spawn cell `(-1,-1)` makes the bot silently inert;
  push_warning + record in the row.
- [I3] Fire consumes pre-tick rain (correct) but `rain_frac`/`day_rain_sum`
  sample post-tick — one-tick skew; document in the column docs.
- [I4] `fire_manager.gd:344-348` — `_advance_burns` allocates two arrays + a
  keys() snapshot per frame/tick even when idle. Pre-existing; lazy-allocate if
  it ever shows.
- [I5] `balance_sim.gd:211-248` — `_verify_paint` instantiates the scene without
  adding it to the tree (deliberate: no `_ready` side effects) — deserves a
  comment; also leaks the parity node and never restores `pw.seed_override`.
- [I6] The game's boot-time rain roll (`day_night_scene_controller.gd:162-170`)
  has no sim analogue — correct (title screen calls `reset_weather_dry`), worth
  a line in the limitations header so nobody "fixes" it.
- [I7] `sim_scenarios.gd:52` — unknown scenario name silently returns
  `{"name": name}`; `push_error` inside `get_scenario`.

## What's Done Well (reviewer's assessment)
- WeatherModel is genuinely pure; the two-clock split documented at the point of
  confusion; tests pin the subtle invariants (state_game_t reset rules, INF
  boot, climate scale on START roll only).
- Per-subsystem xor-derived RNG + VFX on the global stream is the right
  determinism architecture.
- `step_duration_for` / `footprint_by_ring` are the right extraction
  granularity.
- Construction order verified against `gameplay_base.tscn` — signal dispatch
  order genuinely matches the game.
- No game-side cost accepted to help the sim beyond M6's micro-issue.
