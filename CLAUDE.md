# CLAUDE.md

Guidance for Claude Code when working in this repository.

**Tool reference and measured findings live in [`dev-notes/`](dev-notes/README.md).** Read the relevant file before touching a subsystem or proposing an optimisation. This file keeps the rules, the commands, and a one-line hook per finding.

## What the game is

Paramo is a real-time environmental stewardship game in Godot 4.6 / GDScript. It is not a tower defense: nothing marches down a lane and there is no base. The player is an NGO field coordinator who walks one procedurally generated Colombian páramo mountain over a six-season year (wet/dry alternating, 24 game days), identifying flora, planting it, building ladders / bridges / fences, dousing fires with water, and living with the visitors who pay tokens and trample vegetation. Two currencies: `water` (rain-fed, spent on planting and extinguishing) and `tokens` (visitor income, spent on unlocks). The design thesis is in `design/Paramo_GDD.md` (still labelled "tower defense"; the procedural-rhetoric section is the part that matters), the shipping scope in `design/remaining_roadmap.md`, and the 20 source species with their CC BY-NC-ND terms in `design/flora.md`.

**Art style:** isometric pixel art (diamond tiles, 2:1). Dome Keeper's density and tonal weight, reprojected into isometric. Locked projection; elevation is faked via tile stacking and Y-sort.

This codebase is read with a Unity/C# background. Explain Godot concepts where they differ from Unity (scenes-as-prefabs, signals vs events, `@export` vs `[SerializeField]`, `_ready()` vs `Start()`, `_process()` vs `Update()`).

## Engine & commands

Godot 4.6.1 Standard (not .NET), GDScript only. Executable lives beside the project:

```bash
G="../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe"

$G --path .                                              # run the project
$G --path . --scene res://path/to/scene.tscn             # run one scene
"../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64.exe" --path . --editor

$G --path . -s addons/gut/gut_cmdln.gd                                   # all GUT tests
$G --path . -s addons/gut/gut_cmdln.gd -gtest=res://tests/test_x.gd      # one file
$G --path . -s addons/gut/gut_cmdln.gd -gtest=res://tests/test_x.gd -gunit_test_name=test_m

$G --path . --headless --export-release "Windows Desktop"
$G --path . --headless --export-release "Web"            # -> docs/index.html
```

New `class_name` scripts need `$G --path . --headless --import` once before a headless run sees them. Preview / benchmark tools need a rendering context: do not pass `--headless` to them. Generator, indexing, sim and bake tools are headless.

### Tools (`scripts/tools/`, detail in `dev-notes/`)

