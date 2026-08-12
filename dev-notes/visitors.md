# Visitors

`...` = `"../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" --path .`

## Sheets and recolour

A visitor sheet ships **twice**: `Visitor_1.png` is the art, `Visitor_1_general.png`
is an **index** of it — every opaque texel rewritten as (which body part, which
shading rung) so `assets/shaders/visitor_recolor.gdshader` can paint a different
person per instance. The index sheet looks like a near-black silhouette in any
viewer; that is correct, it is data. The encoding lives in
`scripts/data/visitor_slots.gd` and is **mirrored by hand** into the shader
(GDScript consts cannot cross into GLSL).

**`index_character_sheet.gd`** does the rewrite — re-run after **any** repaint. An
unmapped colour is a hard failure with coordinates, which is the guard against a
repaint silently losing a body part.

```bash
... --headless --script res://scripts/tools/index_character_sheet.gd -- --in res://assets/sprites/characters/Visitor_1.png --out res://assets/sprites/characters/Visitor_1_general.png
... --headless --script res://scripts/tools/index_character_sheet.gd -- --in res://assets/sprites/characters/campesino.png --dry-run
```

Two visitor sheets ship (`VisitorAppearance.SHEETS`) and a spawning visitor rolls
one — a different **build**, not a different colourway. Recolouring alone gives a
crowd one silhouette in many outfits, which reads as a costume change rather than
as different people. Adding a third means indexing it and appending the path.
Both existing sheets happen to use the same 9 palette colours, so no schema
change was needed — check that with `--dry-run` before assuming it.
`test_visitor_palette.gd` asserts every listed sheet decodes cleanly and shares
the 24-frame rig (visitor.tscn authors `hframes` once, so a differently sized
sheet would silently play the wrong frames).

**`verify_visitor_palette.gd`** renders the index sheet through the shader and
diffs every pixel against the colours GDScript rolled. Run after touching the
shader, `visitor_slots.gd`, or `resources/characters/visitor_palette.tres`.
Needs a rendering context.

```bash
... --script res://scripts/tools/verify_visitor_palette.gd
```

- The `round()`-based decode **does** work: Godot's 2D path hands the shader the
  sampled texel untransformed, so R=32/255 reads back as 32/255. Verified across
  8 rolls, alpha included.
- The encoding's spacing is load-bearing **slack**, not decoration. Moving
  `STEP_G_BASE` by a whole 32 units still decodes (the `round()` absorbs it);
  moving `SLOT_R_STEP` from 32 to 64 fails 5308 texels. A passing run is proof
  the constants match *closely enough*, not exactly.
- The sampler **must** be nearest. A linear filter averages two slots' index
  values at every silhouette edge and decodes the blend as a third body part.

## Looking at them — `scripts/tools/preview_visitor_palettes.gd`

Two phases answering two questions. Needs a rendering context.

```bash
# wardrobe: rolled variants x 4 facings on the darkest bed
... --script res://scripts/tools/preview_visitor_palettes.gd -- --out /tmp/visitors
# rig: a real map, crowd walking — y-sorting, shadows, walk cycle, entry cell
... --script res://scripts/tools/preview_visitor_palettes.gd -- --out /tmp/visitors --world --count 6
# behaviour: route noise, breathers, party spacing only show over a long walk
... --script res://scripts/tools/preview_visitor_palettes.gd -- --out /tmp/visitors --world --count 10 --groups --frames 1600
# where traffic concentrates (trample rate forced; the SHAPE is the answer, not the rate)
... --script res://scripts/tools/preview_visitor_palettes.gd -- --out /tmp/visitors --world --count 12 --groups --frames 2400 --trample 0.34
```

`--world` defaults to 200 frames, which shows the rig but not the behaviour — at
200 frames everyone is still within two cells of the entry, so route noise,
breathers and party spacing all look broken. At 1600 frames the crowd spreads
over the whole mountain across five altitudes. Trampling is invisible to any
still at the shipped rate (~15 crossings to go bare, i.e. days of game time), so
`--trample` overrides it; the tool also prints bare cells + total grass worn,
the only way to see partial wear the art cannot show.

