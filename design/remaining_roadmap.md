# Páramo — Remaining Work Roadmap

Living tracker for the path from the current sandbox+spine to the vertical-slice
game described in the GDD and README. Created 2026-06-22. Supersedes
`min_loop_implementation_plan.md` (kept for reference, but stale: that plan
assumed per-tile fire scenes, a bucket-based extinguish, and a handcrafted map —
all since superseded; see "Decisions locked" below).

Check items off as they land. Each increment should stay runnable and verifiable
on its own.

---

## Decisions locked (this session)

- **Procedural map per run.** The mountain is generated fresh each run from a
  `TerrainGenerationParams` `.tres`; no handcrafted/baked map for the slice.
  Overrides the GDD's handcrafted-map call. See `map_strategy_procedural` memory.
- **Bimodal year of `days_per_year` day/night cycles (N = 16).** Colombian Andes
  rainfall is bimodal (Urrea et al. 2019): two dry windows (~Dec-Feb, ~Jun-Aug)
  and two wet (~Mar-May, ~Sep-Nov), so the default `season_cycle` is
  Dry-Wet-Dry-Wet. `SeasonManager` counts `TimeManager.day_completed`; a season
  rolls every `days_per_year / season_cycle.size()` days (derived
  `days_per_season`, = 4 at N=16). The cycle length doubles as seasons-per-year
  and drives the year counter. The day/night atmosphere is the season's texture.
  `days_per_year`, `season_count`, `seconds_per_game_day` are `@export` for the
  balance pass.
- **Fire is `FireManager` (autoload), not per-tile scenes.** Already implemented:
  ignition rolls, burn, 4-neighbour spread, grass→dirt burnout, rain coupling.
- **Extinguishing costs water; the water bucket is gone.** `ActionExtinguishFire`
  spends from `ResourceLedger`; the bucket state machine and fill action were
  removed.
- **Single accountant.** All water flows through
  `ResourceLedger.add/try_spend(id, amount, source)`; the per-source tally feeds
  the loss-naming end screen later.
- **No score.** The end screen names what was lost; it does not aggregate a
  score (GDD rhetoric).

---

## Status — done this session

- [x] `SeasonManager` autoload — season clock, year, phase
      (`IDLE/ACTIVE/PLANNING/RUN_OVER`), `run_completed(reason)`. + tests.
- [x] `ResourceLedger` autoload — single accountant, source tally. + tests.
- [x] `SeasonProfile` resource + `dry.tres` / `wet.tres`.
- [x] `RunController` — starts the run after world generation
      (`ProceduralWorld.generation_finished`), debug readout, dev keys
      (F fast-forward, M end-season, N next-season).
- [x] Starting water pool seeded at run start (`SeasonManager.starting_water`).
- [x] Extinguish-costs-water; bucket logic removed.
- [x] Season wheel in the HUD, rotating continuously with the season clock. + tests.

---

## Phase 1 — Finish the minimal losable loop

The smallest thing that is a *game*: plant, lose water, watch the laguna, end.

- [ ] **Frailejón seasonal lifecycle.** Player-planted frailejones mature on
      `season_ended` (`seasons_to_mature`), not on the stochastic hourly tick.
      Add `growth_mode {STOCHASTIC, SEASONAL}`; `ObjectPainter` scatter stays
      STOCHASTIC, player plant defaults SEASONAL. Fields on `PlantObjectData`:
      `seasons_to_mature`, `water_cost_to_plant`, `water_per_season_when_mature`.
- [ ] **Gate planting on water.** `ActionPlantFrailejon` checks
      `ResourceLedger.has(&"water", cost)` and spends `try_spend(..., &"plant_frailejon")`.
      (Mirror of the extinguish gate already shipped.)
- [ ] **Mature frailejones generate water** on `season_ended`
      (`&"frailejon_yield"` source). Tune yield strictly below replacement cost so
      survival, not aggressive replanting, is what pays.
- [ ] **`LagunaState`.** Flood-fill the summit water body once; drain purity each
      `season_ended` unless enough mature frailejones exist; `end_run(&"laguna_dead")`
      at 0. Optional `purity` uniform on the water shader.