| Tool | Purpose | Notes |
|---|---|---|
| `verify_terrain_invariants.gd` | Scenario × seed sweep of grid invariants. **Run after touching `terrain_*.gd`.** | [terrain](dev-notes/terrain.md) |
| `dump_cells_around.gd` / `dump_scene_tiles.gd` / `dump_pathfinder.gd` | Print a generated cell, a scene's painted tiles, or reachability around ramps | [terrain](dev-notes/terrain.md) |
| `smoke_test_terrain.gd` / `generate_terrain_cli.gd` / `copy_atlas_setup.gd` | Generator stats, bake a scene to disk, copy tile defs between atlases | [terrain](dev-notes/terrain.md) |
| `verify_rain_equivalence.gd` / `verify_world_clock.gd` | Prove a rain-shader edit is pixel-identical; prove `world_time` reaches the GPU and freezes under pause | [vfx](dev-notes/vfx.md) |
| `benchmark_rain.gd` / `benchmark_fire.gd` / `benchmark_wind_plant.gd` | Price a shader edit (the **ratio** is the number). `--verify` on the wind one proves pixels actually move | [vfx](dev-notes/vfx.md) |
| `preview_fire_blobs.gd` / `preview_fire_aura.gd` / `preview_spawn_flash.gd` | Look at fire, the off-screen aura, the planting/building flash (exits 1 if a row never lights) | [vfx](dev-notes/vfx.md) |
| `profile_fire_reveal.gd` | Why revealing a fire stutters; `--cold` for a true cold shader cache | [vfx](dev-notes/vfx.md) |
| `preview_page_warp.gd` / `audit_page_blocks.gd` / `verify_journal_palette.gd` | Journal warp error per column; warp seams and how far a heading may move; every rendered pixel vs the ink palette | [journal](dev-notes/journal.md) |
| `preview_run_calendar.gd` / `preview_bitacora.gd` / `preview_language_gate.gd` | Journal pages, the bitácora (`--hires` for photographs), the title-screen language boxes. **Render both locales after touching any fact.** | [journal](dev-notes/journal.md) |
| `bake_flora_photos.gd` | Herbarium sheets + field photos → 216×216 polaroid PNGs. Re-run after swapping a photo, then `--import` | [flora](dev-notes/flora.md) |
| `report_flora_scatter.gd` / `preview_flora_scatter.gd` | Per ecosystem × species stats with research-ordering asserts. **Run after retuning `resources/objects/*.tres` or an ecosystem.** | [flora](dev-notes/flora.md) |
| `preview_tutorial_strip.gd` / `preview_pause_menu.gd` | FTUE hint strip; pause modal, both locales | [ftue](dev-notes/ftue.md) / [ui](dev-notes/ui.md) |
| `measure_tile_ink.gd` / `preview_fence.gd` / `preview_grass_wear.gd` | Where a tile's art lands; a built fence; a wear ramp on real terrain | [tiles](dev-notes/tiles.md) / [vegetation](dev-notes/vegetation.md) |
| `index_character_sheet.gd` / `verify_visitor_palette.gd` / `preview_visitor_palettes.gd` | Rebuild a visitor sheet (**after any repaint**); diff the recolour shader; wardrobe grid or a walking crowd | [visitors](dev-notes/visitors.md) |
| `profile_scene.gd` / `profile_systems.gd` / `profile_day_boundary.gd` | Frame time, per-system ranking on a loaded map, the one frame that stutters | [perf](dev-notes/performance.md) |
| `profile_web.gd` + `run_web_profile.py` | Where the web frame goes. Needs the `"Web Profile"` preset | [perf](dev-notes/performance.md) |
| `benchmark_pathfinder.gd` / `benchmark_visitors.gd` | Price routing / the visitor system | [perf](dev-notes/performance.md) |
| `sim/balance_sim.gd` | Monte Carlo balance runs. **Run after any balance change.** | [sim](dev-notes/balance-sim.md) |
| `sync_music.gd` | Copy `music/*.strudel.js` into `docs/music/` before a web export | see Music |

## Standing findings

One line each; the measurement and the rejected alternatives are in the linked note. Anything marked measured was really run.

**Performance** ([perf](dev-notes/performance.md))
- Desktop cannot measure this project's canvas fill; the 3080 is pinned at every ballast level. Judge fill on the web build.
- 44% of the web frame is 18 ground `TileMapLayer`s. Overdraw, tile materials, draw-call submission and empty layers are excluded by measurement; the lever is fewer canvas items.
- Y-sort on the ground layers is ~15% of the web frame and must be A/B'd at paint time (`?ysort=0`), not by flipping the flag afterwards.
- Do not A/B a web change by exporting twice; sequential runs are not paired (5.00 vs 11.20 ms on the same seed). Add a probe row to `profile_web.gd`.
- Anything hanging off `Pathfinder.graph_changed` must be O(1) per frame, not per signal; a fence run emits it once per tile.
- Shader `instance uniform`s come from one fixed global pool (4096), so they are wrong for anything there are hundreds of. `MODEL_MATRIX` resolves per item under `gl_compatibility` and is the safe way to vary a shared material per instance.

