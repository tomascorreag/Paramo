# VFX: rain, fire, fire aura

`...` = `"../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" --path .`
Every tool here needs a rendering context — **do NOT pass `--headless`.**

## No world shader may use `TIME`

`TIME` is engine uptime and **keeps advancing through `get_tree().paused`** — that
is why rain used to keep falling, water flowing, grass swaying and flames licking
behind the pause menu and the journal while the sim itself was frozen.

Every world shader animates off the `world_time` global uniform instead
(`global uniform float world_time;`, declared in `project.godot`
`[shader_globals]`). Its only writer is the **`WorldClock` autoload**
(`scripts/systems/world_clock.gd`), which keeps the default (pausable) process
mode: pause stops its `_process`, `world_time` holds, and every shader reading it
renders the frame the pause started on. Unpausing resumes from the held value, so
nothing jumps. It carries the same 3600 s rollover `TIME` had.

Rejected alternative: `Engine.time_scale = 0`, which also stops shader time in one
line but zeroes the delta of everything running `PROCESS_MODE_ALWAYS` — the pause
menu's and the journal's own slide tweens would stall unless each opted out with
`set_ignore_time_scale(true)`.

Two consequences worth knowing:

- **Autoloads don't run in the editor**, so `world_time` sits at 0 there and
  water/wind/fire render a **static** frame in the editor viewport. Play the scene
  or use the preview tools below.
- **`verify_rain_equivalence.gd` cannot compare across the commit that introduced
  this.** A pre-`world_time` reference reads `TIME`, the current shader reads the
  clock, and the two differ by however long the process took to reach the first
  frame — the diff reports a false failure. Comparing two post-`world_time`
  revisions is unaffected.

**`verify_world_clock.gd`** proves both halves on the GPU: that `world_time`
reaches a shader at runtime (there is no CPU read-back to assert against —
`RenderingServer.global_shader_parameter_get` is editor-only and returns null in a
running game), and that it holds across 30 paused frames. `tests/test_world_clock.gd`
guards the rest: the clock's arithmetic, its pausability, and that no world shader
has re-grown a `TIME`.

```bash
... --script res://scripts/tools/verify_world_clock.gd   # exit 0 = live + frozen
```

## Rain shader

`assets/shaders/rain.gdshader` is aggressively optimised, and each optimisation
claims some branch is provably dead — nearly impossible to eyeball, since a
mistake costs a few splash pixels one frame in fifty.

**`verify_rain_equivalence.gd`** renders the current shader and a reference copy
to two SubViewports **in the same frame** (their `TIME` built-in must match — you
cannot compare across runs) and diffs the readback across 11 uniform sets,
including rain.tscn's shipped values and the extremes that steer the culling. A
self-test renders the reference against itself first; if that fails the harness
is broken and the results are meaningless. Exit 0 = identical everywhere.

```bash
git show HEAD:assets/shaders/rain.gdshader > scripts/tools/rain_reference.gdshader
... --script res://scripts/tools/verify_rain_equivalence.gd
rm scripts/tools/rain_reference.gdshader
# or against some other revision/copy
... --script res://scripts/tools/verify_rain_equivalence.gd -- --ref res://some/other.gdshader
```

**`benchmark_rain.gd`** renders rain alone into a 1920x1080 SubViewport, vsync
off, at rain.tscn's shipped uniforms (`rain_amount=1.0` is the worst case —
nothing culled). With `--ref` it times a second shader and prints the ratio. **The
ratio is the meaningful number**; absolute ms is for that GPU at that size.
Use it to settle any "surely X is faster" claim *before* committing — the hashing
comment in rain.gdshader records one that measured 25% slower than intuition
predicted.

```bash
... --script res://scripts/tools/benchmark_rain.gd
... --script res://scripts/tools/benchmark_rain.gd -- --ref res://scripts/tools/rain_reference.gdshader
```

## Blob fire — `scripts/tools/preview_fire_blobs.gd`

