# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

**Detailed tool reference and measured findings live in [`dev-notes/`](dev-notes/README.md)** —
read the relevant file before touching a subsystem or proposing an optimisation.
This file keeps the rules, the commands, and a one-line hook per finding.

## Project Overview

Paramo is a tower defense / environmental strategy game in Godot 4.6 with
GDScript. The player is a field coordinator protecting a Colombian paramo
mountain ecosystem from environmental and human threats across 10 seasons. Full
design in `design/Paramo_GDD.md`.

**Art style:** isometric pixel art (diamond tiles, 2:1). Dome Keeper's
atmospheric density and tonal weight, reprojected into isometric. Locked
projection, no 3D camera — elevation is faked via tile stacking and Y-sort.

This codebase is read with a Unity/C# background. Explain Godot-specific
concepts, especially where they differ from Unity conventions
(scenes-as-prefabs, signals vs events, node tree vs GameObject hierarchy,
`@export` vs `[SerializeField]`, `_ready()` vs `Start()`, `_process()` vs
`Update()`).

## Engine & Commands

- **Engine:** Godot 4.6.1 (Standard, not .NET) · **Language:** GDScript only
- **Executable:** `../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64.exe`
  (GUI) / `..._console.exe` (CLI). Paths relative to the project root.

```bash
G="../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe"

$G --path .                                              # run the project
$G --path . --scene res://path/to/scene.tscn             # run one scene
"../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64.exe" --path . --editor

# GUT tests
$G --path . -s addons/gut/gut_cmdln.gd
$G --path . -s addons/gut/gut_cmdln.gd -gtest=res://tests/test_example.gd
$G --path . -s addons/gut/gut_cmdln.gd -gtest=res://tests/test_example.gd -gunit_test_name=test_method_name

# Export
$G --path . --headless --export-release "Windows Desktop"
$G --path . --headless --export-release "Web"            # -> docs/index.html
```

New `class_name` scripts need `$G --path . --headless --import` once before a
headless run sees them.

### Tools (details in `dev-notes/`)

| Tool | Purpose | Notes |
|---|---|---|
| `verify_terrain_invariants.gd` | Scenario × seed sweep of grid invariants. **Run after touching `terrain_*.gd`.** | [terrain](dev-notes/terrain.md) |
| `dump_cells_around.gd` | Print one generated cell + neighbours | [terrain](dev-notes/terrain.md) |
| `dump_scene_tiles.gd` | Every painted tile of a scene, by layer, with its `tile_kind` | [terrain](dev-notes/terrain.md) |
| `dump_pathfinder.gd` | Reachability + edge legality around a scene's ramps | [terrain](dev-notes/terrain.md) |
| `smoke_test_terrain.gd` | End-to-end generator stats | [terrain](dev-notes/terrain.md) |
| `generate_terrain_cli.gd` | Bake a procedural scene to disk | [terrain](dev-notes/terrain.md) |
| `copy_atlas_setup.gd` | Copy tile definitions between atlas sources | [terrain](dev-notes/terrain.md) |
| `verify_rain_equivalence.gd` | Prove a rain-shader edit is pixel-identical | [vfx](dev-notes/vfx.md) |
| `verify_world_clock.gd` | Prove `world_time` reaches the GPU **and** freezes under pause | [vfx](dev-notes/vfx.md) |
| `benchmark_rain.gd` / `benchmark_fire.gd` | Price a shader edit (the **ratio** is the number) | [vfx](dev-notes/vfx.md) |
| `preview_fire_blobs.gd` / `preview_fire_aura.gd` | Look at procedural fire / the off-screen aura | [vfx](dev-notes/vfx.md) |
| `preview_page_warp.gd` | **Measure** journal page-warp error per column | [journal](dev-notes/journal.md) |
| `audit_page_blocks.gd` | Where the journal's warp seams are, what each section inks, and **how far a heading may move**. `--gap <n>` prices a tightening before authoring it | [journal](dev-notes/journal.md) |
| `verify_journal_palette.gd` | Audit every **rendered** journal pixel against the ink palette | [journal](dev-notes/journal.md) |
| `preview_run_calendar.gd` | Journal pages in 4 run states, both locales | [journal](dev-notes/journal.md) |
| `preview_language_gate.gd` | Title-screen language boxes in 4 states | [journal](dev-notes/journal.md) |
| `preview_tutorial_strip.gd` | FTUE hint strip, 4 steps x both locales | [ftue](dev-notes/ftue.md) |
| `preview_pause_menu.gd` | Pause modal: 3 views x both locales | [ui](dev-notes/ui.md) |
| `measure_tile_ink.gd` | Where a tile's art lands on its cell, in texels | [tiles](dev-notes/tiles.md) |
| `preview_fence.gd` | A built fence run, in context | [tiles](dev-notes/tiles.md) |
| `preview_grass_wear.gd` | A wear ramp across real terrain; audits generated grass rungs | [vegetation](dev-notes/vegetation.md) |
| `index_character_sheet.gd` | Rebuild a visitor index sheet. **Re-run after any repaint.** | [visitors](dev-notes/visitors.md) |
| `verify_visitor_palette.gd` | Diff the recolour shader against the rolled colours | [visitors](dev-notes/visitors.md) |
| `preview_visitor_palettes.gd` | Wardrobe grid, or a crowd walking a real map | [visitors](dev-notes/visitors.md) |
| `profile_scene.gd` | Frame time / draw calls for a scene | [perf](dev-notes/performance.md) |
| `profile_systems.gd` | Rank every system on a **loaded** map | [perf](dev-notes/performance.md) |
| `profile_day_boundary.gd` | Find the one frame that stutters | [perf](dev-notes/performance.md) |
| `profile_web.gd` + `run_web_profile.py` | **Where the web frame goes.** Needs the `"Web Profile"` export preset, not `"Web"` | [perf](dev-notes/performance.md) |
| `benchmark_pathfinder.gd` / `benchmark_visitors.gd` | Price routing / the visitor system | [perf](dev-notes/performance.md) |
| `sim/balance_sim.gd` | Monte Carlo balance runs. **Run after any balance change.** | [sim](dev-notes/balance-sim.md) |