## Architecture

`VisitorFlow` is the **economy** (a day → an arrival count → tokens, no entity
involved); `VisitorSpawner` is the **bodies**. Both are in `sim_runner`'s
`_SYSTEM_DEFS` — the sim used to skip the spawner because visitors were pure
presentation, but a footfall costs vegetation, so it walks them for real. Three
things make that safe, all on the spawner: `tick(delta)` (a sim run has
`_process` disabled), `despawn_all` on `_exit_tree` (visitors are parented to the
**world** and would survive into the next run), and `anchor_cell_override` (the
sim's player is a RefCounted bot that cannot join the `player` group).

The spawner drives its crowd's `tick` in the game too, and each visitor's own
`_process` is switched off at spawn — not a headless special case: it gives the
crowd a defined update **order**, which matters the moment two visitors can
trample the same cell in one frame.

### Layering — where a second kind of walker would plug in

| layer | contents |
|---|---|
| `GridWalker` | locomotion + rig. **No behaviour** — walks a path it is handed, reports arrival. Both characters take it; a deer or a miner would too. Rig is per-instance (`walk_frames_per_dir`, `walk_fps`). |
| `Visitor` | ~700 lines, ~a fifth reusable: goal selection from a reachable set, route noise, `nearest_reachable` + the deferred `graph_changed` re-path, per-cell trample reporting. |
| tourism | what must **not** be dragged along: `VisitorParty`, `VisitorStanding`, opening hours, the linger/fade lifecycle, the `VisitorFlow` coupling. |

The trap is not the base class — it is that `Visitor` is the only worked example
of an autonomous walker, so copying it wholesale inherits parties and opening
hours for an animal. Extract the middle layer when the **second** one exists;
there is no fauna or threat entity in the repo and no spec for one.

Single inheritance does block one thing: an entity wanting the
altitude/shadow/y-sort rig **without** grid stepping (a bird, drifting smoke) has
to take path-following too. Cheap to split — the rig is contained in
`_apply_visual_lift`, `_write_sprite_frame`, `_set_facing`, `_advance_anim`.

`GridWalker` is `scripts/player.gd`'s movement core with the player-specific parts
(camera, opening pan, lantern, shadow cutoff, footsteps) left behind. **Player is
not built on it yet, so the step math exists in both files** — a fix to the
interpolation belongs in both until Player is migrated.

## Appearance

- **A variant is a window into a ramp**, not a hand-picked pair of tones. Each
  `VisitorRamp` is a whole dark→light gradient; a roll picks (ramp, top) and the
  shaded rung is `stops[top-1]` clamped. Choosing the darkest stop as the base
  therefore collapses shading onto it with no special case, and the same formula
  extends to 3-rung art with no schema change.
- Ramps are authored stop by stop from palette2 and **shared across slots** (one
  "brown" serves hair and shoes). `test_visitor_palette.gd` guards that every stop
  is a palette entry and each ramp is monotonic in luminance — an inverted ramp
  lights the shadows and reads as the sprite being inside out.
- **Rarity is a ratio, not a percentage** (`VisitorRamp.weight`, default 1.0,
  rolled by `VisitorPalette.pick_ramp`). Weights are normalised by their sum
  within a slot, so 3:1 and 6:2 are the same — which lets a ramp be added or
  removed without re-normalising everything else. 0 parks a ramp without deleting
  it; an all-zero slot falls back to uniform (a wrong colour on screen sends you
  to the data, magenta sends you to the shader).
- The weight travels with the **sub-resource**, so it applies in every slot the
  ramp appears in. Shipped weights therefore only touch ramps unique to one slot
  (hair black/auburn/blond, skin warm). For per-slot rarity on a shared colour,
  split it into its own sub-resource; a parallel weights array on `VisitorPalette`
  was rejected because it must stay index-aligned by hand.
- `test_visitor_palette.gd` asserts every shipped ramp has weight > 0 — an
  authored, palette-checked ramp that can never roll is invisible dead data.
- **Both ShaderMaterials in visitor.tscn are `resource_local_to_scene`.** A
  `.tscn`'s sub-resources are shared between instances, and both carry
  per-visitor state: the recolour's `slot_colors` (the whole crowd takes the last
  roll) and the shadow's `visual_y_offset` (every shadow sits at the last
  visitor's altitude). The player never needed this because there is only one.

