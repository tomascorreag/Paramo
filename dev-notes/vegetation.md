# Vegetation: one value per cell, many ways to lose it

`scripts/systems/regrowth_manager.gd` owns how much grass is on each cell as a
single continuous 0..1 value, and **every damage source writes that same number**.

## Where the state actually lives

- **"Is this cell grassy" is not a field on `CellData`** — it is the ground
  `TileMapLayer`'s atlas **source id** (0 grass, 2 dirt), and always was. The
  ledger stores the value; the layer stores the appearance. `CellData`'s
  health/moisture/biodiversity placeholders are unused and are the **wrong** home
  for this: `TileGrid.build()` reconstructs every `CellData` from the layers, and
  a rebuild happens on every structure placement, so anything written there is lost.
- The 2026-08-09 merge replaced a `_charred` **set** with the value. Two sets
  (char + wear) would mean two ledgers answering one question, an appeal term
  that double-counts a cell in both, a special case to stop it — and a third and
  fourth set when mining and construction land. As one value they are all
  subtractions. `test_regrowth_manager.gd` states it directly: a worn cell that
  then burns is **one** damaged cell.

## Recovery is continuous (2026-08-10), not a midnight pass

It used to run once per completed day, so grass returned in a single step 240
real seconds wide: a scar sat unchanged all day and then jumped.
`RegrowthManager.tick` now sweeps a **slice** of the damaged-cell ledger each
frame, sized so the whole ledger is covered every `sweep_seconds`.

- Each cell integrates its **own** elapsed time against two **monotonic** clocks
  (game-days, and the integral of rain over them), so the authored per-day rate
  is exact however often — or unevenly — a cell is visited. That makes the cadence
  a free parameter and not a balance knob; `test_regrowth_manager.gd` asserts it
  directly (one step vs forty).
- Rain is integrated the same way, so a downpour heals the mountain **while it
  rains** instead of retroactively at midnight.
- A burning cell is skipped but still **stamped**. Skipping without stamping
  would let it bank the time it spent alight and heal retroactively the moment
  the fire went out — worse than what it replaced, and invisible except as fires
  that leave no scar.
- **Cost, and it is a real trade.** Per frame it is nothing (1.4 → 6.9 µs at 170
  cells, and the 0.4-0.7 ms midnight spike is gone). The **simulator** pays: it
  models 5760 real seconds per run and now sweeps every 4 of them instead of 24
  times total — 12.8 → 8.1 runs/min at `sweep_seconds` 4.0, and 4.1 at 1.0. 4.0
  is the shipped compromise: a cell's paint flip lands within 4 s of its ideal
  moment, which no player can see.
- **It moved the balance**, 12 paired seeds vs the daily model: `tokens_final`
  −3.25 (t=−2.1), `visitors_walked` −1.92 (t=−2.5), `charred_cell_days` +508
  (t=2.0); `grass_frac_end` +0.04 and `charred_end` −13 are noise. At
  `sweep_seconds` 1.0 every one roughly doubles (tokens −5.75, t=−3.3) — **the
  shift scales with the cadence**, which is the tell that it comes from threshold
  *timing*, not from the amount recovered: a cell crosses `regrow_threshold` as
  soon as it earns it rather than at the next midnight, so it is grass (and
  ignitable again) sooner. That mechanism is a hypothesis consistent with the
  numbers, not proven by these runs; a `--per-day` trace would settle it.
  `base_recovery_per_day` is the knob if token parity matters.

## Grass LENGTH follows the value (2026-08-11)

Appearance is no longer one grass tile swapped for dirt. Above `bare_threshold`
the cell is grass and its **length** tracks the value: the atlas paints the same
cube at several lengths per tone, `GrassLadder`
(`scripts/systems/grass_ladder.gd`) orders them, and the grass span is cut into
one band per rung.

- **The ceiling is what generation chose.** `TerrainPainter`'s variant resolver
  already picks a variant per cell weighted by altitude, clumping and selection
  weight; that pick is captured in `_begin_tracking` — at the one moment the cell
  is known undamaged — and grass never grows past it. Reading the ceiling off the
  *currently painted* coord instead would ratchet a cell shorter every time it
  was re-tracked.
- **Tone is a hard partition, not a nearest-match.** Tiles group by
  `(tile_kind, grass_tone)`, so a cool cell can only ever wear cool art. There is
  no blending or fallback across tones — the failure it prevents (a cell changing
  species as it wears) looks deliberate, because both tones ship.
- **It is authored, not coded.** Two custom_data layers on `base_tileset.tres`:
  `grass_tone` (>= 1, names a species) and `grass_length` (>= 1, ascending).
  Both default to 0 = "not laddered", so every slope, wall and stair opts out by
  doing nothing and behaves exactly as before — one rung, dirt swap only.
  `GrassLadder` names no coordinate; adding a length step or a third tone is a
  pure `.tres` edit.
- **Two tiles were added to the atlas** (`0:8` / `1:8`, art that was already on
  the sheet and never painted in) as each green ladder's bottom rung. They carry
  `selection_weight = -1`, i.e. degradation-only: generation must never place
  them, or the mountain generates already looking worn and the wear the player
  causes stops reading as something they did. `preview_grass_wear.gd`'s census
  asserts this every run.
- **`grass_step_hysteresis` (0.03)** is `bare_threshold`/`regrow_threshold`'s
  deadband, one scale down and applied against the direction of travel. Without
  it a cell parked on a rung boundary — a lightly used route, worn a little and
  healed a little each day — re-cuts its tile on every sweep.
- **Balance is untouched.** Every rung is still `SOURCE_GRASS`, so
  `FireManager.can_ignite`, the bare/appeal bookkeeping and the firebreak
  behaviour all read exactly what they read before. `roughness` differs per rung
  and feeds only the shadow shader, not movement cost.