Preview/benchmark tools need a **rendering context** — do not pass `--headless`
to them. Generator, indexing and sim tools are headless.

### Standing findings (detail in `dev-notes/`)

- **Desktop cannot measure this project's canvas fill.** The 3080 is pinned at
  every ballast level; judge fill on the web build.
- **44% of the web frame is 18 ground TileMapLayers**, and nothing else is above
  9%. Overdraw, tile materials, draw-call submission and empty layers are all
  **excluded by measurement** — the lever is fewer canvas items.
- **Y-sort on the ground layers is ~15% of the web frame**, and must be A/B'd at
  **paint time** (`?ysort=0`), not by flipping the flag afterwards.
- **No world shader may use `TIME`** — it runs through `get_tree().paused`. Animate
  off the `world_time` global uniform, written by the pausable `WorldClock` autoload.
- **Anything hanging off `Pathfinder.graph_changed` must be O(1) per frame, not
  per signal** — a fence run emits it once per tile.
- **Compare balance arms seed by seed**, 12+ paired seeds for anything downstream
  of fire. Never price code changes off the sim's wall clock (12% arm drift).
- **`MAX_CONCURRENT_BURNING` is not a ceiling** — spread bypasses `can_ignite`.
- **Generated dirt colonises, so the dirt band is no longer a free firebreak** —
  every walkable dirt cell climbs slowly to a short grass ceiling, and
  `can_ignite` reads the layer. `natural` on each regrowth record is what keeps
  bare dirt out of the scar/appeal numbers. See [vegetation](dev-notes/vegetation.md);
  arm is `no_colonise`.
- **The journal's warp-block rule is about INK, not about node tops** — a run of
  height `h` must span `ceil(h/block)` blocks and no more, which is what
  `JournalBlocks` states and every section snaps against. `header_gap_px` is a
  *request*: any value is legal to author and resolves to the nearest row top that
  renders clean. Measure with `audit_page_blocks.gd` before re-laying-out a page;
  the freedom is set by the tallest **ink**, not by the cell around it. See
  [journal](dev-notes/journal.md).
- **The run opens just after dawn, with no spontaneous fire and 15 tokens** —
  FTUE concessions with knock-on effects (unlocks are priced per type now —
  ladder/frailejon 10, bridge 20, fence 30 — which moves every balance-sim arm).
  See [ftue](dev-notes/ftue.md) before retuning any of them.