**VFX and shaders** ([vfx](dev-notes/vfx.md))
- No world shader may use `TIME`; it runs through pause. Animate off the `world_time` global, written by the pausable `WorldClock` autoload.
- Revealing a fire and igniting one are two different spikes. A culled item's shader never compiles until the camera reaches it; `FireShaderWarmup` pays that at load (6.10 → 2.83 ms). The ignition spike is 40 `BurningCellVFX` at once and staggered spawning is its lever. Deleting `.godot/shader_cache` does not get you back to cold; use `profile_fire_reveal --cold`.
- Plant sway is `wind.gdshader` itself. Per-fragment noise is the effect; per-plant sampling reads as teleporting. Only the alpha-probe mask differs per material (plants `dirt 0 / ramp 2`). Five species sway, one material each, +0 draw calls, under the web noise floor.
- `round()` puts a floor of ~0.6× under any sway strength; usable range 0.6×–1.2×. Scale in the strengths, and every sway material must be in `DayNightSceneController.wind_materials` or it ignores the day's wind.
- Verify that a shader's pixels actually move; the first sway shipped static and passed every other check. Drive `WorldClock`, not the uniform, and count texels redrawn, not edge travel. Framebuffer read-back is in physical pixels.
- `SpawnFlash`: a planted/built thing arrives by 4×4 Bayer dither, flashes white by fade, a first-identified plant fades to gold. Plants flash in a per-plant duplicate of their sway material. A structure overlay must add the layer's origin plus the tile's `y_sort_origin` to its own y or it draws behind the tile. A fence run flashes after the whole run is down.
- `MAX_CONCURRENT_BURNING` is not a ceiling; spread bypasses `can_ignite`.

**Flora and vegetation** ([flora](dev-notes/flora.md), [vegetation](dev-notes/vegetation.md))
- A run is one real páramo, not a blend: `ObjectPainter` draws an `EcosystemProfile` (`chingaza` / `guerrero` / `nevados`) as the first object-rng draw; the three *Espeletia* never share a mountain and the shop sells only what grows here. level1 pins `chingaza`. The draw reshuffles rock layouts, so before/after sim pairs are not paired.
- Water affinity must be measured, not guessed; two thirds of level1's ground is within 10 cells of water, so +0.02 empties the far half of the map.
- The patch gate's ramp width decides whether a stand has an interior; `patch_edge` is per species. Count is density × mean multiplier, so tightening a patch without raising `density_by_biome` deletes plants. `patch_frequency` only moves patch size.
- A cell's plant count and its cell count differ: one occupant per cell, and `individuals_per_cell` is a draw count on the node's own CanvasItem, so N individuals cost one item and `PLANT_BUDGET` still counts cells. The sprite must stay the frontmost individual; the burn material goes on the node too.
- Feet damage the plant and the grass on a cell independently. `RegrowthManager.trample` forwards to the occupant before touching the ledger; plants drop a growth stage per `trample_resistance` of damage and heal a flat 0.15/day.
- Generated dirt colonises, so the dirt band is no longer a free firebreak; `natural` on each regrowth record keeps bare dirt out of the scar/appeal numbers. Arm: `no_colonise`.
- Discovery gates the shop: `ActionInspect` → `FloraCodex` (scene-scoped beside `UnlockState`), and only identified species can be bought or sown. Inspect does nothing else now.

**Journal** ([journal](dev-notes/journal.md))
- Two spreads on the same two pages; sections carry a `spread` tag and `FieldJournal.show_spread` flips `visible`. The bitácora is the second: one species per page, name + binomial, four growth stages in one row, then the page cut in four quadrants (phrases, herbarium polaroid, field-photo polaroid, one rotating field note; layout hashed from the species id by `arrangement()`).
- Polaroids are not drawn in the page; they are `JournalPhotoFloat`s over `BookArt` bent by `photo_warp.gdshader`, and exempt from the palette audit.
- Pages turn by their bent corners (`JournalPageCorners`), one fore-edge tab jumps to the other spread (`JournalForeEdge`), right-clicking a shop plant opens its page. With nothing identified the bitácora is closed (`FieldJournal.has_bitacora()`); `browsable_changed` is what tells the tab and corners about a find.
- The warp-block rule is about ink, not node tops: a run of height h spans `ceil(h/block)` blocks (`JournalBlocks`). `header_gap_px` is a request that snaps to a clean row. Measure with `audit_page_blocks.gd` before re-laying-out a page.
- The journal's ink is a constant-interpolation gradient map, because a desaturate or a modulate invents off-palette colours.
- The book fits any window down to 1 device px per texel: `FieldJournal.fit_to` scales `Book` by M/N, M the largest whole scale ≤ the world's N at which `FIT_RECT` (tabs + cover) fits. Exact under CANVAS_ITEMS; `get_global_rect()` ignores that scale, so screen-space readers use `get_global_transform_with_canvas()`.
- `toggle_journal` is Space, which the language gate also answers; the journal ignores it until the run is active and the cinematic is gone.
- `test_journal_bitacora.gd` measures every fact of every species on both page widths in both locales.

