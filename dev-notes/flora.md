# Flora: eight species, three mountains

The species-level layer under `design/flora.md`: how the eight plants in `assets/sprites/objects/ISO_Plants.png` are placed, why the numbers are what they are, and the two tools that keep them honest. Everything measured here was measured on 2026-08-28, on `level1` (48×48, seed range 0–11 unless stated).

## The sheet

128×256, 32×32 cells, one species per row, four growth stages per row left→right (`x = 0/32/64/96`):

| Row | Kind id | Species | Sold? | Shadow |
|---|---|---|---|---|
| 0 | `frailejon` | *Espeletia grandiflora* | yes | yes |
| 1 | `espeletia_hartwegiana` | *E. hartwegiana* | yes | yes |
| 2 | `espeletia_barclayana` | *E. barclayana* | yes | yes |
| 3 | `calamagrostis` | *Calamagrostis effusa* | no | no |
| 4 | `chusquea` | *Chusquea tessellata* | no | no |
| 5 | `cortaderia` | *Cortaderia nitida* | no | no |
| 6 | `hypericum` | *Hypericum juniperinum* | yes | yes |
| 7 | `arcytophyllum` | *Arcytophyllum nitidum* | yes | yes |

`frailejon` keeps its pre-species id: the FTUE, `UnlockState`, the sim bot, `TUTORIAL_BUILD_FRAILEJON` and `_BLOCKING_KINDS` all key on it, and *grandiflora* IS the Chingaza frailejón. Atlases are `resources/objects/variants/<kind>_{0..3}.tres`, data is `resources/objects/<kind>.tres` (`PlantObjectData`), icons for the sold ones are `assets/sprites/UX/icons/<kind>.tres` (the mature frame). Measured ink of the mature frames, rows: 23 / 24 / 21 / 9 / 21 / 16 / 15 / 10. Ground line (bottom inked row) varies 23–27 across species while the scene's sprite offset was tuned for row 0's 25 — a two-texel sink/float on hartwegiana and arcytophyllum that a per-species offset could fix if it ever reads wrong.

## One scene, eight resources

Every species is `scenes/tools/frailejon.tscn` with a different `PlantObjectData` in `data` — the rock pattern (`rock` / `rock_snow` / `rock_moss` share `rock.tscn`). `Frailejon.occupant_kind()` returns `data.id`, `walk_penalty()` returns `data.walk_penalty`, `is_displaceable()` returns `data.displaceable`, and `casts_shadow = false` frees the `Shadow` node in `_ready` before any of the shadow wiring runs. The class name stays `Frailejon` because tests, the sim bot and `TileInteractionController` reference it. `_measure_frame_dimensions` is cached per texture (`static _dims_cache`): it scans 1024 texels with `get_pixel`, and at ~350 procgen plants that was ~360k reads on load for at most 32 distinct answers.

## The mountains do not share their frailejón

The three *Espeletia* in the sheet are allopatric. GBIF Colombia occurrences by department (facet query, 2026-08-27): *E. grandiflora* 4844 records, 80% Cundinamarca, 1 in Caldas; *E. barclayana* 300, Cundinamarca 163 / Boyacá 130, type locality Neusa/Guerrero "dry paramo"; *E. hartwegiana* 2238, Tolima 947 / Cauca 688 / Caldas 172, Cundinamarca 1. Chingaza's own frailejón monitoring dataset lists *grandiflora, killipii, uribei, Espeletiopsis corymbosa* and no *barclayana*. The shrubs split the same way: *Arcytophyllum nitidum* has one record in the whole Cordillera Central (Caldas 1 of 4388), *Hypericum juniperinum* is scarce there (Caldas 43 / Tolima 13 of 3549); the three grasses occur in both cordilleras.

So a run is one real paramo, not a blend. `EcosystemProfile` (`scripts/data/ecosystem_profile.gd`, three `.tres` under `resources/ecosystems/`) is a per-kind density multiplier plus the list of what the shop may sell; a kind missing from the dictionary never spawns and is never sold there.

| kind | `chingaza` (humid Oriental) | `guerrero` (dry Oriental) | `nevados` (Central) |
|---|---|---|---|
| `frailejon` | 1.0 | — | — |
| `espeletia_barclayana` | — | 1.0 | — |
| `espeletia_hartwegiana` | — | — | 1.0 |
| `calamagrostis` | 1.0 | 1.2 | 1.2 |
| `chusquea` | 1.0 | 0.15 | 0.8 |
| `cortaderia` | 1.0 | 0.6 | 0.7 |
| `hypericum` | 0.8 | 1.0 | 0.3 |
| `arcytophyllum` | 1.0 | 1.0 | 0.1 |