`assets/shaders/fire_blobs.gdshader` is fully procedural — there is no sprite to
open, so rendering it is the only way to see it. Draws a row of `FireBlobColumn`s
spanning kindling (left) → wildfire (right) at the real `FireBlobTuning` values on
the palette's darkest background, saved at 4x NEAREST (at 1:1 you cannot tell
whether the faux-pixels are locked to the tile grid).

```bash
... --script res://scripts/tools/preview_fire_blobs.gd -- --out /tmp/fire
... --script res://scripts/tools/preview_fire_blobs.gd -- --out /tmp/fire --ceiling 0.2   # smoulder tail
... --script res://scripts/tools/preview_fire_blobs.gd -- --out /tmp/fire --debug 3
```

`shader_debug` has three modes, each catching one failure:

1. stage index as grey — the rim index **must** exceed the core index; that *is*
   the "outer texels age first" requirement.
2. world-snap check — pan the camera in game; the grid must not swim.
3. quad rect — nothing may clip at the edge. The shader has no spatial bound of
   its own; the quad *is* the bound (`FireBlobTuning.quad_size`).

### Editor-time tuning: `scenes/tools/fire_blob_test.tscn`

Two tuning surfaces, both live in that scene (edits update columns the same
frame, because the preview re-syncs every column each frame — otherwise columns
hold a frozen `.duplicate()` of the material):

- **LOOK** params (ramp colours, `radial_bias`, `rise_curve`, `turb_freq_*`,
  `shape_evolve`, `smoke_dither`) → `resources/materials/fire_blobs.tres`.
- **INTENSITY-SCALED** params (rise height/speed, `turb_amp`, blob sizes,
  stretch, noise, `rise_speed_jitter`, density) → `resources/fire_blob_tuning.tres`.
  These are MIN/MAX pairs (kindling→wildfire), so they can't live on the
  material. The game reads the same resource, so what you tune there ships.

**Editing the intensity params on the material does nothing** — `FireBlobColumn`
overwrites them from the resource every frame. And do **not** expand the preview
node's `tuning` export and drag sliders: an `@export` resource default is CLONED
into the `.tscn` the moment you edit a sub-property, so the edits land in the
scene and the game never sees them, while the preview still looks tuned. Edit
`resources/fire_blob_tuning.tres` directly from the FileSystem dock.

## Off-screen fire aura — `scripts/tools/preview_fire_aura.gd`

The aura (`assets/shaders/fire_aura.gdshader` + `scripts/vfx/fire_aura_overlay.gd`)
is a screen-space edge glow pointing at fires the camera can't see. The tool
builds a 320x240 viewport with a Camera2D at the origin, drops stand-in fires at
chosen bearings, and saves three phases of a probe fire: `0_far` (faint, thin),
`1_near` (bright, thick), `2_onscreen` (glow gone), plus two static context fires
proving distinct directions light distinct edges without interfering.

```bash
... --script res://scripts/tools/preview_fire_aura.gd -- --out /tmp/aura
```

**Not per-fire GPU work.** The overlay bakes every off-screen fire into a 96x1
R32F "weight strip" indexed by bearing from screen centre (weight = intensity ×
rise × far; overlapping fires sum), and the shader samples that strip by each
fragment's angle — N fires cost one texture fetch. Size/intensity and proximity
scaling both live on the CPU.

It renders on a root CanvasLayer at `UILayers.FIRE_AURA` (105) **above**
post-process on purpose: the post vignette darkens the screen edges, i.e.
exactly where the aura draws, so grading it would cancel it. With no fire
off-screen the overlay sets `visible = false`, so it costs nothing.

## The reveal stutter — `scripts/tools/profile_fire_reveal.gd`

