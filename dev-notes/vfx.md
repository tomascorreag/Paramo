# VFX: rain, fire, fire aura

`...` = `"../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" --path .`
Every tool here needs a rendering context — **do NOT pass `--headless`.**

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