**The profile is the FIRST draw of the object rng stream** (`ObjectPainter.assign_object_kinds`, `profile == null`), so `ProceduralWorld`, `SimWorld` and the invariants harness — which all seed that stream as `seed ^ OBJECT_SEED_XOR` — land on the same mountain per seed with no plumbing. It is written to `TerrainGrid.ecosystem` and copied to `ProceduralWorld.ecosystem`, which `UnlockState.is_available` reads (group `procedural_world`) to refuse unlocks of species that are not on this mountain; the journal greys them rather than hiding them, so `JournalShopInput`'s index arithmetic stays aligned. `ProceduralWorld.ecosystem_override` pins one; **level1 pins `chingaza`** so the FTUE's frailejón is always on sale. The `_PROFILES` array is draw-indexed: append, never reorder.

## Placement: one weighted roll per cell

`ObjectPainter.assign_object_kinds` computes, per eligible cell (GROUND, FULL_CUBE or FLAT) and per kind,

`d_k = density_by_biome[biome] × profile scale × altitude × water × patch`

then occupies the cell with probability `min(Σ d_k, 1)` and draws the kind proportionally to the weights. This replaced first-hit-wins in registry order, which with twelve kinds made dictionary order a balance knob. Every seed's layout (rocks included) shifted once when this landed.

- **Altitude** — `altitude_band: Vector2i` is a plateau in half-steps with Gaussian shoulders (`_SIGMA_ALT` 3) on the distance to the nearest edge; rocks keep the old single-peak `preferred_altitude`. Real elevation maps as **h ≈ (m − 3000) / 37.5**, so 18 ↔ 3675 m.
- **Water** — `water_affinity > 0` attracts (`exp(−a·d²)`), `< 0` avoids (`1 − exp(−|a|·d²)`), on the 4-connected BFS distance. **Measure before choosing either.** On level1, 900 of ~1350 eligible cells lie within 10 cells of water (lake + river), so a "gentle" +0.02 zeroes the far half of the map (exp(−0.02·13²) = 0.03), and the first tuning pass lost every rosette that way. A gentle pull is ~0.005. Avoidance half-strength sits at `sqrt(ln 2 / |a|)`: −0.3 → 1.5 cells, −0.1 → 2.6, −0.03 → 4.8.
- **Patch (clumping)** — one seeded `FastNoiseLite` per kind (`patch_frequency`), gate `clamp((noise − patch_cut) / patch_edge, 0, 1)`. Chosen over the tile painter's W/N neighbour pull because that streaks along the row-major diagonal, needs per-kind bookkeeping under weighted selection, and gives cell-scale clumps where the ecology is 5–15-cell stands (chuscales, matorrales). See **Clumping** below for what the two knobs actually do.
- **Budget** — each occupied CELL is one CanvasItem, two with a shadow, and canvas-item count is the web frame's lever ([performance.md](performance.md)). `PLANT_BUDGET` 600 warns; the report's healthy band is 300–450 cells. Ground cover (`casts_shadow = false`) is what keeps ~335 cells at ~450 items instead of ~670. Individuals are a separate number — see **Clumping**.

Eligible ground on level1, from the report: altitude mass sits at h 6–20 with a 270-cell plateau at 18 (the lake apron) and a thin tail to 32 — so a band like 18–32 covers ~630 cells, not half the map.

### Where they landed (24 seeds, level1)

`clump` is the fraction of a plant's four face-neighbours holding the same kind — the number the retune was aimed at. For reference, a kind occupying a share *p* of the eligible ground at random scores ≈ *p*.

| kind | chingaza n | alt | water | clump (was) | guerrero n | nevados n |
|---|---|---|---|---|---|---|
| calamagrostis | 181 | 13.0 ± 4.5 | 10.9 | 0.25 (0.26) | 219 | 222 |
| chusquea | 51 | 10.6 ± 5.2 | 2.4 | **0.42** (0.23) | 10 | 46 |
| frailejon / barclayana / hartwegiana | 33 | 13.8 ± 4.2 | 6.8 | 0.18 (0.12) | 57 (12.9) | 26 (16.2) |
| hypericum | 24 | 12.6 ± 4.6 | 10.7 | **0.22** (0.11) | 30 | 9 |
| arcytophyllum | 26 | 12.2 ± 5.9 | 9.2 | **0.16** (0.06) | 24 | 2 |
| cortaderia | 20 | 9.7 ± 4.6 | **1.2** | 0.08 (0.07) | 12 | 13 |
| **cells / seed** | **334** | | | | **352** | **319** |
| **individuals / seed** | **888** | | | | **916** | **889** |