## Entry, goals, routing

- There is **no trailhead concept** and the playable area is a **disc**, so the
  entry point is derived: the southernmost cell of the landmass connected to the
  player's start, tie-broken toward the bounds' x-centre. Taking it from the
  player's reachable set is what stops it landing on an island.
  `entry_cell_override` exists for a map that wants a specific one.
- Goals are sampled **from** that reachable set, so reachability is a property of
  the draw rather than something checked afterwards. `Visitor.nearest_reachable`
  covers the case a spawn-time check cannot: the graph changing mid-walk.
- The spawner treats a **fresh** `TileGrid` instance as "the world was rebuilt"
  and sends its crowd home; an edit in place only refreshes the cached reachable
  set. Visitors deliberately never join the `procedural_object` group —
  `ObjectPainter._clear_existing` frees group members under World, which would
  free a visitor mid-step and orphan its world-reparented shadow.
- **Route noise is applied to waypoints, never to the path.** Visitor cuts the
  straight line into 1..N points, scatters each, and re-joins them with
  `find_path` — so every step is still a real pathfinder result and no wandering
  visitor can cross a fence or a gap. Perturbing the path itself would have
  neither property.
- The noise is drawn at **two scales**, and the split is what makes a party read
  as a party. The **spawner** draws one set of waypoints per group
  (`_draw_group_route` → `Visitor.draw_route_anchors`, at `wander_radius_cells`)
  along with the group's one shared goal; each member re-scatters around those at
  the much smaller `member_wander_radius_cells`. So parties differ by a whole
  trail, members by a cell or two, and a group of five costs **one** route draw.
  The anchors array is shared **by reference** — `Visitor._anchors_for`
  duplicates before reversing it for the walk home, and must keep doing so.
- **Waypoints are also stops** (`waypoint_pause_min/_max`, unconditional — not the
  `rest_chance_per_step` roll). It explains the detour (someone walked over there
  to look at something), and it is now the **only** thing desynchronising a party
  since members share a route and a near-identical pace. Set the pause to zero and
  a party collapses into one stack of sprites.
- The regrowth group name in `visitor.gd` is a **literal**, not
  `RegrowthManager.GROUP`, and must stay one. Naming the class makes
  `regrowth_manager.gd` a compile-time dependency, it references three autoloads,
  and the whole chain then fails to compile inside a `--script` tool — which does
  not crash the tool, it silently unbinds this script so visitors trample air.

## Parties

- **A party regroups at every waypoint** (`VisitorParty.regroup_at_waypoints`): a
  member that arrives stands there until the rest reach the same waypoint. This is
  the only mechanism that cancels the **spawn stagger** — members enter
  `group_member_stagger_seconds` apart on one trail at one pace, so the last in is
  permanently 3-4 cells behind. Measured on the world preview: a 4-person party
  went from strung across 8 cells to inside 3.
- **The regroup cannot deadlock**, via two mechanisms. `member_left` shrinks the
  party (despawn, `begin_leaving`, `send_home`, a goal relocated by
  `nearest_reachable`, a route that fell back to `_direct_path` with no waypoints)
  — the tidy path. The load-bearing one is `Visitor.regroup_timeout_seconds`,
  checked on the **waiting** member, which releases it regardless of what the
  party thinks. Only the second covers a drop-out route nobody anticipated, and
  the failure it prevents — a visitor standing still forever, in view — is the
  worst thing this feature could ship.