- **`toggle_journal` is Space, which the language gate also answers** — the
  journal ignores it until the run is ACTIVE *and* the cinematic is gone.
- **The pause panel does not grow to its content** — `Margin` is anchored to the
  panel rect, so `custom_minimum_size` IS the content box and the **tallest** of
  its three views sets it. About is currently the tallest, at 128px of 130.
  `test_locale_manager.gd` prints both numbers. See [ui](dev-notes/ui.md).
- **The FTUE lights its own fire, off-screen, and it must stay inside
  `FireAuraOverlay.REACH`** — the screen-edge glow is the only thing that reports
  it. It is `contained` (never spreads) and over-fuelled (outlasts the walk),
  both via optional args on `FireManager.ignite` that nothing else may use.
  See [ftue](dev-notes/ftue.md).
- **During the FTUE, a verb does nothing until the step that teaches it** —
  `TutorialGate` (static, four bits) is checked in `ClickToMoveController`,
  `FieldJournal`, `JournalShopInput` and `TileInteractionController`. It defaults
  OPEN and reopens on the tutorial leaving the tree; a refusal never consumes the
  event. See [ftue](dev-notes/ftue.md).

## Architecture

All systems are data-driven: new content = new resource files, not new code.

| System | Responsibility |
|---|---|
| **TileMap** | Isometric grid, per-tile health state machine, moisture propagation (downhill flow), biodiversity. Multi-layer `TileMapLayer` stack with Y-sort for depth. |
| **Threat Spawner** | Season-based weighted random spawning with intensity curves; each threat is a scene with a shared interface |
| **Tool/Structure** | Player-buildable items as scenes with a shared interface (placement rules, costs, effects, upgrades) |
| **Resource Manager** | Abstract N-resource system (water, funding, community support) with generation/drain rates and seasonal modifiers |
| **Season/Time** | Season resources define duration, modifiers, threat profiles, weather; planning phase pauses simulation |
| **Camera/Visibility** | Player-following camera, fog-of-war with last-known-state caching, monitoring station reveal radii, directional audio |
| **Player Controller** | Grid pathfinding, altitude/terrain movement costs, 3 interaction tiers (field/station/radio) |
| **Event System** | Weighted random events per season (funding cuts, partnerships, political shifts) as resource configs |

### Godot patterns to follow

- **Scenes as composition units:** each threat, tool, structure and UI panel is
  its own scene. Godot scenes ≈ Unity prefabs, but they can be full node trees
  with scripts.
- **Resources for data:** `Resource` (`.tres`) for all config — tile definitions,
  threat profiles, season configs, event definitions. Resources ≈ ScriptableObjects.