Chusquea lowest and wettest of the community formers, cortadera on the bank (mean 1.2 cells from water), calamagrostis everywhere and driest, hypericum below the rosettes, hartwegiana the highest *Espeletia* — the orderings the research asked for, and `report_flora_scatter.gd` asserts them. `nevados` runs ~10% under the Oriental profiles at the same grass density because it has no Oriental shrub layer; that is the profile, not a bug.

*Calamagrostis* is deliberately the one that did not get clumpier: it is the matrix the others sit in, at ~70% cover in the literature, so it wants a soft mosaic rather than stands.

**`guerrero` is the tight pair for the altitude orderings.** Its *Espeletia* (`barclayana`, band 4–20) overlaps `hypericum` (0–16) almost entirely, and the realised margin is under one half-step at 24 seeds — a retune of either band can invert the check. `hypericum`'s top came down 18 → 16 in this pass because the genus band tops out at 3600 m (h 16), which is evidence, not a fix for a red check.

## Clumping

Two independent things had to change, and only the second one is visible.

### 1. The patch gate needs a plateau, and it did not have one

`patch_frequency` sets patch SIZE and nothing else — the noise amplitude distribution is identical at every frequency (measured; `test_patch_amplitude_is_frequency_independent` guards it). What decides the shape of a stand is the pair `patch_cut` (where the patch starts) and `patch_edge` (how wide the ramp up to full density is).

`TYPE_SIMPLEX_SMOOTH` measured over 12 seeds × 48², which is the whole reason `patch_edge` exists:

| | min | p05 | p25 | p50 | p75 | p90 | p95 | p99 | max |
|---|---|---|---|---|---|---|---|---|---|
| noise | −0.75 | −0.42 | −0.18 | 0.00 | 0.18 | 0.33 | 0.41 | 0.54 | 0.76 |

The ramp used to be a fixed 0.25 wide. With a cut of 0.25 — the value the shrubs were authored at — full density needed noise ≥ 0.50, which is the top 1.3% of the field. **Every patch was ramp and none of them had an interior**, so no species ever reached its authored density anywhere on the map. Share of the map at full density, by (cut, edge):

| cut | edge 0.08 | edge 0.12 | edge 0.20 | edge 0.25 |
|---|---|---|---|---|
| −0.20 | 0.67 | 0.62 | 0.50 | 0.43 |
| 0.00 | 0.39 | 0.33 | 0.23 | 0.17 |
| 0.20 | 0.14 | 0.11 | 0.05 | 0.03 |
| 0.30 | 0.06 | 0.04 | 0.01 | 0.01 |

Mean multiplier (the thing that decides COUNT) for the same pairs: −0.20/0.12 → 0.69, 0.00/0.12 → 0.42, 0.20/0.08 → 0.18, 0.22/0.08 → 0.16, 0.30/0.08 → 0.09. **Count is `density × mean multiplier`**, so tightening a patch without raising `density_by_biome` in the same edit just deletes plants; that is what the first retune did.

`patch_edge` is per species because the pajonal matrix and a chuscal want opposite shapes. Wide-and-low is a soft mosaic (*Calamagrostis*: cut −0.2, edge 0.12, plateau 62% of the map at 37% occupancy). Narrow-and-high is a small dense stand with a sharp boundary, which is what the Vargas thesis describes along the valley floors (*Chusquea*: cut 0.20, edge 0.08, plateau 14% at density 1.46 — above 1, so the cell saturates and the chuscal comes out monodominant, correctly).

Patch frequency also dropped (0.10 → 0.05–0.07): larger blobs have less perimeter per unit area, so the same plant count reads as fewer, bigger stands. Free — frequency does not move the counts.

### 2. One sprite per cell was the real ceiling

`min(Σ d_k, 1)` means a cell is occupied at most once, and `TileGrid` holds one occupant per cell. **The densest stand the scatter can express is one sprite per cell**, and after the gate fix the densest stand on the map still read as a sprinkle in `preview_flora_scatter`. A *Calamagrostis* tussock stands ~0.5 m from the next one and a cell is ~2 m across, so one is the wrong number by an order of magnitude.