- The walk home reuses the same waypoints **reversed**, so its barriers live in a
  separate index space (`_RETURN_LEG_INDEX_BASE`). Releases are **latched** (a
  straggler must not block on a barrier the party has passed), so sharing keys
  across the two legs would silently open every barrier on the way home.
- The hold **re-arms the ordinary pause** each frame rather than touching the
  path: `GridWalker` only steps when its pause has run out, so a topped-up pause
  *is* a hold and inherits the step-boundary guarantee free.
- On release each member waits a further `0..regroup_release_spread`. Without it
  the party departs on one frame at one pace along near-identical routes — the
  stack the regroup was supposed to look better than. The barrier converts
  accumulated spread to zero; something has to put a little back.
- **No two visitors stand on one tile** (`VisitorStanding`). Every waypoint and
  goal-side standing cell is reserved at route-**build** time, not on arrival: a
  waypoint sits mid-route, so shuffling aside on arrival would mean rewriting the
  tail of a queued path. The party shares one `goal_cell`, so without this a whole
  party lingers on one tile. `reserve_near` rings outward when the disc is full,
  doubles as the per-member scatter (the pick within a ring is random, not
  nearest-first), and falls back to the anchor when even widened rings are full —
  overlapping beats not walking.
- It governs where visitors **stop**, not every cell they cross. Two walkers in
  transit still overlap for a step. Reserving along a **path** would fix it and
  turns two walkers meeting in a one-cell gap into a deadlock needing a
  yield/repath protocol. A frozen crowd is worse than a momentary overlap.
- `VisitorStanding` is **not** `TileGrid.set_occupant` — that registry decides
  walkability and would make a resting visitor block pathfinding for everyone.
- The registry is **static** (exclusion spans parties; tools/tests build visitors
  with no spawner), which costs two things: every read validates its claimant with
  `is_instance_valid` so a freed visitor cannot block a cell forever, and
  `despawn_all` + test `before_each` must call `clear()`. `despawn_all` uses
  `free()`, not `queue_free`, so `_exit_tree` never runs.

## Pace and animation

- **Pace is authored as a fraction of the player's speed**
  (`pace_fraction_min/_max`, 0.5..0.75), not as seconds per cell — the requirement
  is relative, and speed is the **reciprocal** of a step duration, so the two ends
  swap when you convert. A group draws one fraction; members jitter around it and
  the result is clamped to `MAX_PACE_FRACTION` (0.9), which makes "no visitor
  outpaces the player" structural. `VisitorSpawner.PLAYER_STEP_DURATION` mirrors
  the player's speed **by hand**, and mirrors the *shipped* one —
  `scenes/entities/player.tscn`'s 0.6 override, **not** `player.gd`'s 0.45 default.
  Move it when the override moves.
- Being slower is not enough: the walk cycle ticks at a fixed `WALK_FPS` whatever
  a step costs, so a slow walker **glides**. `GridWalker.frame_hold_chance` rolls
  per animation tick whether to repeat the current frame, which is why the cycle
  is counted (`_anim_index`) rather than derived from elapsed time — a frame index
  recomputed every frame cannot remember that it held. It is tuned well **below**
  the physically-matching value (`max_frame_hold_chance` 0.12, where half speed
  would want 0.5), because a random repeat at a high rate reads as the sprite
  stuttering. Judge it in motion.
- A **breather** is rolled per **step**, not on a timer, so a slow visitor does
  not also stop more often; `GridWalker.pause_movement` holds it to a step
  **boundary** — a walker frozen mid-stride stands on the join between two tiles.
- Per-visitor **pace jitter** used to do two jobs and now does one. Six visitors
  spawned in one frame share the opening stretch of route and stayed stacked on a
  single cell for the whole climb, which reads as one sprite with a rendering bug.
  Separation has since moved to the **waypoint stops**, which freed
  `group_pace_spread` down to 0.02 and actually delivers "a party walks at the
  same speed". Take the pauses out and the pace spread must go back.

