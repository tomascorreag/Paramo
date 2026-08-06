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
- **Bimodal year of `days_per_year` day/night cycles (N = 24).** Colombian Andes
  rainfall is bimodal (Urrea et al. 2019): two dry windows (~Dec-Feb, ~Jun-Aug)
  and two wet (~Mar-May, ~Sep-Nov), so the default `season_cycle` is
  Dry-Wet-Dry-Wet. `SeasonManager` counts `TimeManager.day_completed`; a season
  rolls every `days_per_year / season_cycle.size()` days (derived
  `days_per_season`, = 6 at N=24). The cycle length doubles as seasons-per-year
  and drives the year counter; a run is `season_count` = 4 seasons, i.e. exactly
  one year, so the year counter never advances during the slice's run. The day/night atmosphere is the season's texture.
  `days_per_year`, `season_count`, `seconds_per_game_day` are `@export` for the
  balance pass.
- **Fire is `FireManager` (autoload), not per-tile scenes.** Already implemented:
  ignition rolls, burn, 4-neighbour spread, grass→dirt burnout, rain coupling.
- **Extinguishing costs water; the water bucket is gone.** `ActionExtinguishFire`
  spends 1 water per burning cell doused, working outward from the clicked cell
  so a partial douse spends where the player aimed; the bucket state machine and
  fill action were removed.
- **Single accountant.** All water flows through
  `ResourceLedger.add/try_spend(id, amount, source)`; the per-source tally feeds
  the loss-naming end screen later.
- **Water accrues continuously, scaled by live rain** (`WaterCycle`), not at
  season boundaries. Deliberate relaxation of the ledger's season-quantized
  stance: the player cannot steer the weather, so there is nothing to
  per-second-optimize, and the reserve visibly filling during rain IS the
  mechanic. Player-steerable sources (frailejon yield, laguna seep) stay
  season-quantized.
- **No score.** The end screen names what was lost; it does not aggregate a
  score (GDD rhetoric).
- **Dryness is the simulation's spine** (`ClimateController`): one global [0,1]
  scalar — rain soaks it toward 0 fast, clear sky dries it toward the season's
  `dryness_equilibrium` slowly. Fire ignition multiplies by it. The climate
  ramp is per-SEASON (gentle ~5% rain decay + equilibrium drift), not the
  GDD's per-year band creep — the slice's run is one year, so per-year cannot
  fire; `ClimateState` altitude-band creep remains a Phase 1.5 item.
- **Tourism is abstract and quantized.** No tourist entities: `VisitorFlow`
  computes `visitors = base × (1 − day_avg_rain) × appeal` at each completed
  day and banks visitors × 5 tokens as ONE lump. Daily lump (not a trickle)
  because visitor income is player-steerable — the ledger doctrine's
  quantization rule applies, unlike weather-driven water.
- **Fire chars, char scares, rain heals** (`RegrowthManager`): burnout hands
  the pre-burn grass coord over `tile_burned`; charred cells roll daily
  recovery scaled by rain; the charred count drives visitor `appeal` toward 0.
  Sun pays and burns — drought is a payday loan, which is the loop's argument.
