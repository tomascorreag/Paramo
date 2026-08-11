# Performance: profilers, benchmarks, and what they found

`...` = `"../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" --path .`
All of these need a rendering context — **do NOT pass `--headless`** (draw calls
silently read 0 under it).

**Desktop is not where this game's perf problems are.** An RTX 3080 at a 1440x810
window sits at ~4.4 ms/frame with ~500 draw calls on level1, and cannot resolve
this project's canvas fill at all — every "is X expensive" fill question must be
answered on the [web build](#the-web-build--scriptstoolsprofile_webgd).

## Pick a tool

| Question | Tool |
|---|---|
| Whole-frame cost of a scene | `profile_scene.gd` |
| Which system costs what on a **loaded** map | `profile_systems.gd` |
| Which single frame stutters | `profile_day_boundary.gd` |
| Where the **web** frame goes | `profile_web.gd` + `run_web_profile.py` |
| Is routing the cost | `benchmark_pathfinder.gd` |
| Is the visitor system the cost | `benchmark_visitors.gd` |

## `profile_scene.gd`

Loads a scene, settles it, reports wall-clock frame time (median/p95/worst),
draw calls, objects, primitives, node count, video memory. **Run before
optimising anything.**

```bash
... --script res://scripts/tools/profile_scene.gd -- --scene res://scenes/maps/level1.tscn
... --script res://scripts/tools/profile_scene.gd -- --scene res://scenes/templates/gameplay_base.tscn --settle 600 --frames 900
```

Two traps it encodes, both of which produced nonsense first:

- `Performance.TIME_PROCESS` / `TIME_PHYSICS_PROCESS` / `TIME_FPS` publish **once
  per second**, and the two time monitors are the **max** frame of that second,
  not the mean. They exceed the median frame time and must not be turned into a
  "% of frame". Frame time is wall-clock measured; the monitors are spike
  detectors only.
- Terrain paints across frames, so a short settle blends the generation spike
  into the gameplay median. 600 frames is the measured steady-state for level1.

To attribute cost to a system, **A/B it** (disable, re-measure) rather than
reading a monitor.

## `profile_systems.gd` — rank every system on a loaded map

`profile_scene.gd` reports a median on an **idle** map and concludes "no system
is above the noise floor" — true and useless, since these costs are one-shot
spikes (invisible to a median) and steady-state work that only exists once the
map is busy. This lights 80 fires, spawns a crowd, wears the ground, then times
each system's own entry point.

```bash
... --script res://scripts/tools/profile_systems.gd
... --script res://scripts/tools/profile_systems.gd -- --fires 40 --visitors 8
```

### What it found (level1, RTX 3080, 80 fires + 8 visitors) — all fixed 2026-08-10

Before/after pairs are kept because the **before** is what the next regression
will look like.

- **`Pathfinder.rebuild` 18.7 ms on every structure placement** — the largest
  hitch in the game, and most callers didn't need it. A rebuild re-ingests every
  layer of every cell; a rock, a fence and a ladder change only an occupant claim
  or a traversal edge, both already live on the current grid. The tell was an
  asymmetry: *building* a fence already used `notify_graph_changed` while
  *removing* one rebuilt. Now routed by `Traversal.changes_terrain()` — **true by
  default**, because a decorative traversal that forgets to override is merely
  slow while a terrain-painting one that forgets is a bridge you cannot cross.
  Only `Bridge` still rebuilds. → ~0.05 ms.
- **`FireManager.sim_tick` 1.52 ms/frame → 0.62 ms.** (a) Spread rolls moved from
  every frame to the 0.25 s cadence ignitions already use; `spread_probability`
  is linear in dt, so one coarse roll carries the same expected spread. This also
  closed a **game/sim divergence**: `sim_runner` drives `sim_tick` at dt 0.25
  exactly, so the balance model always measured coarse rolls while the game
  rolled 15x as often at 1/15th the chance — ~4% *less* spread per unit time. The
  sim is unaffected; the game now matches what was balanced. (b)
  `BurningCellVFX.set_state` skips pushes below 1/256 (385 → 57 µs): intensity
  moves over seconds, so consecutive frames differed in the fourth decimal and
  every one wrote shader parameters.
- **A failed `find_path` cost 3.1 ms — dearer than a successful 40-step route**,
  because A* with no goal to stop at runs to exhaustion. Pathfinder now learns
  **connected components** as a by-product of work it already did (a flood fill
  *is* a component; an exhausted search *is* one) and answers cross-component
  queries in O(1). → 3.3 µs, a 940x cut. Requires the graph to be **undirected**,
  which the tool now verifies exhaustively every run rather than assuming (0
  asymmetric edges over 1233 cells).
- **`compute_reachable_set` 0.8-1.2 ms**, asked once per player step by
  `UXOverlay`. Same component cache: the whole landmass is one component, so
  walking inside it is now a dictionary lookup.
- `RegrowthManager`'s day pass was 0.4-0.7 ms at ~170 damaged cells — **replaced**
  rather than optimised; see [vegetation.md](vegetation.md).
- `TileGrid.can_transition` allocated two `Array[int]` per call. Replaced by
  `_edges_share_altitude` (integer comparisons only), guarded by a test walking
  the whole shape × altitude × direction matrix against the original rule.
  **Honest result:** the edge-match step went 2.6 → 1.8 µs, and `can_transition`
  is dominated by its two `is_walkable` calls, so it moved far less than the
  allocation story predicted — and it was no longer hot, since the pathfinder's
  edge cache had absorbed nearly every call. The one item on this list that did
  not pay for its measurement.

**Side effect:** the balance simulator went from ~4.8-6.3 to ~12 runs/min.
Nothing in the sim was optimised — it just pathfinds a lot.

### The node census (`--- every processing node ---`)

Total script `_process` at heavy load is 1.17 ms, 7% of a 60 fps frame. None of
it was where the hand-picked table was looking.

- **[FIXED] Player 168 → 3.5 µs**, one node, essentially all of it
  `Pathfinder.shadow_altitude_deltas` at 171.9 µs run **every frame** by
  `_tick_shadow_cutoff`. It scans all 17 TileMapLayers for the topmost painted
  tile at up to 4 cells along the shadow direction (~68 layer queries a frame),
  while its inputs change per **step** (~0.6 s) and twice a **day** (the sign of
  `shadow_length`). The comment justified the per-frame call by `shadow_length`
  being animated — but only its **sign** is read. Now recomputed when
  `current_cell` or that sign changes, compared against cached inputs rather than
  hung off a step hook so a teleport cannot miss the edge. Player also
  invalidates on `Pathfinder.graph_changed` — the cutoff derives from the cells
  *around* the player, so it goes stale when the world changes.
- **[FIXED] FireAuraOverlay 164 → ~50-75 µs**, one node: it re-baked the 96x1
  bearing strip, smoothed 96 bins, wrote 96 pixels and uploaded a texture every
  frame. Now on a 20 Hz cadence — a soft glow whose own `SMOOTH_TAU` lags it far
  more than 50 ms. Its smoothing is `exp(-dt/TAU)`, so handing it the accumulated
  delta traces the same curve. The idle early-out still runs every frame.
- **[NOT FIXED, MEASURED] FireManager's own 500-630 µs** is per-cell cost with no
  lever left of that kind. Consolidating the burn entry's dictionary reads and
  skipping the per-frame `keys()` snapshot was tried: nothing outside the ~20%
  run-to-run spread, and the untyped iteration it forced may cost more than the
  allocation it saves. **Reverted.** The remaining lever is the burn entry's
  shape (an Array-indexed record instead of string keys — invasive, several tests
  construct entries directly).
- **`MAX_CONCURRENT_BURNING` is not a ceiling, and lowering it does nothing.**
  12 paired seeds, 80 → 64: `peak_fires` 95.3 → 98.8 (t=0.4), every metric inert,
  and the peak did not even fall. `_roll_spread` calls `_ignite` **directly**
  rather than through `can_ignite`, so only *random* ignition is gated and a fire
  front walks straight past the number (at a cap of 80 the measured peak averaged
  95 and reached 145). So the constant bounds how many fires the world **starts**,
  not how many burn, and cannot bound the per-frame cost (~6 µs per burning cell)
  it exists to bound. Making spread honour it is a real fire-behaviour change
  (a front would stop advancing at the cap) and needs its own paired sweep.
- The per-instance **VFX are fine** and were most likely to be suspected:
  `fire_blob_column` 106 µs over 138 nodes, `burning_cell_vfx` 63 µs over 98.
- Controllers whose state changes over **minutes** — climate 3.6 µs, water cycle
  4.3, day/night 5.3, altitude fog 0.9 — are all noise. Staggering them across
  frames, the obvious-looking optimisation, would buy nothing.
- `ShaderMaterial.get_shader_parameter` (a read-back polled per frame) measures
  0.0 µs. That suspicion was wrong.

**Read a cheap row with suspicion, not relief:** a `_process` that early-outs on a
state flag (paused clock, hidden overlay, no hover) is cheap *right now*, not
cheap in general. And the instance count is half the story — 1 × 300 µs and
300 × 1 µs want completely different fixes.

**Do not time a sub-microsecond primitive through a Callable.** A `fn.call()`
costs about a microsecond in GDScript, which is most of what `is_walkable` costs;
measured that way, `can_transition` read *unchanged* after its allocations were
removed. The primitive rows are inlined loops for this reason.

## `profile_day_boundary.gd` — find the frame that stutters

Records **every** frame's wall time on a live map and annotates the worst ones
with what happened (day boundary, park opening/closing, visitor spawn/despawn,
fire lighting, graph change), then prices each `day_completed` listener by hand.

```bash
... --script res://scripts/tools/profile_day_boundary.gd -- --frames 600 --measure 9000 --day-secs 12
```

- **The midnight handlers are not the stutter**, though "the day rolls over and
  it hitches" points straight at them. All four together cost ~150 µs
  (`RegrowthManager` ~50, `VisitorFlow` ~100, `SeasonManager` ~3).
- What stutters is what the boundary **causes**: the day's arrivals are released
  at opening and every **spawn** pathfinds. Before the pathfinder's edge cache
  that was a 45-150 ms frame per visitor, and the closing `send_home` sweep — the
  whole crowd re-routing on one frame — measured **617 ms**. After the cache and
  the dropped direction key: only the **first** spawn of the day is visible at all
  (15.5 ms, a cold cache), the rest sit in the ~5 ms noise, and `send_home` is
  0.18 ms per visitor.
- Two traps it encodes, both of which produced a confidently wrong reading first:
  vsync makes every frame read as the refresh interval (it disables it — the first
  run reported a flat 13.34 ms median and learned nothing); and **teleporting the
  clock** to force a midnight crosses several period thresholds in one frame and
  charges their weather rolls to the boundary, so the clock is **compressed**
  (`--day-secs`) instead.
- A measured run is ~30 real seconds against a 240-second game day, so the clock
  must stay inside opening hours or nobody spawns and it measures an empty map.

## The web build — `scripts/tools/profile_web.gd`

**The** tool for "is the web build fast enough, and what is costing". Every other
tool here is a `--script` SceneTree, which cannot exist on web (no command line;
the export boots `run/main_scene`). This one is a **node** attached to the live
game — shipped build, shipped map — that reports itself back over HTTP.

Four files: `profile_web.gd` (harness), `web_profile_boot.gd` (on
`scenes/main.tscn`, inert without the flag), `assets/shaders/profile_ballast.gdshader`
(calibrated fullscreen load), `scripts/tools/run_web_profile.py` (serve + launch
+ collect).

```bash
# 1. unattended (the normal way) — export first, the runner needs docs/index.pck
... --headless --export-release "Web"
python scripts/tools/run_web_profile.py --out /tmp/webprof.txt
python scripts/tools/run_web_profile.py --browser edge --fires 80 --visitors 12
python scripts/tools/run_web_profile.py --headless --keep-open --timeout 400

# 2. by hand (same build, same URL)
cd docs && python -m http.server 8765      # the fetch/PWA need http, not file://
#  http://localhost:8765/?profile  (&fires=80&visitors=12&ysort=0)

# 3. desktop, same entry point — for validating the HARNESS, not for numbers
... --scene res://scenes/main.tscn -- --profile --fires=40 --visitors=8
```

Runner options: `--browser chrome|edge`, `--headless`, `--port`, `--timeout`,
`--fires`, `--visitors`, `--width/--height`, `--keep-open`, `--out` (also writes
`.json` with raw per-block results). Exit 0 **only** if a report arrived. Takes
~2 min. Results also land in the console, an on-screen panel (a screenshot is a
complete result) and `window.__paramo_profile`.

The report contains: a header (platform, the **real** GL renderer, threads,
render target and Mpx, `DisplayManager`'s integer scale, the **measured** clock
tick); a fill sweep (0/4/8/16/32 stacked fullscreen passes, least-squares slope
pricing one pass, and the sweep **response** as the instrument's own sensitivity
check); the A/B (each layer hidden for a block, bracketed by two identical
baselines — a row reading *lower* than baseline is that layer's cost); and the
node census.

Knobs: `MEASURE_FRAMES` (60 — **raise this** to separate the small layers),
`WARMUP_FRAMES` (30), `BALLAST_STEPS`, fires/visitors, and the A/B list in
`_plan()` (add a layer as `["label", _node("Name")]`, **typed as `Node`**).

### Two browser facts that invalidate this repo's usual measurement style

- **The clock is coarse.** Browsers quantise `performance.now()` as a Spectre
  mitigation — measured at exactly **100 µs** here, against 1 µs on desktop —
  because this build ships without cross-origin isolation. So the 3.5 µs Player
  row that `profile_systems.gd` resolves happily is below one tick and is pure
  noise. Phase 1 **measures** the granularity, and the census sizes each script's
  reps adaptively against it (doubling until the total clears 50 ticks; rows land
  at 16 to 16384 reps). A hardcoded rep count returns either 0 or one quantum.
- **The frame rate is pinned by default.** The main loop runs off
  `requestAnimationFrame`, so vsync cannot be disabled from inside the engine.
  Pinned, every frame reads as the refresh interval and "is rain expensive?" is
  unanswerable. Two independent answers: the **browser flags** below remove the
  floor outright (the good path — the A/B then runs at **zero ballast**), and
  **ballast** for when they don't apply. `profile_ballast.gdshader` is a
  fullscreen pass costing real fill that changes no pixel — its arithmetic is
  folded in at a uniform weight of exactly 0, so no compiler can prove it dead.
  `_ab_ballast()` returns 0 when the unballasted frame already sits well under
  the refresh interval, because ballast then costs precision: forcing x32 on an
  unpinned run gave a ±0.90 ms noise floor against a 5.7 ms frame, vs ±0.40 ms at x0.

### Three launch flags are load-bearing (`run_web_profile.py`)

- `--disable-features=CalculateNativeWinOcclusion`. The window is parked
  off-screen (−32000,−32000) so the run doesn't sit on top of your work; without
  this, Windows occlusion detection decides an invisible window is hidden and
  **stops driving `requestAnimationFrame`**, so the harness sits at frame 1 and
  times out with no report.
- `--disable-gpu-vsync --disable-frame-rate-limit`. These unpin the frame rate,
  which is what makes fill directly measurable. **The cost:** the run no longer
  represents a player's frame pacing — it prices the **work**, not the fps anyone
  will see. For that, run without them and read the census.

### The guards, which are the point

The report refuses to quote numbers it cannot stand behind; each guard exists
because the unguarded version produced a confident wrong answer.

- **UNRESPONSIVE** — stacking the full ballast barely moved the frame, so no A/B
  delta means anything. Measured, **not** inferred from the refresh rate.
- **under noise** — the delta lost to the two-baseline noise floor.
- **SOFTWARE RASTERIZER** — the GL renderer is a CPU rasterizer, so every fill
  number is fiction; only the census survives.

### THE ANSWER: where the web frame goes

Chrome, RTX 3080 via ANGLE/D3D11, 1.04 Mpx, 40 fires, 8 visitors, zero ballast,
paired baselines, ±0.20 ms floor, baseline ~6.1 ms:

```
world ALL                    -3.50 ms   57.2%
  terrain layers (x89)       -3.10 ms   50.7%
    ground layers (x18)      -2.70 ms   44.1%   <-- THE TARGET
    structure layers (x34)   -0.20 ms   under noise
    preview layers (x34)     -0.10 ms   under noise
  flora (x162)               -0.30 ms    4.9%
  player (x1)                -0.50 ms    8.2%
  visitors (x8)              -0.40 ms    6.5%
  fire vfx                   -0.20 ms    3.3%
post: grade                  -0.30 ms    4.9%
post: rain / aura / background / ambient     ALL under noise
ui: hud / journal / ux / tile debug / debug  ALL under noise
```

**Eighteen ground TileMapLayers are 44% of the frame, and nothing else is above
9%.** The whole fullscreen shader stack — the thing the tool was built to catch —
totals under a tenth of what the ground layers cost. This inverts the assumption
the tool was built on, and it means a low-res SubViewport would buy less than its
N² arithmetic suggests: it shrinks the fullscreen passes, which are already under
the noise floor.

Cost tracks **tile count**, not layer count: splitting the 18 ground layers into
three bands of 6 gave low −0.20 ms, **mid −3.20 ms** (36.5% of the frame), high
−0.30 ms, and the mid band is where the tiles are.

### Four mechanisms EXCLUDED by measurement — don't rebuild these

- **The 68 empty layers are not the problem.** `StructureLayerManager` spawns two
  TileMapLayers per altitude (structure + preview), 68 of the 89. They are empty
  almost always and measure as free. "Delete the empty nodes" would buy nothing.
- **It is not overdraw. Do not build an occlusion cull.** Average stack depth is
  **1.7** (3121 tiles over 1819 distinct cells), so there is nothing buried to
  cull. Tile area is only **2.6x** the screen (3.05 Mpx of art against 1.17 Mpx,
  counting every texel as opaque and on-screen); at the measured web fill rate of
  0.118 ms/Mpx that is ~0.36 ms against the 4.30 ms attributed to these layers —
  fill is off by **twelve times**. The arithmetic that made overdraw look right
  assumed the tiles covered the screen 35 times. Deriving a mechanism from a cost
  ratio without checking the quantity the mechanism needs is what produced a
  plausible wrong answer.
- **It is not the tile shaders.** `base_tileset.tres` assigns materials per
  TileData (wind on grass, flow on water, waterfall), and 24% of painted ground
  tiles (695 of 2939) resolve to one, concentrated in the **same** mid-altitude
  band that carries the cost. As suggestive as correlation gets, and still wrong:
  nulling all 42 materials for a block moved the frame **0.00 ms**.
- **It is not draw-call submission.** 492 draw calls for the whole frame on web
  (491 on desktop), not ~3000 — the tiles batch.

### So what is it? Still open

~2.7 ms for ~2900 tiles is ~0.9 µs per tile of something that is not pixels and
not draw calls. **There is no single lever, and that is the finding** — every
attribute removed from the ground layers recovers only ~20%:

| removed | delta | share of frame |
|---|---|---|
| global `World` y-sort OFF | −0.40 ms | 7.5% |
| layer y-sort OFF | −0.50 ms | 9.4% |
| tile materials OFF | −0.50 ms | 9.4% |

The parts do not sum to the whole. What is left is the base cost of pushing ~3000
tiles through Godot's canvas renderer on single-threaded WebGL2 — per-item
overhead not attributable to any one feature. **The lever is fewer canvas items**
(bake static terrain, paint fewer tiles), not a setting.

### Y-sort: the valid A/B

Y-sort changes how TileMapLayer groups tiles into CanvasItems, and that grouping
is built **as tiles are painted** — so the in-run probe that flips the flag
afterwards may measure nothing, which is why its −0.50 ms answer was never
trusted. `?ysort=0` exists to test the **paint-time** flag. Same pinned seed,
identical maps (3023 tiles / 1713 cells in both arms):

| arm | baseline | draw calls |
|---|---|---|
| y-sort ON | ~6.1 ms | 518 |
| y-sort OFF | ~5.2 ms | 393 (−24%) |

**Y-sort on the ground layers costs ~0.9 ms, ~15% of the web frame** — and the
in-run probe understated it by about half. What it does **not** say: the ground
layers still cost −2.70 ms in arm B, so y-sort is roughly a **third** of their
cost. Arm B is visually **wrong** (entities no longer sort against terrain), so
this is a **ceiling** on what a batched-base + small-sorted-overlay split could
recover, not a shippable state. Caveat: n=1 per arm, from separate browser
launches; rows *within* a run are paired to ±0.20 ms, these are not.

Verified against the Godot docs: `rendering_quadrant_size` is **ignored** when
y-sort is on, because y-sorting groups tiles by Y position instead of by 32x32
quadrant. The `rendering_quadrant_size = 32` authored in `gameplay_base.tscn` is
therefore dead configuration on the 8 y-sorted layers; level1's Ground7..Ground16
set no `y_sort_enabled`, so those 10 do get quadrant batching — and they are the
cheap band.

**Shipped 2026-08-10: the south-cliff skirt no longer y-sorts.**
`procedural_base.tscn` authored CliffN8/N6/N4 with `y_sort_enabled = true` —
~980 tiles at altitudes −8/−6/−4, paint-only skirt below all playable ground,
whose sorting bought nothing. Measured on web, same pinned seed: ~6.07 → ~5.70 ms
baseline, 518 → 429 draw calls (−17%). **Read the two numbers differently:** the
draw-call drop is large and repeatable and confirms the change took effect; the
~0.37 ms frame delta is n=1 per arm and sits inside plausible cross-run drift.

It is **verified pixel-identical**, not argued: `scripts/tools/verify_cliff_ysort.gd`
renders the map sorted and unsorted and diffs the frames — three seeds (26, 7,
99), 0 of 518400 pixels differ. **That verifier needs two things or it lies**,
both found the hard way:

- **A control diff** (two grabs of the same scene, nothing changed). Without it
  the tool reported "the skirt's y-sort IS doing something" at 2600 differing
  pixels — and 2064 on a repeat. A real sorting change is identical every run; a
  number that moves is animation.
- **`Engine.time_scale = 0`.** Pausing `TimeManager` does **not** stop the tile
  shaders — wind and water flow animate off `TIME`, which Godot scales by
  `Engine.time_scale`. Without it the control alone read 5352 px (seed 7) and
  1784 px (seed 99). With it, every control is 0.

**The "unreachable edge tiles never need sorting" idea has a ~1-2% ceiling** on
this map, measured: only 35 of 3073 tiles (83 of 4544 on another seed) sit more
than 2 cells from **any** walkable cell. The reasoning is sound; the geometry
doesn't pay — the painted skirt hugs the walkable disc closely.
(`Pathfinder.bounds_clip` is **not** the test and gives 0 — it is the 48x48 grid
rect, and every painted tile is inside it. The playable area is a **disc** within
that rect. The real measure is distance from the walkable set, with
`_SORT_MARGIN_CELLS = 2` for sprite height.)

### Traps this tool encodes

- **Do not compare numbers across runs.** The map is procedural and regenerates
  per run (2937/2939/3025 tiles, 86/106 frailejones across three runs), and the
  band split moved from mid −3.20 / high −0.30 to mid −1.30 / high −1.20. Rows
  *within* a run are paired against their own baseline and are comparable.
- **Every A/B row is paired with its own baseline**, measured immediately before
  it. Three baselines across 22 blocks was not enough: the run **drifted** (5.40,
  5.30, then 7.10 ms for the identical configuration), which inflated the noise
  floor to ±1.80 ms, buried every row, and made a run whose frame moved +3.10 ms
  under ballast report itself as UNRESPONSIVE. Pairing dropped the floor to
  ±0.20 ms. **Drift is a trend, not noise to be averaged.** The floor is the
  **median gap between adjacent** baselines, not the widest gap across all of
  them — the widest gap measures the drift the pairing just cancelled.
- The noise floor is **not** a p95-to-median spread. That form reported ±1.38 ms
  on a run whose baselines agreed to 0.00 ms: it measures occasional hitches,
  which each block's median already rejects.
- **Resolve the toggle lists when the block starts, never at plan time.**
  Visitors spawn on a stagger over the seconds *after* the map loads, so a list
  captured at plan time is empty and the row silently skips itself — which is how
  the first decomposed run reported no visitor cost at all. A row with nothing to
  hide prints **NOTHING TO HIDE**, not "under noise" — those mean opposite things.
- **`CanvasLayer` is not a `CanvasItem`.** Four of the six A/B toggles are
  CanvasLayer, and casting them to CanvasItem **nulls** them, so those rows
  vanished from the report rather than erroring, and the first run looked clean
  while measuring two layers. Toggles are typed `Node` and driven through
  `set(&"visible")`.
- **The load must be frozen or it measures itself.** A first run asking for 40
  fires reached 199 across its blocks (fire spreads, and `_roll_spread` bypasses
  `MAX_CONCURRENT_BURNING`). The harness now lights the field and then sets
  `FireManager.set_process(false)`: only the **simulation** stops, every VFX node
  keeps animating, so the rendering load stays real **and** constant. Re-enabled
  for the census.
- **The report clears `_lines` before building the posted blob**, so anything
  printed during setup reaches the console and not the report. Two A/B arms that
  don't record which arm they are cannot be compared — which is what the first
  y-sort A/B produced. The header re-states the seed and ground y-sort count so a
  run is self-identifying.
- **The software-rasterizer guard cannot use Godot's adapter name.** On web
  `RenderingServer.get_video_adapter_name()` returns the constant "WebKit WebGL",
  identical on a 3080 and on SwiftShader, so a guard reading it can never fire
  while looking like it checked. The renderer comes from WebGL's
  `WEBGL_debug_renderer_info` (`UNMASKED_RENDERER_WEBGL`).
- **"Pinned" must be measured, not inferred from the refresh rate.** The first
  version asked `baseline <= vsync_floor * 1.1`, which is backwards once vsync is
  disabled: an *unlocked* 8.2 ms frame is *below* the 16.7 ms interval, so it
  declared "pinned, nothing measurable" on the very run that produced the first
  real fill numbers. The test is whether frame time **responds** to ballast.
- **Headless Chrome got the real GPU** on this machine (`--headless=new`, same
  ANGLE/NVIDIA/D3D11 string as headful). The received wisdom that headless means
  SwiftShader was not true here — established by the guard, not assumed. It is
  still not identical: it reported a different screen size, so `DisplayManager`
  picked scale x2 instead of x4, and the two modes are not directly comparable.
- **The 3080 is pinned at every ballast level on desktop** — 13.3x ms flat at 0,
  4, 8, 16 **and** 32 extra fullscreen passes at 1440x810. That is the standing
  "desktop cannot measure fill" finding reproduced by a tool built to measure fill.

### If no report arrives

The runner exits 1 and prints nothing useful. Causes, in order: the build never
loaded (is `docs/index.pck` newer than the last source change? the runner does
**not** export for you); rAF was throttled so the harness never advanced past
frame 1 (the occlusion flag above — re-run with `--keep-open` and look); the map
never settled (it waits on `generation_finished` and gives up after 6000 frames);
the page threw. On a partial run the on-screen panel shows the last 44 lines.

## `benchmark_pathfinder.gd`

Times `Pathfinder.find_path` on the legs a visitor really builds (entry → goal,
tens of cells), A/Bs the levers, and asserts the shipped search still returns the
pre-cache search's paths.

```bash
... --script res://scripts/tools/benchmark_pathfinder.gd
```

**MEASURED** (level1, 686 reachable cells, 25-step legs, 2026-08-09):

- The cost was never in the **number** of expansions, it was in **each** one.
  ~480 pops took 27.8 ms mean / 95.9 ms worst, i.e. ~56 µs per expansion: every
  edge re-derived walkability, transition legality, step kind and enter cost, and
  `can_transition` allocated two `Array[int]`s and re-ran `is_walkable` on both
  endpoints — after `find_path` had just asked `is_walkable` directly.
- Pathfinder now caches each cell's resolved exits (`_edges_for`), **lazily**:
  5.3 ms mean / 19.9 ms worst, same pop count. Building it eagerly for the whole
  grid costs 49.7 ms, and `graph_changed` fires once per **tile** of a fence run —
  an eager build trades the spawn hitch for a placement hitch.
- The cache is validated against `TileGrid.structure_version`, **not a signal**.
  `Rock`, `Frailejon` and `TraversalBase` all mutate occupancy without emitting
  `graph_changed`, and got away with it only because every query used to be live.
  `test_pathfinder.gd`'s staleness tests search **first**, then mutate, then
  search again — the order is the whole point, and all five fail if the
  invalidation is removed.
- **The second 3.4x, taken 2026-08-10:** the incoming **direction** is gone from
  the search key. It existed only to charge a 1e-4 turn penalty so the
  straightest of the equally-short routes won, and it multiplied the state space
  by 5 (480 → 182 pops). Shipped total: 27.8 → **1.55 ms** mean, 95.9 → 5.7 ms
  worst, i.e. 18x.
  **The price is the staircase.** Ties among shortest routes now fall to the
  heap's FIFO counter, so on open ground a route can zig-zag where it used to turn
  once — the **player's** click-to-move too. Measured on level1 spawn legs: 16 of
  24 routes changed, **0 changed length**. If it ever needs undoing, do **not**
  put the direction back: key on the incoming **axis** (2 states, not 4). A turn
  *is* an axis change, and the one case an axis cannot see — a 180° reversal —
  steps back onto the cell just left at strictly higher g, so it is never optimal.
- A weighted heuristic is **not** the lever (h × 1.25 → 22.2 ms, barely better).
  The search is not unfocused; the expansions are just dear.
- `test_pathfinder.gd`'s turn tests assert **length** now. Two still check a turn
  count, and both are geometry (a 1-wide corridor, an L with one corner) rather
  than tie-breaking. The open-3x3 case that really depended on the penalty was
  relaxed — it kept passing after the change purely because of the order of
  `_NEIGHBOR_DIRS`, exactly the kind of accident a test should not encode.

## `benchmark_visitors.gd`

The balance simulator **cannot** settle a visitor perf question: it is dominated
by fire (~1900 ignitions, ~90 concurrent, against 8 visitors), and two 16-seed
sweeps of the **same** code disagreed by 8% on machine drift alone. So this times
the three expensive operations in one process with the old and new
implementations **alternated round by round**; drift then hits both arms and the
**ratio** survives even when the ms do not.

```bash
... --script res://scripts/tools/benchmark_visitors.gd
... --script res://scripts/tools/benchmark_visitors.gd -- --count 8 --frames 400 --rounds 6
```

**MEASURED** (level1, 8 visitors, 370-cell reachable set, 2026-08-09):

- A visitor's **re-route** costs ~0.6 ms (~12 ms before `find_path` lost its
  per-edge derivation and its direction key). `_walk_to` runs up to three A*
  searches plus the standing-cell reservations, in GDScript. **Validating** the
  queued path instead (`GridWalker.path_is_valid`) costs ~0.06 ms — 9.6x, and it
  re-routes only the visitors the change actually broke.
- The spawner's reachable-set flood fill costs ~1.1 ms (~2.7 ms before).
- Those two are **per `graph_changed` signal**, and a fence run emits one **per
  tile**. Before both ends were coalesced, a 10-tile fence run with 8 visitors
  cost 10 × (2.7 + 8 × 12) ms — about **one second of frozen frame**, on the most
  interactive action in the game. (At today's costs the same un-coalesced code
  would be ~60 ms. Cheap search raised the ceiling; it did not make per-signal
  work acceptable.)
- `nearest_reachable` measured only 1.7x faster after dropping the whole-set
  `sort_custom`, because both versions were dominated by the `find_path`
  confirmation they share. Now that the confirmation is ~40x cheaper the sort is
  exposed and the same comparison reads **4.2x** — a reminder that a ratio between
  two implementations is only meaningful against the shared cost of the day it
  was taken.
- **The steady state is nothing:** 34 µs/frame for the whole crowd, 4.3 µs per
  visitor, ~0.2% of a 16 ms frame. Per-frame micro-optimisation of `GridWalker`
  is not where visitor cost lives — the re-route path is.
- This tool **cannot** see the spawn hitch: it samples the short legs between
  waypoints, while a spawn builds entry→goal. Use `benchmark_pathfinder.gd` for
  anything about route length.

## Not on this branch: the low-res SubViewport

`scripts/tools/compare_stretch_modes.gd`, `DisplayConfig.stretch_mode`,
`SmoothPixelViewport`, `assets/shaders/subpixel_offset.gdshader`, the debug
overlay's "Pixel Grid" toggle, `verify_subpixel.gd` and `screenshot_subpixel.gd`
live on **`feature/LowResRasterization`** (tip `4cc5636`, WIP, unmerged). **None
of those symbols resolve here** — don't write code against them.

What was measured there, since it still frames the decision: framing is
**identical** between the two stretch modes (both cameras at zoom 1,
`content_scale_size` = window/N either way), so "switch to 480x270" does not
change what the player sees; the terrain looks the same (tile art is already
pixel-locked), and the visible delta is in **text** and the fullscreen shaders.
Neither a still-frame comparison nor a desktop benchmark can settle it — the
deciding VIEWPORT artefact is pixel **crawl**, which exists only in motion, and
the perf win is exactly N² fewer fragments on the fullscreen passes, which the
web decomposition above shows are already under the noise floor.