## Opening hours

- Opening hours gate arrivals but never **drop** them. `VisitorFlow` banks the
  day's count at the midnight boundary, so a spawner that discarded arrivals
  outside its window would discard every visitor the game produces; the queue
  waits for opening instead. The window survives wrapping past midnight, so a
  night trail is a retune rather than a special case.
- **At closing** nobody new is let in and everyone still out **walks** to the
  trailhead — `Visitor.send_home`, which paths to the entry cell, **not**
  `begin_leaving`, which is the terminal fade. Getting that backwards is what the
  code did until 2026-08-09: the whole crowd stopped where it stood and dissolved
  in 0.6s at 17:00 while both files' comments claimed a walk home. The two are
  separate methods because `begin_leaving` is for when walking is **impossible**
  (a regenerated world, a visitor walled in), and `send_home` falls back to it in
  exactly those cases. Departing visitors keep their `_live` slot until they reach
  the entry, which costs nothing since `max_concurrent` only gates arrivals.

## graph_changed: the one real performance cliff

**The response is deferred and conditional at both ends.** A fence **run** emits
`graph_changed` once **per tile** inside a single frame. Both the spawner
(`_reach_dirty`) and each Visitor (`_graph_dirty`) only set a flag in the handler
and do the work at the top of their next tick — so twenty tiles cost one
response. The spawner refreshes **before** it ticks the crowd, so a visitor
relocating a goal sees the new reachable set.

A visitor's deferred response starts with `GridWalker.path_is_valid()` and
re-routes **only** if its queued path actually broke (12 ms vs 0.09 ms). The
behaviour is better too: an unconditional re-route re-rolled the route noise,
released and re-took every standing cell, and could drop the member out of its
party — so a fence on the far side of the mountain visibly reshuffled a crowd
that should have ignored it. A **lingering** visitor is skipped outright; the old
code re-pathed it toward the entry mid-linger, starting the walk home early on
any unrelated change.

**Anything hanging off `graph_changed` must stay O(1) per frame, not per signal.**

## Balance results (paired seeds)

Read anything downstream of fire with 12+ **paired** seeds — at 8 seeds the same
comparison handed back a significant-looking result with a plausible mechanism
attached, and it was noise.

- Deferred/conditional re-routing, 16 paired seeds: balance-neutral.
  `grass_frac_end` +0.00 (t=0.0), `charred_end` +25 (t=0.7), `fires_ignited` +21
  (t=0.3), `tokens_final` −0.9 (t=−0.7).
- Shared party waypoints, 12 paired seeds: nothing ecological moved
  (`fires_ignited` +13, `charred_end` +15, `grass_frac_end` +0.02, all inside
  noise). Only `visitors_walked` +1.8 (t=2.5) carrying `tokens_final` +3.3
  (t=2.4) — ~2 more visitors per run because a member no longer re-rolls its own
  goal and can no longer fail to find one. Concentrating a party's footfall onto
  one trail did **not** measurably sharpen the wear.
- Regroup, 12 paired seeds: `grass_frac_end` +0.01, `charred_end` +45,
  `tokens_final` −1.7 (t=−1.3 — a held member occupies a `max_concurrent` slot
  longer). The one significant move is `charred_cell_days` +667 (t=3.2), with a
  plausible mechanism: bunched parties trample **fewer distinct** cells (world
  preview: 12 bare vs 19), and bare cells are firebreaks.
- Route noise (`defaults` vs `no_wander`), 16 paired seeds: roughly neutral, one
  clear effect on **fire** — removing it raises `fires_ignited` by 210 (t=2.9);
  grass +0.05 (t=1.9) and tokens +1.4 (t=0.9) inside noise. Same firebreak
  mechanism. So route noise pays for itself in firebreaks, which is a statement
  about fire being overtuned rather than a reason to keep it — its actual
  justification is visual.