- **Everything placeable starts locked.** 10 tokens unlocks a type for the run
  (bought by clicking its swatch on the journal's right page), 5 more per
  placement (charged at commit, refunded on build failure). Locked actions are
  NOT offered in the wheel (`TileAction.unlock_id`); unlocked-but-broke ones
  dim (`is_enabled`). `starting_tokens = 15` = one unlock + one placement.

---

## Status — done this session

- [x] `SeasonManager` autoload — season clock, year, phase
      (`IDLE/ACTIVE/PLANNING/RUN_OVER`), `run_completed(reason)`. + tests.
- [x] `ResourceLedger` autoload — single accountant, source tally. + tests.
- [x] `SeasonProfile` resource + `dry.tres` / `wet.tres`.
- [x] `RunController` — starts the run after world generation
      (`ProceduralWorld.generation_finished`), debug readout, dev keys
      (F fast-forward, M end-season, N next-season).
- [x] Starting water pool seeded at run start (`SeasonManager.starting_water`,
      now 10.0 — was 100.0, which no run could ever spend).
- [x] Bucket logic removed. NOTE: this line previously also claimed
      extinguish-costs-water, which was never true — the bucket was deleted but
      the spend was never added, and `ActionExtinguishFire` documented itself as
      "a free, unlimited player verb" until the water pass below.
- [x] Season wheel in the HUD, rotating continuously with the season clock. + tests.

### Water pass

- [x] `WaterCycle` node (`gameplay_base.tscn`) — continuous accrual into the
      ledger, `base_per_game_day` always plus `rain_per_game_day_at_full` scaled
      by live rain intensity polled off `DayNightSceneController`. Banked on a
      0.5 s beat under `&"fog_capture"` / `&"rainfall"` so the breakdown survives
      for the end screen. + tests.
- [x] `ActionExtinguishFire` spends 1 water per cell doused, partial douses
      allowed, nearest-first. + tests.
- [x] `TileAction.is_enabled` + dimmed `RadialMenuItem` — an unaffordable action
      is shown greyed and swallows its click rather than disappearing.
- [x] Journal supplies list reads the live water balance
      (`FieldJournal` → `ResourceLedger.resource_changed` → `JournalInventory`).

### Simulation pass (weather ↔ water ↔ fire ↔ tourism ↔ tokens)

- [x] Dry/Wet `DayNightProfile`s authored and wired into the season .tres —
      weather now differs by season (dry: rain base 0.08, wet: 0.5). Visuals
      still identical between them; distinct looks remain Phase 1.5.
- [x] `ClimateController` — global dryness scalar, per-season climate ramp
      (rain-start probability scale pushed into `DayNightSceneController`,
      never by mutating the shared profile .tres), fire-ignition multiplier
      read by `FireManager` (group lookup, fallback 1.0). + tests.
- [x] `RegrowthManager` — char ledger fed by the widened `tile_burned(cell,
      grass_coord, grass_layer)` signal, rain-scaled daily recovery repainting
      the original grass variant, `appeal` factor for tourism. + tests.
- [x] `VisitorFlow` — abstract daily visitors, end-of-day token lump under
      `&"visitors"`. + tests.
- [x] `UnlockState` + `TileAction.unlock_id` — bridge/ladder/frailejon locked
      at run start, unlock 10 / placement 5 (commit-charged, failure-refunded),
      run-scoped reset. + tests.
- [x] Journal shop — the right page's known-set sections are buyable:
      `JournalShopInput` on BookHit resolves clicks by arithmetic (no viewport
      input forwarding), locked swatches fade via the ink shader's new `dim`
      uniform with the cost printed beside them. Journal money row renamed to
      the live `tokens`. + tests.
- [x] **Headless Monte Carlo balance simulator** (`scripts/tools/sim/`) —
      deterministic full runs of the real stack (paint-parity world, real
      FireManager/weather/economy via extracted `advance`/`tick`/`sim_tick`,
      `WeatherModel` shared by game + sim, per-subsystem seeded RNG) with a
      scripted player bot (douse/unlock/place, configurable noise), CSV out
      for pandas, scenario table. + determinism/step-duration/weather tests.
      First finding, before any tuning: at current fire rates an unfought dry
      day chars ~40% of the map, appeal hits 0 in every run, and even an
      optimal bot barely moves the outcome — fire needs a large nerf before
      the token economy can breathe.

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
      (alongside the season wheel). The `RunDebugLabel` is already retired — the
      journal's `RunCalendar` + season slot carry run progress now, so the year /
      resource readouts are what is still missing.

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
      ~96 min at 6 days × 240 s × 4 seasons). Tune water economy so it doesn't
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