- **Signals for decoupling:** systems communicate via signals (≈ C# events).
- **Autoloads for globals:** singleton systems (ResourceManager, SeasonManager,
  EventBus) are autoloads ≈ `DontDestroyOnLoad` singletons.
- **`class_name`** to register types globally, so no `preload` everywhere.

### Project structure

```
res://
  scenes/          entities/ templates/ tools/ ui/          # .tscn
  scripts/         systems/ data/ ui/core/ tools/ debug/     # .gd
  resources/       threats/ seasons/ tiles/ events/ ui/      # .tres
  assets/          sprites/ (incl. UX/icons/) audio/ fonts/ shaders/ palettes/
  tests/           GUT tests (test_*.gd)
  addons/          plugins (GUT)
  dev-notes/       tool reference + measured findings
  design/          GDD (en/es), roadmap, moodboard
```

### Map authoring

New gameplay maps are **inherited scenes** of
`res://scenes/templates/gameplay_base.tscn` (≈ Unity prefab variants). The base
wires every system once: `Pathfinder`, `ClickToMoveController`,
`StructureLayerManager`, `TileInteractionController`,
`TraversalPlacementController`, `TileDebugOverlay`, `UXOverlay`,
`DayNightController`, `LayerConfigurator`, post-process, ambient modulate, UI
overlay — plus an empty `World` with the standard 8-altitude `TileMapLayer` stack
and a `Player`.

Scene → New Inherited Scene From… → `gameplay_base.tscn` → save under
`scenes/maps/<name>.tscn`. Paint the `Ground*` layers, override `Player.position`,
save. **Don't add controller nodes** — they're inherited, and edits to them belong
on the base scene. A map needing a different number of altitude tiers must also
override `Pathfinder.tile_map_layers` and `LayerConfigurator.layers` on that map.
`scenes/tools/tileset_test.tscn` is the canonical example.

### The display path: one integer upscale, at window resolution

`DisplayManager` (autoload, `scripts/systems/display_manager.gd`) is the whole
display boundary. **There is no SubViewport**: `gameplay_base.tscn` puts `World`,
the world-space overlays, the day/night `CanvasModulate`, `RainLayer`,
`PostProcessLayer` and `FireAuraLayer` directly under the scene root, and the
window rasterizes everything at its own resolution.

The pixel look comes from CANVAS_ITEMS stretch, not from a low-res buffer.
CANVAS_ITEMS scales the canvas transform by `window_size / content_scale_size`,
so `DisplayManager` locks the upscale to an integer N by setting
`content_scale_size = window_size / N` on every resize. N is chosen from the
**monitor** (1080p → 4×, 2160p → 8×), so resizing shows more or less world at the
same pixel size. `config.base_width/height` (480×270) is only the design
reference used to pick N; the runtime logical viewport is `window / N`.

- **Fill scales with the WINDOW, not with 480×270.** At 1440×810 every fullscreen
  pass is 1.17M fragments, not 130k.
- **`content_scale_factor` is inert here** — the engine only applies it in
  VIEWPORT mode.
- The low-res SubViewport + subpixel-offset work is **not on this branch** (see
  [perf](dev-notes/performance.md)); those symbols don't resolve here.

### Vertical slice scope

1 mountain (~200-300 tiles), 10 seasons, core threats (invasive grass, tourists,
illegal miners, 1 legal mining event, farmers, dry spell, fire, rain), core tools
(frailejones, shrubs, trails, fences, channels, signage, monitoring stations), 3
resources, player movement, camera/visibility, radio upgrade, research station
with management UI, win/loss, end screen. Full breakdown in the GDD.

## Color Palette

Every RGB value **authored in this project** — UI/HUD `StyleBoxFlat` colors,
shader globals, `ColorRect` fills, `Sprite2D.modulate`, ambient/light tints,
gizmos, debug visualizations — **must come from `assets/palettes/palette2.txt`**
(a human-readable mirror of `palette2.aseprite`, which is the source of truth).
Alpha is free; RGB is locked to the 33 entries.

In code, **don't hand-write `Color(...)` literals** — use the `Palette` static
class (`scripts/ui/core/palette.gd`): `Palette.ACCENT` / `Palette.at(i)`, and
`Palette.with_alpha(c, a)` to set alpha. For Inspector values on `.tres`/`.tscn`,
paste the closest palette entry's hex. Don't sample arbitrary hex from
references, screenshots or generation tools. If no entry fits, raise it — the
palette gets edited in Aseprite and re-exported, not bypassed. When
`palette2.txt` changes, update `palette.gd` to match.

Art assets are already palette-bound at authoring time; this rule covers colors
*typed by code or set in `.tres`/`.tscn`*.

Consequences worth knowing: a luminance desaturate or a modulate tint **invents**
colors that are in no palette, so the journal's ink is a CONSTANT-interpolation
gradient map and a highlighted UI frame is a swapped authored stylebox, not a
tint. See [journal](dev-notes/journal.md).

## UI Architecture

### Copy convention: lowercase UI text

All player-facing chrome is **lowercase** — menu items, buttons, headers, section
titles (`paused`, `settings`, `volume`, `resume`). A deliberate typographic
choice for the pixel-art look; don't Title-Case or ALL-CAPS. Applies in **every
language** (`pausa`, `ajustes`), guarded by `tests/test_localization.gd`. Proper
nouns and in-world narrative copy are out of scope — and the `NARRATIVE_` key
prefix is what marks that exemption. It is the FTUE's prose (see
[ftue](dev-notes/ftue.md)), written in sentence case, and the lowercase test
skips that prefix and nothing else.

### Localization: es-CO and en-GB

The player picks on the title screen (see `preview_language_gate.gd`), and the
choice is asked **every launch**, with the previous pick marked but not
pre-committed.

- **Strings live in `assets/translations/paramo.csv`** (UTF-8, no BOM,
  `keys,en_GB,es_CO`). Import generates one `.translation` per column. **The
  importer does not register them** — `project.godot`'s
  `internationalization/locale/translations` is hand-maintained; a new locale
  column needs a new line there.