- [ ] **`EcosystemEvents` / `ThreatEvents` signal buses** (planted / matured /
      died / laguna_purity_changed / fire_started / tile_burned) — wiring for the
      recorder + audio later.
- [ ] **`RunRecorder`.** Pure sink: accumulate planted / surviving / lost-to-fire
      counts and laguna history as events fire.
- [ ] **End screen.** On `run_completed(reason)`: title, reason, named losses
      from `RunRecorder`. **No score.**
- [ ] **Real planning phase UI.** Replace the debug M/N keys: on `season_ended`,
      corner panel appears; walking to a `ResearchStation` marker expands it and
      pauses (`get_tree().paused`); "Begin Season N+1" resumes.
- [ ] **HUD bars.** Signal-driven water + laguna bars, season/year labels
      (alongside the season wheel). Retire the `RunDebugLabel`.

## Phase 1.5 — Make the season felt

- [ ] **Author Dry/Wet `DayNightProfile`s** (golden haze vs gray-blue fog) and
      assign to `SeasonProfile.day_night_profile`. The swap hook
      (`DayNightSceneController.set_profile`) is already wired and inert until then.
- [ ] **Couple fire to season.** Gate `FireManager` ignition on
      `profile.allows_fire` (Dry only); fold dry/wet into spread rates.
- [ ] **Climate ceiling.** `ClimateState` (viable frailejón altitude band creeps
      upslope each year); frailejones below band wilt then die (`&"climate"`).
      Surfaced on `year_changed`. The un-counterable pressure.

## Phase 1 tuning gate

- [ ] **Balance pass.** Shorten season length for the 30–45 min target (currently
      ~100 min at 4 days × 300 s × 5 seasons). Tune water economy so it doesn't
      snowball; tune climate so Year-1 plantings die by Year 3.

---

## Phase 2 — Resource triad & the political frame

- [ ] **Funding** resource (grant trickle, event cuts) via `ResourceLedger`.
- [ ] **Community Support** as a global modifier — and a real *input* (feeds
      threat spawn rate / legal odds), not just a HUD number.
- [ ] **Event system** — weighted per-season events (funding cut, partnership).

## Phase 3 — Threats: the things that climb

- [ ] **Tile health state machine** (Healthy→Stressed→Degraded→Barren→**Scarred**)
      with the permanent scar ceiling — "the land remembers" made mechanical.
- [ ] **Threat spawner** — season profiles, weighted timing, edge spawn, pathing
      toward objectives; climate-shift severity coefficient.
- [ ] **First threats:** invasive grass (quiet creep), illegal miners
      (fast/concentrated), one **legal mining op** (cannot be physically stopped —
      the rhetorical centerpiece).

## Phase 4 — Tools, personnel & the station

- [ ] Interaction tiers (Tier 1 field / Tier 2 station / Tier 3 radio),
      research-station node, planning-overview map.
- [ ] Rangers, legal team (probabilistic injunctions), monitoring stations,
      fences, trails, water channels, community educators. Each costs elsewhere.

## Phase 5 — Environmental pressure

- [ ] Dry spells, heavy rains + **erosion** on degraded tiles, deepen the climate
      escalation. Wire fire fully into season dryness.

## Phase 6 — Field-coordinator fantasy

- [ ] Fog-of-war with last-known-state caching, monitoring-station reveal radii,
      directional audio cues, radio-upgrade gate, alert/notification queue,
      player-following camera confirmed over `FreeCamera`.

## Phase 7 — Polish & rhetoric finish

- [ ] End screen that foregrounds loss (which frailejón field is gone, which
      downstream communities lost water), indigenous atmospheric presence,
      audio/music, damage visualization, scar textures.

---

## Critical path

Phases 1→3 are where it becomes a *game that argues*; 4–7 deepen and finish it.
Phases 1, 3, 5 carry the load-bearing rhetoric; 2, 4, 6 are enablers.

## Verification convention

Every increment: GUT tests for pure logic (run headless via
`addons/gut/gut_cmdln.gd`), plus a short headless launch to confirm no runtime
errors. New `class_name` types need `Godot --headless --import` before CLI tests
can resolve them.