**FTUE** ([ftue](dev-notes/ftue.md))
- The run opens just after dawn with no spontaneous fire and 25 tokens: the tutorial's exact shopping list (frailejón 10+1, ladder 10+2) plus 2, and `TutorialGate.restrict_purchases` limits the shop to it. Unlocks are priced per type (ladder/frailejón 10, bridge 20, fence 30). Read the note before retuning any of these.
- Order: walk → identify a frailejón → read it → buy and plant it → identify a second species → buy and build a ladder → fire. The ladder steps are currently `"disabled"` in `_STEPS` (skipped, sell nothing). `ObjectPainter.ensure_flagship_near` guarantees a mature Espeletia 2–5 cells from the spawn, in both `ProceduralWorld` and `SimWorld`; it shifts later rng draws, so sim pairs across it are not paired.
- A verb does nothing until the step that teaches it: `TutorialGate` (static, five bits plus a shop allowlist) is checked in `ClickToMoveController`, `FieldJournal`, `JournalShopInput` and `TileInteractionController`. It defaults open, reopens when the tutorial leaves the tree, and a refusal never consumes the event.
- The FTUE lights its own fire off-screen, `contained` and over-fuelled via optional `FireManager.ignite` args nothing else may use. It must stay inside `FireAuraOverlay.REACH` or nothing reports it, and it is the shortest walk off screen (`Pathfinder.walk_costs_from`, capped at 30), not the nearest cell: reachability alone lit fires across rivers.

**UI** ([ui](dev-notes/ui.md))
- Pausing the tree does not silence hotkeys on a `PROCESS_MODE_ALWAYS` node; ask `PauseMenu.is_blocking()` first, not `get_tree().paused`, which the journal also sets.
- The pause panel does not grow to its content; `custom_minimum_size` is the content box and the tallest view sets it.
- A Container resets a child's `rotation` and `scale` every layout pass; wrap a rotated glyph in a plain `Control`.

**Balance** ([sim](dev-notes/balance-sim.md))
- Compare arms seed by seed, 12+ paired seeds for anything downstream of fire. Never price code changes off the sim's wall clock (12% arm drift).

## Architecture

Data-driven where it can be: new species, seasons, ecosystems, day/night looks are new `.tres`, not new code.