`WorldObjectData.individuals_per_cell: Vector2i` is a **draw count, not an occupancy count**. `Frailejon._roll_clump` rolls N per cell, samples N offsets inside the cell's iso diamond (a square box at the same width puts tufts on the neighbouring cube's face), sorts them by y, hands the frontmost to the existing `Sprite2D` and draws the rest in `_draw()`. Consequences worth knowing:

- **N tufts cost one CanvasItem**, because `_draw` runs on the node's own item. The plant budget still counts cells and still means what it says; only draw commands scale. ~335 cells now carry ~890 individuals.
- **A CanvasItem draws its own commands before its children**, which is exactly why the sprite has to be the frontmost individual — otherwise the extras occlude it.
- **The burn shader has to go on the node as well as the sprite** (`apply_burn_material` sets both), or a burning clump chars one tuft and leaves three.
- **Only the frontmost individual casts a shadow.** For a cushion plant that reads as the clump's shadow; for anything with a trunk, leave `individuals_per_cell` at (1, 1). All three *Espeletia* do, and their jitter box is bit-for-bit the historical one.

Authored: *Calamagrostis* / *Chusquea* / *Arcytophyllum* 2–4, *Hypericum* 1–3, *Cortaderia* 1–2, the three *Espeletia* 1.

`report_flora_scatter.gd` prints both numbers — cells in the header, individuals on the line under it — and a `per` column on each row.

## Wind

The three grasses sway (`PlantObjectData.wind_material`); the *Espeletia* and the two shrubs do not, which is the botany. It is the ground's own `wind.gdshader` with a re-sized mask, not a plant-specific shader — 2.67x a plain draw per fragment, +0 draw calls, and under the noise floor on web. See [vfx](vfx.md#wind-on-plants-2026-08-28) for why the fork was wrong and why a still frame cannot tell you a sway is broken.

## Feet

