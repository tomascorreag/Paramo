# Minimum Vertical-Slice Loop — Implementation Plan

## Context

Páramo currently has a runnable foundation (procedural terrain, pathfinding, click-to-move player, traversal placement, action system, frailejon planting). It is not yet a **game**: there is no time, no resources, no threats, no win/loss state. This plan adds the smallest set of systems that constitutes a complete game loop — start, play, lose or survive, see consequences — and that audibly carries the procedural rhetoric formalized in the GDD's new "Procedural Rhetoric" section.

**Loop scope.** 1 run = 5 seasons (Dry → Wet → Dry → Wet → Dry), ~3–5 min each. One resource (Water). One plant (Frailejon, already exists). One acute threat (Fire). One chronic ceiling (Climate shift via viable-altitude band creep). One survival metric (Laguna purity). Loss naming end-screen, no score.

**Sub-arguments carried by this loop** (from the procedural rhetoric umbrella claim):
1. Destruction cheap; repair dear (frailejon takes 2 seasons to mature; fire kills in seconds)
2. Triage; can't save everything (fire spreads while player is elsewhere; Tier-1 extinguish only)
6. Climate is a ceiling (viable-altitude band shifts upslope each year — *changes what works*, not just difficulty)
7. The map remembers (end-of-run names losses, doesn't aggregate)

The four remaining sub-arguments (latency, fortress fails, permitted destruction, NGO-perspective rhetoric in full) are deferred to post-loop additions; the architecture below does not block them.

## Design compass

Three principles, all defended in the agent's full design (preserved in conversation):

- **Season-quantized ticks.** Frailejon growth, water generation, laguna drain, climate advance — all on `season_ended`. Real-time ticking only for fire (the one system whose rhetoric requires felt urgency). Continuous trickles invite per-second optimization and erode "slow, asymmetric."
- **Single accountant for spend/generation.** All water moves through `ResourceLedger.add/try_spend(..., source: StringName)` so the end-screen can name where water came from and went without retrofitting.
- **Losses are accumulated as they happen, not reconstructed.** A `RunRecorder` autoload listens to ecosystem events. By the time a frailejon is freed, its death is already counted.

## Architecture

### Autoloads (3 new, on top of existing `TimeManager`, `DisplayManager`, `Debug`)

| Autoload | Responsibility | Key signals |
|---|---|---|
| `SeasonManager` | Owns season clock, year, phase (`PLANNING/ACTIVE/RUN_OVER`). State machine. | `season_started`, `season_ended`, `planning_phase_entered/exited`, `year_changed`, `run_completed(reason)` |
| `ResourceLedger` | `Dictionary[StringName, float]` for resources (currently just `&"water"`). Tracks cumulative add by source for end-screen tally. | `resource_changed(id, value, delta)`, `resource_depleted(id)` |
| `RunRecorder` | Pure data sink. Listens to ecosystem/threat events; aggregates planted/lost/peak counts, laguna history. | None — read on `run_completed`. |

Plus two **signal-only buses** (autoloads, no state):

- `EcosystemEvents` — `frailejon_planted/matured/died(cell, cause)`, `laguna_purity_changed`
- `ThreatEvents` — `fire_started/spread/extinguished(cell)`, `tile_burned(cell)`

Rationale for split: domain clarity at slice time. Mergeable later if it bloats. Past-tense convention. `cause: StringName` for dispatch without string allocation (`&"fire"`, `&"climate"`, `&"removed"`).

**Deliberately NOT autoloads:** `Fire` (spatial, one per burning tile), `LagunaState` (map-local), `ClimateState` (per-map Resource via DI — see below).

### New Resource (.tres) types

**`SeasonProfile` (`res://resources/seasons/dry.tres`, `wet.tres`)**
```
@export id: StringName             # &"dry" | &"wet"
@export display_name: String
@export duration_seconds: float    # 240.0 default
@export allows_fire: bool
@export fire_spawn_min/max_interval: float
@export laguna_drain_per_season: float
@export min_mature_frailejones_for_no_drain: int
@export ambient_tint: Color
```

**`ClimateState` (Resource subclass; instantiated at runtime via `.duplicate()` from a `.tres` of initial values to avoid persisting `current_warming_c` across runs)**
```
signal warming_advanced(new_value, year)
@export initial_viable_band_low/high: int   # half-steps on data grid
@export degrees_per_year: float
@export band_shift_per_degree: int
var current_warming_c: float
var current_year: int
func viable_band_low/high() / cell_in_band(alt) / advance_year()
```

DI pattern: a small `ClimateAuthority` node on `gameplay_base.tscn` (in group `&"climate_authority"`) owns the runtime instance; consumers look it up once in `_ready`. Per-map climate trajectories possible (debug "no-climate" map, etc.). Avoids the autoload-shared-state trap and is testable.

**Extend existing `PlantObjectData`** (don't subclass yet; subclass when a 2nd species lands):
```
@export seasons_to_mature: int = 2
@export water_cost_to_plant: float = 5.0
@export water_per_season_when_mature: float = 1.0
@export wilt_seasons_below_band: int = 2
```
The existing `growth_chance` becomes vestigial for player-planted frailejones; keep it for procgen scatter (don't perturb procgen behavior).

### New scenes

```
scenes/
  entities/
    fire.tscn                    # Node2D extends WorldOccupant; AnimatedSprite + CPUParticles + Timer
  systems/
    fire_spawner.tscn            # listens to SeasonManager; rolls intervals during Dry
  ui/
    hud.tscn                     # signal-driven; water bar, laguna bar, season/year labels
    planning_phase_screen.tscn   # appears on season_ended; "Begin Season N+1" button
    end_screen.tscn              # appears on run_completed; names losses, no score
```

### `gameplay_base.tscn` additions

```
GameplayBase
├── World (y_sort)
│   ├── (existing layers / Player)
│   └── FireContainer (Node2D, y_sort)        # NEW
├── UILayer (CanvasLayer)
│   └── HUD                                    # NEW
├── PlanningLayer (CanvasLayer, layer=110)     # NEW
│   └── PlanningPhaseScreen (visible=false)
├── EndLayer (CanvasLayer, layer=120)          # NEW
│   └── EndScreen (visible=false)
├── ClimateAuthority (Node, in &"climate_authority" group)  # NEW
├── FireSpawner (Node)                         # NEW
├── LagunaState (Node)                         # NEW
└── (existing controllers, post-process, TitleIntro)
```

Inherited maps add a `Marker2D` named `ResearchStation` at a chosen cell.

### Frailejon lifecycle changes

Add `growth_mode: GrowthMode {STOCHASTIC, SEASONAL}` `@export` on `frailejon.gd`. `ObjectPainter` sets STOCHASTIC for procgen scatter; player-planted defaults SEASONAL. Critical: gate the existing hourly TimeManager growth tick on `growth_mode == STOCHASTIC` to prevent double-maturation when SEASONAL is added.

For SEASONAL:
- `_ready`: connect to `SeasonManager.season_ended`.
- On tick: `_seasons_alive++`; if `>= seasons_to_mature`, jump to mature variant. Emit `EcosystemEvents.frailejon_matured(cell)`.
- Same handler: climate band check. If `altitude_center(cell) < climate.viable_band_low()`: `_seasons_below_band++`; transition to `WILTING`; apply tint; if `>= wilt_seasons_below_band`, call `_die(&"climate")`. If back in band, reset counter, return to `HEALTHY`.
- `_die(cause)`: emit `EcosystemEvents.frailejon_died(cell, cause)`; existing cleanup; `queue_free`.

Comparison lives **inside the Frailejon node** (rules-bearing unit owns its lifecycle; ~100 frailejones × one float compare per season = free).

### Action integration

`ActionPlantFrailejon`:
- `is_available`: add `ResourceLedger.get_amount(&"water") >= data.water_cost_to_plant`
- `execute`: `ResourceLedger.try_spend(&"water", cost, &"plant_frailejon")` (atomic), then existing plant call, then `EcosystemEvents.frailejon_planted.emit(cell)`. The signal lives in the action, **not** the Frailejon scene, because procgen scatter must NOT count toward player run stats.

### Fire system

**Fire as per-tile `Node2D extends WorldOccupant`** (rejected: tilemap overlay, single particle node). Justification: the GDD names burning frailejones as the game's most devastating visual; deserves an animated scene per fire, not a particle puff. Slots into existing `WorldOccupant` registry (`grid.occupant_at(cell)`).

**Pathfinding integration:** `blocks_movement = false`, `walk_penalty = 3.0`. Click-to-move routes around fires by default; player must explicitly click a fire tile to move into it. The right friction for Tier-1 commitment.

**Spawning** (`FireSpawner`): on `season_started`, if `profile.allows_fire`, schedule rolling intervals. Pick cell weighted by `exp(-altitude/k) * exp(-edge_dist/k)`. Cap concurrent ignition sources at 2 (rhetoric breaks if 8 fires spawn simultaneously and triage becomes futile, not just hard).

**Spread** (per-fire timer, NOT global tick): every `spread_interval_seconds`, for each 4-neighbor candidate (in bounds, walkable terrain, not water, no existing fire), roll ignition probability — base 0.4, 0.85 if a frailejon occupies the cell. Per-fire timers chosen over global tick because synchronized advancement reads as spreadsheet, decorrelated reads as wildfire.

**Frailejon kill on ignite:** when fire spreads INTO a frailejon's cell, call `frailejon._die(&"fire")` immediately (the ignition IS the kill). Burnout from pre-existing frailejone-on-tile-when-fire-spawned: same path on first overlap tick.

**Player extinguish:** Tier 1, polled in `Fire._process` — `if player.cell == self.cell: _overlap_time += delta`; at `EXTINGUISH_TIME` (~2.5s), `_die_extinguished()`. Polling chosen over a Player "moved to cell" signal because adding the signal isn't justified for one listener; revisit if listener count grows.

**Fire lifetime cap:** `lifetime_seconds = 25.0` auto-burnout if not extinguished. Otherwise a single fire could persist across the season boundary into Wet — out of scope for the slice.

**Fire does NOT:** contaminate laguna, generate visibility-blocking smoke, interact with bridges/ladders. Deferred.

### Climate

`SeasonManager` fires `year_changed` after seasons indexed 1 and 3 of the 5-season run (D-W = Year 1, D-W = Year 2; the final D ends mid-Year 3 by design — runs end mid-trajectory).

`LevelRoot._on_year_changed`: `climate.advance_year()` → `warming_advanced` signal → HUD refreshes "+°C" and band labels, frailejones recompute on next `season_ended`.

Existing `Pathfinder.altitude_center(cell)` already returns half-steps; same units as ClimateState band. No data extension needed.

### Laguna

`LagunaState` flood-fills the connected water body once at `_ready`: BFS from the highest-altitude WATER cell with `water_flow == ZERO and river_width == 0`, restricted to same-predicate neighbors. Identifies the laguna without requiring a tagged tile (procgen doesn't currently emit one). Trade-off accepted: if a future map has two equal-altitude lakes, this picks one — revisit with a tag when it bites.

On `season_ended`: count mature frailejones via `pathfinder.grid().occupants_of_kind(&"frailejon")` (already O(N), not O(W*H)). If `< profile.min_mature_frailejones_for_no_drain`, drain `purity` by `profile.laguna_drain_per_season`. Emit `laguna_purity_changed`. If `<= 0`, `SeasonManager.end_run(&"laguna_dead")`.

Visual feedback (light touch): water shader gets a `purity` uniform driven from LagunaState.

### Planning phase

`get_tree().paused = true` + per-node `process_mode` discipline. Planning UI sets `PROCESS_MODE_ALWAYS`. Most gameplay (Player, Fire, FireSpawner, Frailejon process tick) inherits → pauses correctly. `TimeManager.paused = true` in tandem.

**Refinement:** when a season ends, the planning panel appears in a *corner overlay*, world keeps running. Only when the player walks back to the `ResearchStation` marker does `get_tree().paused = true` and the full panel expand. This costs ~10–30s of fire-still-burning if the player isn't at the station — that's the rhetoric, not a bug.

### HUD + End screen

**HUD** is signal-driven (not polled): connects to `ResourceLedger.resource_changed`, `EcosystemEvents.laguna_purity_changed`, `SeasonManager.season_started/year_changed`, `ClimateState.warming_advanced`. Tweens kill-and-restart per change (no stacking).

**End screen** on `run_completed(reason)`: title ("The mountain remembers."), reason ("The laguna died in Year 3."), stat lines pulled from RunRecorder:
- Frailejones planted, surviving, lost to fire, lost to climate
- Peak mature count + season
- Laguna purity at end

Emphasize losses at least as strongly as survivors. **No score, no percentage, no congratulation.** Architecture supports this by not having a scoring resource — don't add one.

## Build order

Each milestone is runnable and verifiable on its own. Ordered to surface integration risk early.

| # | Milestone | Est | Verifiable when |
|---|---|---|---|
| **M0** | Pre-flight: verify `FreeCamera` vs Player camera, `ClickToMoveController` pause behavior (see Risks) | 0.5d | Player-following camera confirmed active; click-to-move halts under `tree.paused` |
| **M1** | `SeasonManager` autoload + `SeasonProfile` `.tres` (dry/wet) + `PlanningPhaseScreen` + pause wiring | 1d | Timer counts down → screen appears + pause → button → resume; cycles 5× → `run_completed(&"survived")` |
| **M2** | `ResourceLedger` autoload; gate `ActionPlantFrailejon` on water + spend; placeholder HUD water label | 0.5d | Plant decreases water; insufficient water blocks the action in radial menu |
| **M3** | `Frailejon` SEASONAL growth mode + maturation signal; `EcosystemEvents` autoload | 0.5d | Plant frailejon, debug-advance 2 seasons, sprite swaps to mature; `frailejon_matured` fires |
| **M4** | `LagunaState` (flood-fill + drain) + `EndScreen` + `RunRecorder` (planted/alive only) | 1d | No-action run → 5 seasons → laguna dies → end screen shows reason |
| **M5** | Mature frailejones generate water on `season_ended` (per §5.6 of design) | 0.5d | Mature frailejones recover water; ≥4 mature prevents laguna drain |
| **M6** | Fire system: `Fire` scene, `FireSpawner`, `ThreatEvents`, spread, extinguish, frailejon kill on ignite | 2d | Dry season → fire spawns → spreads → player stands ~2.5s to extinguish → frailejon-on-fire dies, RunRecorder counts |
| **M7** | `ClimateState` resource + `ClimateAuthority` node + frailejon wilt state machine | 1d | Plant at band edge → advance years → wilts → dies → RunRecorder "lost to climate" increments |
| **M8** | HUD polish (bars, season/year/°C labels) + EndScreen full stats | 1d | All HUD signal bindings live; end screen lists planted/surviving/lost-to-fire/lost-to-climate/peak/purity |
| **M9** | Tuning pass — every dial is `.tres` or `@export`; no code changes expected | 1–2d | Playtest: water economy doesn't snowball; climate forces upslope migration by Year 3; fire feels urgent not futile |

**Total: 8–10 working days.** Compresses if M6 (fire, the largest milestone) goes smoothly.

## Critical files

**Existing — to read/modify:**
- `scripts/tools/frailejon.gd` — add SEASONAL mode, season_ended handler, climate check, wilt state
- `scripts/systems/actions/action_plant_frailejon.gd` — water gate + spend + planted emission
- `scripts/systems/object_painter.gd` — set STOCHASTIC mode on procgen scatter
- `scripts/data/plant_object_data.gd` — add new fields
- `scripts/systems/tile_grid.gd` — `occupants_of_kind` query (verify exists; if not, add)
- `scripts/systems/pathfinder.gd` — `altitude_center(cell)` (verify exists; same units as ClimateState)
- `scenes/templates/gameplay_base.tscn` — add new layers and system nodes
- `resources/objects/frailejon.tres` — set new field values

**New — to create:**
- Autoloads (registered in Project Settings): `scripts/systems/season_manager.gd`, `resource_ledger.gd`, `run_recorder.gd`, `ecosystem_events.gd`, `threat_events.gd`
- Resources: `scripts/data/season_profile.gd`, `climate_state.gd`; `.tres` files in `resources/seasons/dry.tres`, `wet.tres`, `resources/climate/default.tres`
- Scenes: `scenes/entities/fire.tscn` (+ `scripts/entities/fire.gd`), `scenes/systems/fire_spawner.tscn` (+ script), `scenes/ui/hud.tscn`, `planning_phase_screen.tscn`, `end_screen.tscn`
- Map: add `Marker2D` named `ResearchStation` to `scenes/maps/level1.tscn` and any new inherited maps

## Verification — end-to-end smoke test after M9

A successful slice run should demonstrate:
1. Run begins in Dry Season 1, Year 1, +0.0°C, full water, full laguna purity.
2. Player can plant frailejones (water spent, action gated correctly).
3. A fire spawns mid-Dry, spreads, kills at least one frailejon if unattended.
4. Player can run to a fire and extinguish it by standing on it.
5. Season ends → planning panel appears in corner → player walks to ResearchStation → full panel expands → click "Begin Season 2" → Wet starts.
6. After Year 2 ends, climate advances; HUD shows "+°C"; frailejones at the lowest plantable altitudes begin wilting (visible tint).
7. By Year 3 / Season 5, low-altitude planted frailejones have died from climate.
8. Run can end three ways: laguna at 0% (loss), all frailejones dead (loss), or 5 seasons survived. Each shows EndScreen with the correct reason and named loss tally — no score number.
9. Restart button reloads cleanly; SeasonManager / ResourceLedger / RunRecorder reset.

## Risks and items to verify

**To verify before M1 (pre-flight, M0):**
- **`FreeCamera` vs player-following camera.** A free camera that lets the player see fires across the map breaks the triage rhetoric. The slice must use a player-following camera. Inspect `gameplay_base.tscn` and confirm or add a toggle.
- **`ClickToMoveController` pause behavior.** Verify `_unhandled_input` respects `process_mode`. If not, set explicit `PROCESS_MODE_INHERIT` (default) — but read the script first.

**To verify in M1:**
- `Tween` under `tree.paused`: needs `set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)` and possibly `set_ignore_time_scale(true)` for HUD bars to animate while paused. Confirm exact API in Godot 4.6.

**To verify before M6:**
- Spread interval (`6.0s`), CPUParticles2D `amount` (`30`), fire `lifetime_seconds` (`25s`) are all guesses. Tune in M9.
- Concurrent fire cap of 2 may be too generous for ~200-tile maps. Lower if playtests show futility.

**Design risks (validate in M9):**
- **Water snowball.** If `water_per_season_when_mature × mature_count > water_cost_to_plant × plants_per_season`, the player snowballs and only laguna purity pressures them. Tune mature yield strictly *below* the cost of replacing one fire-killed frailejon, so net gain comes from sustained survival, not aggressive replanting.
- **Climate as cosmetic.** If wilting kills one outlying frailejon every two years, the player won't notice. Tune `degrees_per_year` and `band_shift_per_degree` so by Year 3, planting at Year-1 altitudes is *infeasible*. The player's first plantings should die mid-run by climate — that's the rhetoric.

**Accepted risks (won't fix in slice):**
- Two domain buses + per-node signals (RunRecorder subscribes to three sources). Mergeable later.
- LagunaState flood-fill runs once at `_ready`, never recomputed. Slice has no mechanic that converts WATER cells.
- Single-laguna heuristic (highest-altitude still water). Acceptable until a map has competing lakes.

**Out of scope (deliberately):**
- Save/load. Runs are short; iteration first.
- Audio. Architecture won't fight it — `EcosystemEvents` and `ThreatEvents` give an audio listener everything it needs.
- Localization. All strings English literals; swap to translation lookup at the UI binding point when needed.

**Confidence on this plan: MEDIUM.**
- Factual accuracy: HIGH on existing-codebase claims (agent read referenced files); MEDIUM on Godot 4.6 Tween-under-pause and ClickToMoveController pause behavior — flagged as M0/M1 verification.
- Completeness: MEDIUM — `FreeCamera` integration with planning pause not deeply verified.
- Implementation correctness: untested — design only.