**Autoloads** (`project.godot`): `DisplayManager` (integer upscale), `TimeManager` (day/night clock), `WorldClock` (pausable shader time), `Debug`, `FireManager` (ignition, spread, burn), `ResourceLedger` (single accountant for water and tokens, tagged by source), `SeasonManager` (the run's spine: season clock, run phase, seasons roll straight over, no planning phase), `DayLog`, `LocaleManager`. Autoloads cannot carry `class_name`.

**Scene-scoped systems** (`scripts/systems/`): `TileGrid` + `TerrainGenerator` / `TerrainPainter` / `ObjectPainter` (procedural mountain), `Pathfinder` + `ClickToMoveController`, `TileInteractionController` + `ActionRegistry` / `actions/*` (the verbs: plant, build, remove, inspect, extinguish), `StructureLayerManager` / `StructurePlacer` / `TraversalPlacementController`, `UnlockState` + `FloraCodex` (shop and discovery), `RegrowthManager` (one vegetation value per cell), `WaterCycle` / `WeatherModel` / `ClimateController`, `VisitorFlow` (the economy) + `VisitorSpawner` (the bodies), `RunController` (starts the run after generation).

**Data** (`scripts/data/`, `resources/`): `WorldObjectData` / `PlantObjectData` (`resources/objects/`), `EcosystemProfile`, `SeasonProfile`, `DayNightProfile`, `TerrainGenerationParams`. `resources/threats/` and `resources/events/` are empty; those systems are roadmap, not code.

The GDD's fog-of-war, monitoring stations, three-resource economy, threat spawner and event system are not built. Check `remaining_roadmap.md` before assuming a system exists.

### Godot patterns

- Scenes are the composition unit (≈ prefabs, but full node trees with scripts). Resources (`.tres`) for all config (≈ ScriptableObjects). Signals between systems (≈ C# events). `class_name` so nothing needs `preload`.
- Static typing everywhere. `@export` for inspector values, `@onready` for node refs. `snake_case` / `PascalCase` / `UPPER_SNAKE` per the GDScript style guide.

### Project structure

```
scenes/    entities/ maps/ objects/ templates/ tools/ traversals/ ui/ vfx/
scripts/   systems/ (+actions/) data/ ui/ (+core/) tools/ (+sim/) debug/
resources/ objects/ ecosystems/ seasons/ day_night/ terrain/ tiles/ materials/ ui/ audio/ characters/
assets/    sprites/ (incl. UX/icons/, flora/photos/) audio/ fonts/ shaders/ palettes/ translations/
tests/     GUT (test_*.gd)      dev-notes/  findings      design/  GDD, roadmap, flora
```

### Maps

`scenes/templates/gameplay_base.tscn` wires every controller once; `procedural_base.tscn` inherits it and adds `ProceduralWorld` + `RunController`. `scenes/maps/level1.tscn` (the shipping map, loaded by `main.tscn`) inherits `procedural_base` and points at a `TerrainGenerationParams`. New maps are inherited scenes (≈ prefab variants): don't add controller nodes on a map, edit the base. A map with a different altitude-tier count must also override `Pathfinder.tile_map_layers` and `LayerConfigurator.layers`.

### Display: one integer upscale at window resolution

`DisplayManager` is the whole display boundary. There is no SubViewport; the window rasterizes everything at its own resolution under CANVAS_ITEMS stretch, and the manager locks the scale to an integer N (1080p → 4×, 2160p → 8×) by setting `content_scale_size = window_size / N` on every resize. 480×270 is only the design reference used to pick N. Consequences: fill scales with the window (1440×810 is 1.17M fragments per fullscreen pass, not 130k); `content_scale_factor` is inert; the low-res SubViewport work is on another branch and its symbols don't resolve here.

## Colour palette

Every RGB value authored in this project (styleboxes, shader globals, `ColorRect`, modulates, tints, gizmos) comes from `assets/palettes/palette2.txt` (mirror of `palette2.aseprite`, 33 entries). Alpha is free. In code use `Palette.ACCENT` / `Palette.at(i)` / `Palette.with_alpha(c, a)` (`scripts/ui/core/palette.gd`), never a `Color(...)` literal; in `.tres`/`.tscn` paste a palette hex. If no entry fits, raise it: the palette is edited in Aseprite, not bypassed. A luminance desaturate or a modulate tint invents colours, so highlighted UI is a swapped authored stylebox, not a tint.

## UI

**Copy is lowercase in the CSV** (`paused`, `pausa`) in every language, guarded by `tests/test_localization.gd`. Journal headings and the species name are cased at draw time by `JournalTitle.cased`. The `NARRATIVE_` key prefix (FTUE prose, bitácora field notes) is the only exemption.

**Localization, es-CO and en-GB.** Strings live in `assets/translations/paramo.csv` (UTF-8, no BOM, `keys,en_GB,es_CO`); `project.godot`'s translation list is hand-maintained. Keys are `UPPER_SNAKE`; scenes and scripts store the key, never `tr()` output, or the label freezes in one language. Custom `_draw` must call `tr()` inside `_draw`. `LocaleManager` applies the locale in `_ready`, which runs after a `--script` tool's `_initialize` and overwrites a locale set there. The player picks every launch. Spanish runs ~25% longer and `draw_string` with width −1 overflows silently, so tests measure every journal title, calendar row and pause button in both locales; add to them when adding copy. The title face is FantasticBoogaloo-16 (Eggmode had no Spanish glyphs).

**Three ways to build UI:** scene-authored `.tscn` for static layouts (`hud`, `title_intro`, `pause_menu`); code-built for data-driven or animated UI (`radial_menu.gd`, `loading_overlay.gd`); `Node2D` overlays for world space (`ux_overlay.gd`).

**Styling:** `resources/ui/paramo_theme.tres` is the global theme (Tiny5 font, pixel-art `Button` / `Panel` / `HSlider` / `ProgressBar` / `Label`), backed by `resources/ui/styleboxes/*.tres` (`solid_*` fills, `frame_*` outlines, white masks tinted by `modulate_color`). Framed panels are a `Panel` fill plus a `frame_border` child (`scenes/ui/components/framed_panel.tscn`). `scripts/ui/core/`: `Palette`, `PixelUI` (runtime styleboxes for state-driven UI), `UILayers` (every `CanvasLayer.layer`; `.tscn` values must match, `tests/test_ui_layers.gd` guards it). No UI base classes, no `UIManager`; cross-system UI wiring uses groups.

**Icons:** every glyph is a `.tres` under `assets/sprites/UX/icons/` (`AtlasTexture` static, `AnimatedTexture` animated, one file per shared glyph), named by the glyph not the action. Consumers take a `Texture2D`; no `Rect2` regions at the call site. `AnimatedTexture.current_frame` is shared by reference: lockstep playback unless `.duplicate()`d.

**Font sizes** must be a multiple of the face's native em (Tiny5 8, FantasticBoogaloo 16).

## Web export and GitHub Pages

Live at https://tomascorreag.github.io/Paramo/. Single-threaded, Compatibility (WebGL2) renderer. `export_presets.cfg` has `"Web"` (ships) and `"Web Profile"` (same plus `custom_features="profiling"`, exports to `build/web-profile/`); keep them in lockstep or the profiler's numbers mean nothing.

- Threads disabled (no SharedArrayBuffer / COOP-COEP, which GitHub Pages cannot set). `ProceduralWorld` gates its `WorkerThreadPool` path on `OS.has_feature("threads")`.
- PWA on, `ensure_cross_origin_isolation_headers = false`. Nothing cross-origin is fetched any more; keep it off.
- Every texture imports Lossless except the bitácora photographs. VRAM compression flags are inert.
- `exclude_filter` drops GUT, tests, screenshots, `assets/audio_all/`, and every output directory that sits under `res://` (`docs/`, `build/`, `preview_out/`, `sim_out/`, …). Godot imports what a tool writes under `res://` whether git tracks it or not, so a new output dir needs a line here as well as in `.gitignore`. Never add `scripts/tools/*`: base scenes load runtime scripts from there.
- Do not audit the pck with `strings`; `uid_cache.bin` names every path in the project. The authoritative list is `--export-release ... | grep 'Storing File:'`.
- Test shaders on web after changes; WebGL2 renders noise differently.

```bash
$G --path . --headless --script res://scripts/tools/sync_music.gd   # if music/*.strudel.js changed
$G --path . --headless --export-release "Web"
git add docs/ && git commit -m "update web export" && git push
```

Pages serves the `gh-pages` branch pushed by `.github/workflows/deploy.yml` (main → root, staging → `/staging/`). `docs/` is local preview output only. If the site breaks after a re-export, clear caches and service workers in the console:

```js
caches.keys().then(keys => keys.forEach(k => caches.delete(k))).then(() => navigator.serviceWorker.getRegistrations().then(regs => regs.forEach(r => r.unregister()))).then(() => location.reload())
```

## Music (Strudel)

A vendored Strudel engine plays one `music/<song>.strudel.js` arrangement (paste-compatible with strudel.cc, deterministic because Strudel seeds by cycle position) with no dynamics; it autoplays on first interaction and loops. No autoload: the export's `head_include` injects the engine and `docs/music/paramo-music.js`, which fetches the `sync_music.gd` copy. Preview via `docs/music/dev-music.html` over http. Drum samples and FluidR3 soundfonts are vendored and same-origin; adding any CDN fetch back is a licensing decision (read `THIRD-PARTY-NOTICES.md`, including its Removed section). The song pins its soundfont variant with `.n()`; index 0 is JCLive, whose licence could not be established, and dropping an `.n()` silently reverts to it (`docs/music/soundfonts/README.md`).