A plant on a walked cell loses growth stages and is eventually removed — `PlantObjectData.trample_resistance`, driven from `RegrowthManager.trample`, measured at ~36 plants destroyed a run. It is the same wear the grass under it takes, and it is the second thing (after fire) that removes flora the player did not place. Full model, the resistances, and the paired-seed numbers are in [vegetation](vegetation.md#feet-kill-plants-too-2026-08-28).

## Growth

`growth_chance` is per in-game hour (`Frailejon._process`, unchanged); a season is 96 hours and a plant needs 3 advances. Values are authored so *Espeletia* take ~3 seasons (0.010–0.012/h), shrubs ~1 (0.028–0.035), grasses ~half (0.05–0.08) — the GDD's "3–4 seasons to mature", which is also what the roadmap's SEASONAL `growth_mode` will land on. The real ratio (decades vs 1–2 years) is ~20×; ~8× is what a 24-day run can show. Procgen still seeds random stages so the field looks established; only planted or young plants visibly grow. `frailejon.tres` used to inherit the script default 0.1 — it is authored now, and the FTUE's seedling stays a seedling for its first season by design.

## Grasses yield, shrubs block

Any registered occupant blocks planting (`ActionPlantSpecies._applies`) and building (`_BLOCKING_KINDS`). At ~0.3 natural cover that would lock the player out of a third of the ground, so ground cover is `displaceable`: the action offers the cell, and **`TileGrid.set_occupant` evicts a displaceable occupant** (clears its claim and frees it) when anything else claims the cell — one eviction point for plants, bridges, ladders and fences. It has to happen in `set_occupant`, not in `_exit_tree`: the new plant's `_ready` claims the cell in the same frame as `add_child`, and the old one's deferred free would still hold it. The three grasses are displaceable; the five sold species and rocks are not, and are in `_BLOCKING_KINDS`.

## Balance (12 paired seeds, `defaults`, seed0 100)

Three arms, because the ecosystem draw consumes one rng value before the rocks are rolled and therefore reshuffles every rock layout: `flora_off` (the tree before this work), `flora_none` (this tree with every profile's `density_scale` emptied — new rock layouts, zero plants) and `flora_on`.

- **Layout reshuffle alone is noise**: `flora_none` vs `flora_off`, every metric |t| < 1.8 (`fires_ignited` +19, t 0.24; `charred_end` −3, t −0.07).
- **Plants on identical maps**: `flora_on` vs `flora_none`, `fires_ignited` 2043 → 1912 (t −1.7), `fires_active_end` 2.5 → 17.0 (t 2.2), `charred_end` −44 (t −0.9), `tokens_final` +2.3 (t 1.0), `placements_frailejon` 0.0. Economy flat; fire leans ~6% down and ends the run with more fires still burning, **but neither clears the 12-seed bar** — the direction is consistent, the mechanism is not identified (grasses are not fuel, `set_burn_amount` follows `fuel_frac`, the only plant-side inputs are ~350 walk penalties on visitor and bot routes). A naive `flora_on` vs `flora_off` pairing reported t 7.1 on `fires_active_end`: that number is the layout change, not the plants. Re-run the three-way before believing any flora ↔ fire claim.

The `flora_none` arm is a temporary edit of the three `.tres`, not a `sim_scenarios.gd` entry — `SimWorld` calls `ObjectPainter.paint` without a profile, so pinning one from a scenario needs plumbing first.

## Tools

| Tool | What |
|---|---|
| `report_flora_scatter.gd` (headless) | Per ecosystem × species: count/seed, altitude mean ± sd, mean water distance, same-kind neighbour fraction, eligible-ground histograms; then PASS/FAIL on the orderings above and the plant budget, exit 1 on any FAIL. `-- --seeds N --scenario level1 --ecosystem id`. Reuses the invariants harness's `SCENARIOS` / `_make_params`, so it sees the sweep's terrain. **Run after any retune of `resources/objects/*.tres` or `resources/ecosystems/*.tres`.** |
| `preview_flora_scatter.gd` (rendering — no `--headless`) | Generates level1 with an ecosystem pinned, strips the atmosphere, aims at the densest stand, saves `preview_out/flora_<id>.png` (+@2x) and prints spawned counts and the shadow count. `-- --ecosystem nevados --seed 26 --out preview_out`. |
| `verify_terrain_invariants.gd` | `_KNOWN_OBJECT_KINDS` must list every registered kind or `_check_object_kind_known` fails every seed. |

Tests: `tests/test_object_painter.gd` (band/water terms, determinism, profile pinning, eligibility, profile ↔ registry consistency), `tests/test_frailejon.gd` (occupant interface off `data`, shadow opt-out), `tests/test_journal_pages.gd` (five swatches, `align_ink_bottom`), `tests/test_tutorial.gd` (every sold species has a build line).

## Journal

Five swatches in `KnownFlora` (5 × 24 = 120 px of 157). The section sets `align_ink_bottom = true`: with inks of 24 and 10 rows centred in a 30-row cell there is no header row at which both clear the warp seams (measured: hypericum and arcytophyllum straddled a block at every gap −36..36); with a shared baseline every run ends on the same row and one row top serves all heights. The buildings section keeps its hand-tuned centring. No text is drawn, so no CSV keys; the four `TUTORIAL_BUILD_*` lines are the only new copy (common names: frailejon motoso, chite, piojo).

## Not done, deliberately

Fire fuel from plant biomass (`_fuel_for_cell` is still the seam — `individuals/seed` is the number it would read); runtime re-seeding after burns; the roadmap's SEASONAL growth mode; discovery of the unsold species in the journal (`set_known`); ecosystem names in the UI (`EcosystemProfile.display_key` is reserved, unwired — needs CSV keys and accent-free Eggmode forms).

**Multi-cell footprints (a tree over 3×3) are the other half of `individuals_per_cell` and are NOT built.** The occupancy half is nearly free — `TraversalBase._register_with_grid` already claims every cell in `occupied_cells()`, which is how a bridge spans a gorge — but four things around it are not:

1. **Altitude.** The sprite is lifted by one cell's altitude, so a footprint straddling a half-step renders half-buried. Needs a "every cell in the footprint shares an altitude" gate in the procgen scatter *and* the placement action.
2. **Y-sort.** A node anchored at the centre sorts as the centre, so anything standing on the front cells draws behind the trunk. Iso multi-tile props anchor at the south cell, which then disagrees with `cell_to_world`.
3. **Fire.** `FireManager` calls `apply_burn_material` on `cd.occupant` per burning cell; nine cells pointing at one node burn it nine times and fire `burned_out` early.
4. **Displacement and refunds** across nine cells when one of them is blocked.

None of it is hard; all of it is testable; none of it can be looked at without tree art. It is its own change.

**The canvas-item A/B on the web build is still not run.** Cell count did not change in this pass, so the item count did not either, but `_draw` added ~550 draw commands per map and that has not been priced on `gl_compatibility` — `profile_web.gd` against the `"Web Profile"` preset, `procedural_object` row.