- **The tall pale paja (`0:10`) is the WARM ladder's top rung**, not a species of
  its own — the same grass left to grow out. It is the only rung whose tile is
  1x3 rather than 1x2, so stepping off it drops the skyline by half a cell, which
  is the most legible step in the whole ramp. It is also the single most common
  grass on a level1 map (~280 of ~660 grass cells), so putting it on the ladder
  is what gives the feature its coverage: as its own species it would have been a
  third of the mountain still snapping straight to dirt.
- **MEASURED, level1**: generation spreads warm grass over rungs 1-5
  (74/3/68/117/288 cells) but cool over **only rungs 1-2** (117/94) — `1:2` and
  `1:4` are authored `selection_weight = -1` and predate this work. So cool cells
  have at most three visible lengths against warm's six. That is a variant-weight
  fact, not a wear fact, and it is the first thing to check when a ramp looks
  flat. Flipping those two weights positive is a one-line `.tres` change.

Look at it with `scripts/tools/preview_grass_wear.gd` — it lays a 1.0 → 0.18 wear
ramp across a real run of cells and saves a before/after pair, plus the
per-cell table (tone, ceiling, value, rung, painted coord) a still cannot carry.
Needs a rendering context.

```bash
... --script res://scripts/tools/preview_grass_wear.gd -- --out /tmp/grass
... --script res://scripts/tools/preview_grass_wear.gd -- --out /tmp/grass --len 14 --scene res://scenes/maps/level1.tscn
```

## Rate model and thresholds

- The per-day **rate** model (not a per-day coin flip) is what lets a scar climb
  back gradually. The old Bernoulli roll also made scars heal **patchily**; with a
  rate, every cell burned on one day heals on one day and the scar vanishes as a
  block. That is why each cell draws its own recovery **multiplier** once, at
  damage time (`recovery_rate_spread`) — patchy again, and stable per cell rather
  than re-rolled every morning.
- **Appearance is a threshold, and there are deliberately two**
  (`bare_threshold` 0.15, `regrow_threshold` 0.55). A single threshold makes a
  cell that is walked daily and heals daily flip appearance **every day**. The gap
  also models the real thing: a path stays bare a while after the walking stops
  and re-bares quickly when it resumes.
- **A trampled cell cannot burn, for free:** `FireManager.can_ignite` requires the
  layer to read grass, so a worn path is a firebreak. Nothing was written to make
  that happen.
- Fire's fuel does **not** yet read the value; `_fuel_for_cell` is the seam.
  Wiring it changes fire balance and belongs in its own change.
- `bare_count` / `vegetation_deficit` are **incremental**, not summed on demand:
  the sim samples both once per tick (~23k times a run) against a ledger of
  several hundred cells, and summing there measured as about a third of the run's
  wall clock. Every write goes through `_set_veg`/`_set_bare`/`_erase`, and a test
  recounts from scratch to catch drift.

## Trampling

`Visitor._on_step_started` reports each cell it steps onto to
`RegrowthManager.trample` — the only damage source besides fire. **Nothing routes
toward worn ground** (deliberate: the pathfinder is untouched), so tracks appear
where routes genuinely overlap: a dark apron at the trailhead funnel and around
popular goals, diffuse in between. Turning wear into a routing discount would
sharpen them into single-file desire paths; that is one term in the step cost,
and the wear value is already readable (`RegrowthManager.vegetation_at`).

The balance simulator walks **real** visitors (`VisitorSpawner` is in
`sim_runner`'s `_SYSTEM_DEFS`), so trampling is measured rather than guessed. Use
`no_trample` (`trample_per_step` 0) against `defaults` on the same `--seed0`
range to isolate it; `no_visitors` is the other end. Visitors cost the sim ~25%
throughput (6.3 → 4.8 runs/min at 12 seeds).

**Compare the arms seed by seed.** Both arms run the same `--seed0` range, so
every metric is **paired** and the fire variance that swallows everything cancels.
Unpaired, the real firebreak effect below reads as t=1.7 (nothing); paired it is
t=8.4.

- At `trample_per_step` 0.06, 12 seeds: trampling cost ~3 tokens a run via appeal
  and had **no** detectable effect on the ground (`grass_frac_end` 0.59 vs 0.60).
  ~53 visitors wearing 0.06 a step is small next to ~550 charred cells. The
  arithmetic against `base_recovery_per_day`: a cell heals 0.15-0.65 a day, so at
  0.06 it needed 3+ crossings **every day** just to break even.
- At `trample_per_step` 0.18 (`base_visitors_per_day` 6), 12 paired seeds, and the
  **sign is the surprise**: trampling makes the mountain **healthier**.
  `fires_ignited` −374 (t=−8.4, lower in 12/12 seeds), `charred_end` −98 (t=−2.2),
  `grass_frac_min` +0.03 (t=+2.2); tokens flat (+0.8, t=0.5). The firebreak
  mechanism is real and free — it was just too small to measure at 0.06.
  Trampling is therefore **not** currently a cost the player answers; at this rate
  it is fire mitigation. Read that as a statement about **fire** being overtuned
  (~1800-2200 ignitions a run) rather than about feet: any mechanism that removes
  fuel wins while fire dominates. **Fix fire before tuning trample against it.**
- A 4-seed A/B at 0.06 also said trampling improved grass, and that one was noise
  (`no_trample`'s grass sd is 0.14, one seed at 0.97). Same sign, different
  reason — do not treat the 0.18 result as confirming it.

The merge moved the sim's numbers (2026-08-09 re-baseline): appeal now gives
partial credit for partly-regrown ground where the old model counted a cell fully
non-natural until fully back, so appeal recovers sooner. **Old CSVs are not
comparable across that line.**