**Igniting a fire is not what hitches; revealing one is.** Under
`gl_compatibility` a canvas shader is compiled and linked the first time it is
actually DRAWN, on the main thread. A CanvasItem outside the camera rect is
culled, so it never draws, so its shader never compiles. FireManager can light a
front two screens away for free and the bill arrives on the frame the camera
reaches it — which is exactly how the symptom was reported ("stutter when fire
comes on screen").

The tool records every frame of one continuous run and scripts four events onto
it — ignite off screen, reveal, hide, re-reveal the same fire — so the worst
frames can be read against what caused them. Re-reveal is the discriminator: a
cheap second reveal means a ONE-TIME cost and a warm-up fixes it; an equally dear
one means recurring per-reveal work and a warm-up would not.

```bash
... --script res://scripts/tools/profile_fire_reveal.gd
... --script res://scripts/tools/profile_fire_reveal.gd -- --cold --fires 40 --cluster 200
... --script res://scripts/tools/profile_fire_reveal.gd -- --cold --no-warmup   # the old behaviour
... --script res://scripts/tools/profile_fire_reveal.gd -- --compile-only --cold
```

Note the `--` before the flags: these are user args, and without the separator
`OS.get_cmdline_user_args()` returns nothing and every run silently uses the
defaults.

**MEASURED (level1, RTX 3080, 960x540, vsync off, median frame ~1.8 ms):**

- **The effect scales with how much is revealed at once, and a six-cell fire
  cannot see it.** At `--fires 6` the reveal frame sits inside the run-to-run
  noise (12 paired cold runs: 3.35 ms vs 2.77 ms, the warm-up ahead in only 8 of
  12 — not a result). At `--fires 40`, one realistic front, it is unambiguous:
  **6.10 ms → 2.83 ms mean over 11 paired cold runs, the warm-up ahead 10 of 11.**
  Size the cluster before concluding anything from this tool.
- **The warm-up does NOT relocate the cost onto ignition** — the obvious
  objection, measured rather than argued. Over the same 11 pairs the ignition
  frame cost **9.63 ms without the warm-up and 9.01 ms with it, the warm-up ahead
  in 6 of 11** — a coin flip. Always read both rows of the event table; a change
  that only moved the spike would show here.
- **Re-revealing the same fire costs nothing** (~1.1x median in every arm), which
  is what identifies the cost as first-draw and not as culling or node work.
- **`--compile-only` prices the compile alone at well under 1 ms on this
  driver** (cold 0.84 ms of excess, warm 0.73 ms). So NVIDIA's own compile is not
  where the 7 ms goes; what the warm-up removes is the wider first-draw setup the
  reveal frame otherwise pays for every material and light at once. On WebGL2,
  where program linking is orders of magnitude dearer, the same warm-up covers
  the compile too — **unverified on web**, see below.

**Getting back to cold is harder than it looks.** Deleting
`.godot/shader_cache` is not enough: the GL driver keeps its own program cache
keyed by shader source, so the second run of an experiment re-links from that and
the spike disappears — an early version of this investigation measured the warm
path four times while believing it was measuring the cold one. `--cold` appends a
unique comment to each fire shader, which misses both caches.

**Two spikes this tool finds that are NOT the reveal**, and that the warm-up
neither causes nor cures:

- **Igniting 40 cells inside one frame costs ~9.6 ms**, identical with and
  without the warm-up. It is CPU work — 40 `BurningCellVFX`, each duplicating a
  material, baking a texture and adding a `PointLight2D` — and it *cannot* be
  shader work, because those nodes are off screen and culled on the frame they
  are created, so nothing draws. The tool lights the whole cluster at once, which
  the real sim does not (spread rolls ignite a few neighbours per tick); the lever
  if this ever matters is staggered spawning, not warming.
- **The frame a burn completes costs ~7.5 ms.**

**NOT VERIFIED ON WEB.** The shipping target is WebGL2, where this class of
hitch is far worse, but `profile_web.gd` measures steady-state per-layer costs
over a 60-frame median — it has no way to see a one-off hitch. Confirming the
reveal stutter on web needs instrumentation that does not exist yet.

## `FireShaderWarmup` — the fix

`scripts/vfx/fire_shader_warmup.gd`, spawned once per process from
`FireManager._ready`. A 128x64 SubViewport that nothing composites anywhere, fed
**one item per frame** and then freed. Same trick `ProceduralWorld` already uses
for water/post-process (`SHADER_WARM_FRAMES`), except fire has nothing on screen
at load time to warm itself with.

Four things about it are load-bearing:

- **One item per frame.** The first version added every item at once and rendered
  for three frames, which only relocated the pile-up onto the first of those
  three — the same mistake as the reveal frame, one level down. On an RTX 3080
  the whole warm-up measures 0.84 ms, so this buys nothing locally; it matters
  because the shipping target is WebGL2, where the same work is orders of
  magnitude dearer and a pile-up would show even behind the loading overlay.
  `tests/test_fire_shader_warmup.gd` asserts at most one item lands per frame,
  because that property would otherwise regress silently.
- **The light, and the fact that half the viewport is outside it.** Canvas
  lighting is a separate shader permutation, and the game draws fire BOTH ways: a
  burning cell normally sits under its own `PointLight2D`, but cells past
  `BurningCellVFX.LIGHT_BUDGET` get none. So the light covers only the right half
  and every shader is warmed twice, once each side. Warming one permutation
  leaves the other on the reveal frame.
- **Real node types with the real shader resources.** A stand-in `ColorRect` for
  something the game draws as a `Sprite2D` can warm a different permutation and
  still look like it worked — hence a real `FireBlobColumn` and a real
  `ColorRect` for the aura, matching how each actually draws.
- **`fire.gdshader` is deliberately NOT warmed.** It is the legacy sprite-flame
  path behind `Debug.fire_blob_flames`, which ships off; warming it would charge
  every player a compile for something they never see. Flip that toggle and the
  first fire hitches — the intended trade, asserted in
  `tests/test_fire_shader_warmup.gd`.

`Engine.set_meta("skip_fire_shader_warmup", true)` suppresses it. It has to be
engine metadata rather than a `Debug` flag because it must be answerable before
any autoload's `_ready` — `profile_fire_reveal --no-warmup` sets it in
`_initialize`, and by the time `Debug` exists the warm-up has already drawn.

`tests/test_fire_shader_warmup.gd` guards the coverage by DISCOVERING which
shaders the fire VFX reference (scanning their sources, and the materials that
scenes attach) rather than restating the warm-up's own list — a hand-copied list
would agree with itself forever.

## Fire cost — `scripts/tools/benchmark_fire.gd`

Renders N columns at the real tuning on the real 32x16 iso spacing, each phase
compared against a rain pass.

```bash
... --script res://scripts/tools/benchmark_fire.gd
```

**MEASURED:** on an RTX 3080 every fire phase — including the 80-cell
`MAX_CONCURRENT_BURNING` worst case — lands within a few tenths of a ms of the
empty baseline, i.e. at the noise floor. Desktop cannot resolve this shader's
fill cost; what it times is the 80 nodes/draw calls. The tell is that 80
*kindling* columns measure **dearer** than 80 mature ones despite 100x fewer
fragments. Do not quote the per-phase ms as "fire is fast" — the load-bearing
number is the **area ratio** it prints (80 mature ≈ 1x a fullscreen frame of quad
area). The real decision belongs on the web build; see
[performance.md](performance.md).

## Wind on plants (2026-08-28)

The three grasses (*Calamagrostis*, *Chusquea*, *Cortaderia*) sway. The *Espeletia* and the two shrubs do not: a rosette is a thick woody trunk under dense marcescent leaves and is the thing in a paramo that visibly does not move. `PlantObjectData.wind_material` is the switch; null means still.

**It is `wind.gdshader`, the tile shader, unmodified.** `resources/materials/wind_plant.tres` is a second material on it with the same amplitudes as `wind_heavy.tres` and a different mask. There is no plant-specific shader, and the attempt to write one is the substance of this section.

### Why a fork was wrong

A custom shader was written first, on two arguments that both turned out to be backwards:

- **"Sample the noise once per plant, or a 3px stem tears in half."** The tile shader samples per fragment in world space, so neighbouring texel columns of one sprite round to offsets differing by 0 or 1. That is not tearing — **it is the ripple, and it is the entire effect.** Sampling once per plant makes the whole sprite jump 1–3 texels as a rigid block, which reads as a sprite teleporting rather than grass bending. The tearing was hypothesised and never measured; the ripple was real and got deleted.
- **"Replace the alpha probe with frame-grid arithmetic, it's cheaper."** The probe counts opaque pixels below each fragment, which is precisely the measurement a cut-out needs: the ramp is taken from the plant's own ink, per column, with nothing to author per species. The replacement measured height from the *frame's bottom edge* instead, which is 5–9 transparent rows below where the plant actually starts.

Both are visible in the measurement that matters. `--verify` reports the fraction of a plant's ink redrawn per sample:

| | edge travel | ink redrawn/sample |
|---|---|---|
| one noise sample per plant | 2–3 texels | — (rigid slide) |
| per-fragment noise (tile shader) | ~0 texels | 12–32% |

An edge that does not move is CORRECT here. Mature *Chusquea* redraws 17k physical pixels while its leading edge never shifts at all — the silhouette boils rather than slides. An edge-travel metric scores that as static, which is how the first version got signed off.

### What legitimately differs: the mask, and only the mask

The probe's ramp has to be re-sized because a tussock is not a tile. Measured on ISO_Plants.png — the deepest opaque run in any column, which is what `opaque_below` saturates against:

| species | stage 0 → 3 | ink width |
|---|---|---|
| calamagrostis | 3, 5, 6, 7 | 4–12 cols |
| cortaderia | 7, 6, 10, 12 | 7–16 |
| chusquea | 6, 9, 16, 17 | 8–17 |

A grass tile gives the probe 16–32; a tussock gives it 2–7. At the tile's `dirt 16 / ramp 16` a mature *Calamagrostis* sits at a mask of **0.06** and never moves. The shipped material uses **`dirt 0 / ramp 2`**.

### Who sways, and at what strength

Five species carry a sway material, one each, all on `wind.gdshader`. The other three are `wind_material = null` — no material at all, the cheap path. `PlantObjectData.wind_material` is the switch and `test_exactly_the_authored_species_sway` pins the set.

| sheet row | species | strength vs `wind_heavy` | mask (dirt / ramp) |
|---|---|---|---|
| 1 | *E. grandiflora* (frailejon) | — still | — |
| 2 | *E. hartwegiana* | 0.5 | 4 / 6 |
| 3 | *E. barclayana* | — still | — |
| 4 | *Calamagrostis* | — still | — |
| 5 | *Chusquea* | 0.3 | 0 / 2 |
| 6 | *Cortaderia* | 0.6 | 0 / 2 |
| 7 | *Hypericum* | 0.4 | 2 / 4 |
| 8 | *Arcytophyllum* | 0.3 | 0 / 2 |

Dropping *Calamagrostis* is the real optimisation of the three: it is ~180 plants a map, and the shaded-CanvasItem count on level1 went **437 → 202**.

The masks differ because the alpha probe measures growth form. Deepest opaque run in any column, mature: *hartwegiana* 23 (a trunk — pinned for 4px so the crown sways and the base does not), *chusquea* 17, *cortaderia* 12, *hypericum* 14, *arcytophyllum* 7 (a cushion; at dirt 2 / ramp 4 it never saturated and read as static even at 0.6x).

### The quantiser floor: below ~0.5x nothing moves at all

**`round()` puts a hard floor under this scale, and four of those five strengths are under it.** Measured ink redrawn per sample at maturity, as authored:

| species | strength | churn |
|---|---|---|
| cortaderia | 0.6 | **14%** |
| hartwegiana | 0.5 | 2% |
| hypericum | 0.4 | 0% |
| chusquea | 0.3 | 0% |
| arcytophyllum | 0.3 | 0% |

And with every species forced to 0.6x, masks as authored, all five move (5 / 15 / 14 / 8 / 3%) — so this is the strength, not the masks.

The reason is that the offset is quantised to whole texels. Peak displacement at factor *f* is about `f x 2.7` px, so 0.6x peaks at 1.6 (rounds to 1, often 2), 0.5x at 1.3 (rounds to 1, rarely), and 0.3x at 0.8 (rounds to 0, essentially always). Churn against factor, on the tussock mask, calamagrostis / chusquea / cortaderia:

| factor | churn | vs 1.0x |
|---|---|---|
| 1.0x | 16 / 29 / 27 % | — |
| 0.8x | 11 / 24 / 22 % | 78% |
| 0.7x | 7 / 21 / 19 % | 62% |
| 0.6x | 5 / 15 / 14 % | 47% |
| 0.5x | 4 / 7 / 8 % | 26% |

**The usable range is roughly 0.6x to 1.2x.** A set of five distinct intensities has to be expressed inside it — the ratios can be preserved by scaling the whole set (x2 turns 0.3/0.4/0.5/0.6 into 0.6/0.8/1.0/1.2), at the price of the strongest species swaying more than the ground rather than less.

Scaled in the **strengths**, not in `wind_intensity`: `DayNightSceneController` writes `wind_intensity` on every material in its `wind_materials` array each frame from the day's wind curve and would overwrite it. All five ARE in that array (`gameplay_base.tscn`) — they were not at first, so plants ignored the day's wind entirely while the ground gusted, and `test_every_swaying_material_is_registered_for_the_day_wind_curve` now guards it.

### Cost

**Per fragment**, `benchmark_wind_plant.gd --fill --passes 96` (199 Mpx, RTX 3080). A single 2 Mpx pass is useless — all arms sit at the ~0.45 ms CPU floor and the *shaded* ones come out faster. Stack passes until the sweep responds:

| arm | ms/frame | vs plain |
|---|---|---|
| plain, no material | 1.437 | 1.00× |
| `wind_plant.tres` | 3.836 | 2.67× |
| `wind_heavy.tres` (tile) | 3.872 | 2.69× |

Identical, as it must be — it is the same shader. The probe's early-out does not save anything measurable at `ramp 2` versus the tile's 32.

**Draw calls and canvas items: +0.** Every plant shares one material, so there is nothing to break a batch, and the extras of a clumped cell ride the CanvasItem the node already had.

**On web: under the noise floor.** `profile_web.gd` has a `world: plant sway OFF` row that nulls the material in place, so it is paired inside one frame: **0.00 ms across 202 CanvasItems, against a ±0.10 ms floor** (and +0.10 ms across 437 when *Calamagrostis* still swayed). For scale in the same run, `tile materials OFF` is −0.70 ms (13%) over 42 tile datas.

**Do not A/B this by exporting twice.** Sequential web runs are not paired: two runs of `seed=26` came back at 5.00 and 11.20 ms with 150 canvas items between them. That is what the in-run A/B row exists for.

### `--verify` is the guard, and it has two traps

`benchmark_wind_plant.gd --verify` drives the clock across a span and reports ink churn per species per growth stage. It exists because the first version shipped visibly static and *everything else passed*: the shader compiled, the material bound, the preview render looked right, the fill benchmark priced it, the web profile ran. None of them asked whether the pixels move.

- **Drive `WorldClock`, never `RenderingServer.global_shader_parameter_set(&"world_time", …)`.** The autoload re-pushes the value from its own accumulator every frame, so a direct write is overwritten before anything renders and the test's whole time axis is a lie — it reported zero motion for a shader that was working.
- **Count texels REDRAWN, not how far an edge slid.** See the ripple table above.
- **Seed the global rng.** `Frailejon._roll_clump` draws from it in `_ready`, so without seeding each run gets a different tuft count and ink area; the same settings measured 9% and then 5% on *Calamagrostis*. It is bit-repeatable now, and the sweep above was re-run after the fix — the first version of that table was noise.