- Two scenarios price the features: `no_wander` (`wander_chance` 0) removes the
  route noise (the most expensive thing a visitor does per body — every waypoint
  is another A* on spawn and on every re-route) and takes the waypoint stops and
  regroups with it; `no_regroup` isolates the barrier from the noise it rides on.

**Do not price any of this off the sim's wall clock.** Across four 16-seed sweeps
on one machine, defaults ran 338.9 s, 379.8 s and 338.3 s — the same arm varied
12% between slots, swamping every visitor-side effect and pointing whichever way
the machine drifted. Arms run sequentially, so drift maps entirely onto the arm
and `sim_ms` looks paired when it is not. Use `benchmark_visitors.gd`, which
interleaves implementations inside one process.

Every knob is an `@export` on `VisitorSpawner`, in Inspector groups named for the
question they answer (Groups / Pace / Opening hours / Wandering). **Re-run the
simulator after changing any of them** — feet wear grass, grass is appeal, appeal
is tomorrow's arrivals.

## The cost-field routing idea: measured and REJECTED — do not rebuild it

Two measurements frame it.

**"The shortest path between two cells is unique" is FALSE** (visitor.gd's header
used to assert it): it is unique only because Pathfinder's A* breaks equal-f ties
on a FIFO counter. Measured on level1, 39 routes / 1051 steps with the real
per-step costs: 24% of steps have an equal-cost neighbour, mean branching 1.24. So
the shortest-path corridor is already a couple of cells wide, and a **randomised
tie-break** spreads walkers across it at zero cost — the same scale as
`member_wander_radius_cells` (1), i.e. the whole per-member scatter.

**The cost field loses anyway.** `benchmark_visitors.gd`'s routing phase, level1,
legs sampled at the real waypoint spacing (~4 cells): one A* = 2.3 ms, one
heap-Dijkstra field = 18.6 ms — 8x a single A*, and the field loses at every
party size (M=1 0.12x, M=3 0.37x, M=5 0.60x). A*'s cost scales with **leg
length**, a field's with **reachable-set size**, and the legs are ~4 cells across
a ~450-cell disc. (Sampling random cross-map pairs instead of real legs put A* at
8.3 ms and made the field look like a 2.5x win at M=5 — the sample was measuring
itself.) Re-measured after `find_path` got its edge cache: A* 1.4 ms, field
22.5 ms; the verdict only got firmer.

Note which way this scales: on a **bigger** map the field gets **worse**, since
field cost grows with the reachable set while a leg stays ~4 cells.

"A field is per map change, not per party" is the right mechanism and still
doesn't pay. A field is keyed to a **target**, so it survives only if the target
comes round again — today's never do (`_pick_goal` samples uniformly from ~450
cells), so across ~32 parties per run the expected number of repeated goals is
about one. Amortising needs goals drawn from a **small reused set** (landmarks) —
a game-design change. And even then: ~660 ms of routing per run (96 visitors × 3
legs × 2.3 ms) against ~14 graph changes, so break-even is ~33 field builds a
run, i.e. K × G ≤ 33; at G = 14 that allows K = 2.4 distinct live targets. Two
landmarks is not a game.

The only version that would work is **incremental repair** (D*Lite and friends),
which is a lot of machinery for a system whose entire routing bill is ~660 ms
across a 24-day run (~0.03 ms/frame). And routing is no longer an **aggregate**
problem — it is a **spike** problem, and the spike (the fence run) is fixed.
Fields trade a spread-out 2.3 ms cost for a lumpy 18.6 ms one, the wrong
direction for the only symptom that was ever visible.

What survives is **only the randomised tie-break**, and it is a **look** change,
not a perf one: every member still runs its own A* per leg. What it would buy is
dropping the per-member waypoint scatter (and its `VisitorStanding` reservations)
while keeping members visually apart. The perf lever is, and stays, not
re-routing at all unless the path actually broke.
