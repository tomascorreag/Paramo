# Monte Carlo balance simulator — `scripts/tools/sim/balance_sim.gd`

Runs N complete, **deterministic** headless game runs: real terrain + painted
layers (cell-for-cell parity with `ProceduralWorld`, checked by `--verify-paint`),
real Pathfinder/FireManager/weather/economy driven through the same
`advance`/`tick`/`sim_tick` functions a game frame calls, plus a scripted player
bot (walks to fires at the player's real step durations, douses at 1 water/cell in
ring order, buys unlocks and places ladders/frailejones in planning).

Writes `runs.csv` (+ `days.csv` with `--per-day`) for pandas; column docs in
`sim_runner.gd`'s header, scenarios + bot configs in `sim_scenarios.gd`.

**Run this after any balance change** (fire rates, weather profiles, economy
constants) — it is the cheapest way to see season-by-season consequences.

```bash
G="../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe"
$G --path . --headless --script res://scripts/tools/sim/balance_sim.gd -- --runs 100
$G --path . --headless --script res://scripts/tools/sim/balance_sim.gd -- --runs 500 --seed0 1000 --scenario no_bot --per-day --out sim_out/no_bot
$G --path . --headless --script res://scripts/tools/sim/balance_sim.gd -- --verify-paint
```

Ecosystem health is a **continuum** by design: no loss rule exists in game or
sim. Read `grass_frac` / appeal / token trajectories, not a survival flag.

## Notes that save re-discovery

- Runs are seeded `seed0..seed0+runs-1`: shard sweeps across OS processes with
  disjoint `--seed0` ranges and concat the CSVs.
- Same (seed, scenario) ⇒ byte-identical rows (guarded by
  `tests/test_sim_determinism.gd`). Every stochastic system draws from its own
  injected `RandomNumberGenerator` (weather/fire/regrowth/bot, xor-derived from
  the run seed); VFX stays on the global stream and cannot perturb outcomes — in
  the game either, since the same refactor shipped there.
- The sim models `time_scale = 1` (normal play). The game's M-key fast-forward
  makes fire/economy run 60x faster than player movement — a different regime.
- Throughput at the current (overtuned) fire balance is ~8 runs/min with the bot,
  because ~100 concurrent fires dominate; it rises as fire is retuned. The
  continuous-regrowth change costs some of it (see [vegetation.md](vegetation.md)).
- `benchmark_sim_world.gd` times the per-phase costs if perf regresses.

## Reading results

- **Compare the arms seed by seed.** Both arms run the same `--seed0` range, so
  every metric is **paired** and the fire variance that swallows everything
  cancels. Unpaired, a real effect measured t=1.7 (nothing); paired it was t=8.4.
- **Anything downstream of fire needs 12+ paired seeds.** At 8 seeds the same
  comparison handed back a significant-looking result with a plausible mechanism
  attached, and it was noise.
- **Do not price code changes off the sim's wall clock.** The same arm varied 12%
  between slots on one machine; arms run sequentially, so drift maps entirely onto
  the arm and `sim_ms` looks paired when it is not. Use the interleaved
  benchmarks in [performance.md](performance.md).