- **Keys are explicit UPPER_SNAKE** (`UI_PAUSED`), not the English text.
  Scenes/scripts store the KEY, never a translated string: a `Label`
  re-translates whatever sits in `text` when the locale changes, so
  `label.text = tr(...)` freezes that label in one language.
  `tests/test_localization.gd` scans `scenes/ui` and `scripts/{ui,tools,systems}`
  for key-shaped literals and fails on any not in the CSV.
- **`LocaleManager`** (autoload) owns `SUPPORTED`, applies the locale in `_ready`
  (before the loading overlay's first status line) and persists to
  `user://settings.cfg`. Its `_ready` runs **after** a `--script` tool's
  `_initialize`, silently overwriting a locale set there.
- **Nothing has to walk the UI on a locale change.**
  `TranslationServer.set_locale` propagates `NOTIFICATION_TRANSLATION_CHANGED`,
  and `Control` re-translates + `queue_redraw()`s. Custom `_draw` gets this free
  **provided it calls `tr()` inside `_draw`** — a string cached outside it needs
  its own `_notification` handler.
- **Eggmode has no Spanish glyphs** (107 glyphs: no accented vowel, no ñ, no ¿,
  no ellipsis). Every string drawn in it (`RunCalendar.header_text`,
  `JournalKnownSet.title`) must be accent-free in Spanish — hence `temporadas` /
  `obras conocidas` / `flora conocida`. Tiny5 has the full set.
  `tests/test_journal_pages.gd` asserts glyph coverage.
- **Spanish runs ~25% longer, and this project pins widgets to exact pixels.**
  Two real overflows were caught by measurement, not by eye (a 199px heading on a
  156px page; the calendar gutter widened 30 → 38 to hold `4 lluvia`).
  `draw_string` is called with width `-1` — it does not wrap or ellipsise, it
  runs off the paper silently. Tests measure every journal title, every calendar
  row and every pause-menu button in **both** locales; add to them when adding copy.

### Three ways to build UI — pick by what the layout is

- **Prefabs (scene-authored `.tscn`)** — static layouts: `scenes/ui/hud.tscn`,
  `title_intro.tscn`, `debug_overlay.tscn`. Set the root `CanvasLayer.layer` to
  the matching `UILayers` constant.
- **Code-built** (no `.tscn`, spawned via `load(...).new()`) — data-driven or
  animated UI with no fixed layout: `radial_menu.gd` (fans out from a runtime
  array), `loading_overlay.gd` (must have zero load-time dependency).
- **In-world overlays (`Node2D`)** — world space, not screen space:
  `ux_overlay.gd` (reticles at `cell_visual_center`), `tile_debug_overlay.gd`.

### Styling: the authored theme is the source of truth

Static styling lives in **authored resources**, so UI renders styled in the editor
and is edited via the Inspector / Theme editor:

- **`resources/ui/paramo_theme.tres`** — the global theme (`project.godot` →
  `[gui] theme/custom`), inherited by every Control. Carries the Tiny5 font and
  the pixel-art type items: `Button` (normal/hover/pressed/focus + font colors),
  `Panel`/`PanelContainer`, `HSlider` (track/grabber_area + grabber icon),
  `ProgressBar`, `Label`. A bare widget is styled automatically — no code.
- **`resources/ui/styleboxes/*.tres`** — the `StyleBoxTexture` library the theme
  references: `solid_*` (filled) and `frame_*` (hollow outline), each a white
  atlas mask tinted via `modulate_color` = a palette hex. Edit one `.tres` → the
  change shows everywhere. `grabber.tres` is the slider's `AtlasTexture`.
  `tests/test_ui_theme.gd` guards the theme items + stylebox regions/margins.
- **Framed panels use the two-node fill + frame pattern**: a `Panel` (solid fill)
  + a child overlaying `frame_border.tres` — the frame sprite is see-through, so
  it always needs a solid fill behind it. Reusable primitive:
  `scenes/ui/components/framed_panel.tscn`.
- Add a palette-tinted stylebox by copying a `solid_*`/`frame_*` `.tres` and
  changing `modulate_color`; wire it into the theme (or a scene's
  `theme_override_styles/*`) in the editor.

Shared code foundation in `res://scripts/ui/core/` — all static `class_name`, no
autoloads:

- **`Palette`** — the 33 colors. Use for **dynamic/runtime** colors (state tints,
  tween targets); static colors belong in the authored `.tres`.
- **`PixelUI`** — the **dynamic** styling path (runtime-generated styleboxes and
  nodes for data-driven or state-driven UI, e.g. the HUD item-menu frames and
  equipped highlight, radial icons). `make_icon_fill`/`make_icon_sized`
  (nearest-filter `TextureRect`s), `make_frame_ninepatch(tint)` /
  `make_solid_ninepatch(tint)`, `atlas_stylebox` / `solid_stylebox(tint)`
  (cached), and legacy `frame_stylebox(border, fill)`. Sprites are white masks;
  `tint` recolors via `modulate_color`/`self_modulate`. Prefer the authored theme
  for anything static.
- **`UILayers`** — single source of truth for every `CanvasLayer.layer`. `.tscn`
  files can't reference it, so keep authored values in sync;
  `tests/test_ui_layers.gd` guards the drift.

**Deliberate non-goals** (don't add without a concrete need): UI base classes, a
`UIManager` autoload, a grid-snap helper (fractional positions in the codebase
are intentionally animated). Cross-system UI wiring uses groups (`hud`,
`ux_overlay`, `title_intro`), not a manager.

### UI icons

Every UI glyph is its own `.tres` under `res://assets/sprites/UX/icons/`, never a
hard-coded `Rect2` in code. Static → `AtlasTexture.tres`; animated →
`AnimatedTexture.tres` whose frames are `AtlasTexture` entries (per-frame
duration and loop authored in the inspector); a glyph shared by several actions →
**one** `.tres`, referenced from each.

```gdscript
icon = preload("res://assets/sprites/UX/icons/ladder.tres")
```

No `region: Rect2` on the consuming type, no `AtlasTexture` wrapping at the call
site — both extend `Texture2D`, so a single `texture: Texture2D` slot works for
both, and size queries use `texture.get_size()`.

`.tres` resources are shared by reference, so `AnimatedTexture.current_frame` is
shared across all live references — lockstep playback, which is what a radial
menu wants. `.duplicate()` on load if independent playback is ever needed.

Name files by the **semantic glyph**, not the action (`trash.tres`,
`trowel.tres`, `bridge.tres`).

## Web Export & GitHub Pages

Playable at **https://tomascorreag.github.io/Paramo/**.

Single-threaded web export, Compatibility (GLES3/WebGL2) renderer.
`export_presets.cfg` (tracked in git) defines two presets: **"Web"**, which is
what ships, and **"Web Profile"**, identical except for
`custom_features="profiling"` and an export path of `build/web-profile/`. Keep
them in lockstep — the profiler's numbers only mean something while the two
configurations match. Everything below describes "Web":

- **Thread support disabled** — drops the SharedArrayBuffer / cross-origin
  isolation requirement, so the build boots on the widest set of browsers (no
  forced first-load service-worker reload, no hard boot failure where service
  workers are restricted). For a 2D GL-Compatibility game threads buy little.
  Re-enabling them needs server-set COOP/COEP headers, which GitHub Pages cannot
  provide. `ProceduralWorld._generate_grid_async` gates its `WorkerThreadPool`
  path on `OS.has_feature("threads")`, falling back to inline generation.
- **PWA enabled**, `ensure_cross_origin_isolation_headers = false`. This used to
  be load-bearing for the music (COEP off let the Strudel CDN percussion through);
  since every sample is vendored, nothing cross-origin is left to block. It stays
  off because turning it on would need COOP/COEP headers GitHub Pages cannot set.
- **VRAM texture compression flags are inert** — every texture imports Lossless
  (`compress/mode=0`), correct for nearest-filter pixel art.
- **`exclude_filter`** drops `addons/gut/*` (~1.7 MB), `tests/*`,
  `assets/screenshots/*`, `assets/audio_all/*`, and — added 2026-08-11 — the
  three **output** directories that sit under `res://` and were being imported
  back into the next build: `docs/*` (the previous export's own PWA icons and
  manifest), `preview_out/*` (local preview-tool renders, gitignored) and
  `sim_out/*`, plus `.gutconfig.json`. **Measured: 693 → 671 stored files,
  1,659,036 → 1,521,048 bytes of `index.pck`, −8.3%**, all of it build output
  and local scratch. `build/*` joined them 2026-08-17, when the "Web Profile"
  preset started writing there and **14 of its own icon/manifest files came back
  in the next pck** — the same trap, one directory over. Anything a tool writes
  under `res://` needs a line here as well as in `.gitignore` — Godot imports it
  whether git tracks it or not, and a fresh CI checkout will not reproduce it.
  Keep the filter identical across both presets.
  Do **not** add `scripts/tools/*` — `gameplay_base.tscn` /
  `procedural_base.tscn` / `frailejon.tscn` load runtime scripts from there.
- **Do not audit the pck with `strings`.** `.godot/uid_cache.bin` ships inside
  it and maps every UID in the *project* to its path, so excluded directories
  appear in the byte dump and a `strings | grep` reports GUT and all 41 test
  scripts as shipping when they are not. The authoritative list is the export's
  own log: `--export-release ... | grep 'Storing File:'`.
- `head_include` music scripts use `defer` so they don't block first paint.

```bash
# $G as defined under Engine & Commands above
# 0. sync in-game music (skip if no music/*.strudel.js changed)
$G --path . --headless --script res://scripts/tools/sync_music.gd
# 1. export
$G --path . --headless --export-release "Web"
# 2. commit and push docs/ (index.pck is whitelisted in .gitignore)
git add docs/ && git commit -m "update web export" && git push
```

**Pages config:** source = `gh-pages` branch, `/` root — published by
`.github/workflows/deploy.yml` (main → root, staging → `/staging/`), **not** from
`docs/`. `docs/` is the local-preview / manual export output; the live site is
whatever CI last pushed. `.nojekyll` prevents Jekyll processing.

**If the site breaks after re-export** (stale service worker), in the site's
DevTools console:

```js
caches.keys().then(keys => keys.forEach(k => caches.delete(k))).then(() => navigator.serviceWorker.getRegistrations().then(regs => regs.forEach(r => r.unregister()))).then(() => location.reload())
```

**Shader caveat:** web is WebGL 2.0. Test shaders (especially noise/procedural)
on web after changes — they can render differently than a desktop GPU.

## Music (Strudel)

A vendored [Strudel](https://strudel.cc) engine playing one `.strudel.js`
arrangement, with **no dynamics** (MVP scope): autoplays on first user
interaction and loops.

- **Source of truth:** `music/<song>.strudel.js` — authored here, paste-compatible
  with strudel.cc. `music/` is also the score→Strudel converter (`music/README.md`).
- **Runtime copy:** `docs/music/<song>.strudel.js`, **generated** by
  `scripts/tools/sync_music.gd` (run before export). `docs/music/paramo-music.js`
  fetches it and `repl.evaluate()`s it verbatim. Strudel's RNG is seeded by cycle
  position, not the wall clock, so playback is deterministic.
- **No autoload** — there is no MusicDirector; audio lives entirely in the page.
  The export's `head_include` injects the engine bundle + `paramo-music.js`.
  Preview via `docs/music/dev-music.html` (serve `docs/` over http; the fetch
  needs it).
- **CI parity:** `deploy.yml` exports to `build/web/` and its "Bundle music
  assets" step copies the `head_include` static assets from `docs/music/` into the
  export output, dropping the dev-only `dev-music.html`.
- **Nothing is fetched from a third party at play time** (2026-08-17). Drum
  samples (`docs/music/samples/`, uzu-drumkit, public domain) and soundfonts
  (`docs/music/soundfonts/`, FluidR3, MIT) are both vendored and same-origin.
  Adding any CDN fetch back is a licensing decision — read
  `THIRD-PARTY-NOTICES.md` first, including its **Removed** section.
- **The song pins its soundfont variant with `.n()`** — `n` indexes the engine's
  per-instrument variant list, and index 0 is JCLive, whose licence could not be
  established. Dropping an `.n()` call silently reverts to it. Indices are
  per-instrument; see `docs/music/soundfonts/README.md`.

## GDScript Style

- Follow the [GDScript style guide](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html):
  `snake_case` functions/variables, `PascalCase` classes/nodes, `UPPER_SNAKE`
  constants.
- Static typing everywhere: `var health: float = 100.0`,
  `func take_damage(amount: float) -> void:`
- `@export` for inspector-exposed properties, `@onready` for node references.
- Prefer signals over direct method calls between systems.
