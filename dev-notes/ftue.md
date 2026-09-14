# FTUE — the first fifteen minutes

The opening of a run: what time the day starts, what the world is allowed to do
on that first day, and the hint strip that frames the run in narrative and
teaches the verbs.

Everything here is in `scripts/ui/tutorial_controller.gd`, plus three small
concessions in systems it depends on.

## The shape

| Step | id | Copy key | Advances on |
|---|---|---|---|
| 1 | `welcome` | `NARRATIVE_WELCOME` | dwell, or any key/click |
| 2 | `charge` | `NARRATIVE_CHARGE` | dwell, or any key/click |
| 3 | `move` | `TUTORIAL_MOVE` | `ClickToMoveController.path_dispatched`, **twice** |
| 4 | `discover` | `TUTORIAL_DISCOVER_FRAILEJON` | `FloraCodex.discovered` with an Espeletia (skipped if one is known) |
| 5 | `journal` | `TUTORIAL_JOURNAL` | `FieldJournal.opened` |
| 6 | `bitacora` | `TUTORIAL_BITACORA` | `FieldJournal.spread_changed` to `bitacora` (skipped if already there) |
| 7 | `shop` | `TUTORIAL_SHOP_FRAILEJON` | `UnlockState.unlock_changed` with the frailejón |
| 8 | `close_journal` | `TUTORIAL_CLOSE_JOURNAL` | `FieldJournal.closed` |
| 9 | `build` | `TUTORIAL_BUILD_<species>` | `UnlockState.placement_paid` (or `placement_began`) |
| 10 | `discover_more` | `TUTORIAL_DISCOVER_MORE` | `FloraCodex.discovered`, any species (skipped if two are known) |
| 11 | `shop_ladder` | `TUTORIAL_SHOP_LADDER` | `UnlockState.unlock_changed` with the ladder |
| 12 | `close_journal_ladder` | `TUTORIAL_CLOSE_JOURNAL` | `FieldJournal.closed` |
| 13 | `build_ladder` | `TUTORIAL_BUILD_LADDER` | `TraversalPlacementController.placement_began`, or `UnlockState.placement_paid` |
| 14 | `build_endpoint` | `TUTORIAL_ENDPOINT_LADDER` | `UnlockState.placement_paid` (skipped unless a placement is open) |
| 15 | `roam` | *(no copy — the strip is gone)* | a fixed `_ROAM_SECONDS` (12) hold |
| 16 | `fire_follow` | `TUTORIAL_FIRE_FOLLOW` | **polled**: the fire's cell entering the frame |
| 17 | `fire_douse` | `TUTORIAL_FIRE_DOUSE` | `FireManager.tile_extinguished`, or `tile_burned` on that cell |
| 18 | `closing` | `NARRATIVE_CLOSING` | dwell, or any key/click |

**The ladder half is disabled (2026-09-14).** Steps 11–13 carry `"disabled": true`: `_step_applies` steps over them and `_granted_mask` / `_granted_purchases` ignore their `grants` / `sells`, so the ladder never goes on sale during the FTUE. `build_endpoint` skips itself too, since no placement can be open. The copy, wiring and tests stay; remove the flag to restore. The 25-token opening balance was priced for the ladder and now leaves 14 spare.

**Discovery comes before building (2026-09-14).** Discovery gates the shop, so the loop taught first is the one every later purchase goes through: identify a frailejón, read its page in the bitácora (whose tab only exists once something is identified), buy it on the resources page, plant it. Then an open objective (identify any second species, grasses included) says what discovery is for, and only then the ladder, which is the old FTUE's build half with its second-click step. Steps that repeat a verb share its completion wiring through a `"kind"` on the step (`discover_more` is kind `discover`, `shop_ladder` kind `shop`, …), because ids must stay unique; `test_tutorial.gd` asserts every kind names wiring that exists.

**The first right click opens a menu with one entry.** `TutorialGate.Action.INSPECT` is granted by `discover`, and `TileInteractionController` opens the tile menu when INSPECT *or* BUILD is allowed, filtering it down to `inspect` while BUILD is still withheld. Without the filter the step that teaches identifying also teaches removing a rock.

**The shop sells the shopping list and nothing else.** A step can carry `"sells"` (cumulative, like `"grants"`; `_FRAILEJON` expands to every registered Espeletia, of which the mountain sells one) and `_show_step` passes the union to `TutorialGate.restrict_purchases`. `JournalShopInput` asks `TutorialGate.allows_purchase(id)` at the hover and at the buy. The reason is money: the run opens with 25 tokens and the list is 23 (frailejón 10 + 1 tile, ladder 10 + 2 tiles), with income only at day end. A player who bought a chite on the way would reach the ladder step unable to finish it. `release()` lifts the list with the rest of the gate.

**A frailejón is guaranteed near the spawn.** level1's seed is random and the scatter gives ~33 frailejón cells a map, none promised nearby, so step 4 could point at nothing. `ObjectPainter.ensure_flagship_near(ctx, spawn)` runs between `begin_spawn` (which rolls the kinds) and the spawn rows: it takes the nearest Espeletia already within `FLAGSHIP_RADIUS` (5) cells on the spawn's altitude or, with none, flags the nearest open or grass cell at `FLAGSHIP_MIN_DISTANCE` (2) or more with the mountain's own species (`flagship_species`: its first plantable Espeletia). Either way it records the cell in `ctx["mature"]` so `_spawn_row` spawns it at its last growth stage (a sprout is a few texels; its stage draw is still consumed). **MEASURED 2026-09-14**, 40 seeds on level1's terrain params through `SimWorld`, all three ecosystems: 40/40 had a mature frailejón within 5 cells, reachable from the spawn; 4 of them at ring 5. Two things follow from where it sits:

- **The spawn is picked once, before the guarantee.** `_find_starting_cell` reads object flags; the new flag can shrink the chosen plateau and move a re-run pick. `ProceduralWorld._ensure_flagship` stores the pick in `_start_cell` and `_place_player_on_walkable` reuses it.
- **`SimWorld` makes the same calls in the same order**, so the game and the sim still agree per seed. But the extra plant and its rng draw shift growth stages and rock variants after it, so a before/after sim pair across this change is not paired.

**No line leaves the screen inside `_MIN_ON_SCREEN` (2.5s)**, however fast it is
satisfied. Several steps can be completed by an action already in flight — a
click landing mid-fade dispatches a path, a key held over from the previous step
opens the journal — and the narrative can be clicked through; without the floor
a line appears and vanishes inside a few frames and reads as a flicker. A step
completed early disconnects its signal immediately (so it can't complete twice)
and parks in `_completion_pending` until the floor elapses. It sits just above
`_DWELL_FLOOR` (2.4), so the shortest narrative line is paced by the floor rather
than by its own reading time; the test caps it at `_DWELL_CEILING` so it can
never pace a long one.

**`"repeat": 2` on the move step.** One dispatched path is often a mis-click or
a one-tile nudge; the second is where the ground reads as a destination. The
count lives in the step table (`_step_progress` against `"repeat"`, default 1)
rather than in `_on_moved`, so any step can ask for more than one of its own
signal.

**A third opening line (`NARRATIVE_SEASONS`, "ten seasons stand between today
and the rains") was cut 2026-08-14** — three panels of prose before the player
is allowed to touch anything was too long a hold, and the seasons count is
legible from the journal's calendar page anyway.

### The narrative bracket

Three lines in the park's voice: two that open the run (this land and what its
water is, then what you were sent to do) and one that closes the tutorial. They
**bracket** the instructions rather than interleave with them —
prose between two things the player is being asked to do reads as an
interruption. `test_tutorial.gd` asserts that shape rather than the exact list,
so lines can be added at either end but not into the middle.

A narrative step is `{"narrative": true}` in `_STEPS` and is the one kind of step
with **no completion signal** — there is no action to report. It advances on a
dwell of `2.4 s + 0.05 s per character of the translated line` (clamped to 8),
which is per-character so the ~25% longer Spanish gets proportionally longer to
read, and on any key or mouse press, which does **not** consume the event: the
click that ends the last narrative line is also the click that starts the walk
the next step asks for. The dwell timer is bound to the step index that started
it, so one that outlives its step (player clicked through) can't complete
whatever is up when it lands.

They are the only copy in the project written in **sentence case**. CLAUDE.md's
lowercase convention covers chrome; in-world narrative is explicitly out of its
scope, and the `NARRATIVE_` prefix is what marks the exemption — both
`test_localization.gd` and `test_tutorial.gd` skip the lowercase assertion for
that prefix and nothing else.

Step 7 exists because the open book covers the screen and every way out of it
(Space again, Esc, a click on the scrim) is invisible — the one thing here a
player cannot discover by looking.

Step 7's line is picked per bought type from `_BUILD_KEYS`
(`TUTORIAL_BUILD_LADDER`, `..._BRIDGE`, `..._FENCE`, `..._FRAILEJON`), with the
generic `TUTORIAL_BUILD` as fallback. "right click a tile" teaches nothing about
a thing the player has never seen, so each line says what the thing is FOR and
where it goes — the ladder's names the two-block ledge it climbs.
`test_tutorial.gd` asserts every id on sale in the journal has a line.

### The second click has its own step

A ladder, a bridge and a fence are all **two** clicks. The right click of step 7
only opens the ring; picking the tool from it calls
`TileInteractionController.begin_traversal` → `TraversalPlacementController.begin`,
which enters `AWAITING_ENDPOINT` and waits for a LEFT click on a far cell. The
player is left holding a half-built thing with a ghost following the cursor and
x marks on the legal cells, and nothing on screen says what to do with them.

So step 7 **ends when the placement opens**, not when something gets built, and
step 8 asks for the second click. Concretely:

- Step 7 connects **two** completion signals and takes whichever fires first —
  `placement_began` (a traversal opened its second click; nothing paid yet) or
  `placement_paid` (a frailejon, which is planted by the ring pick itself and
  never opens one). `_complete_step` disconnects both.
- Step 8 carries `"placement_only": true`. `_show_step` skips any step whose
  `_step_applies()` is false — read off `TraversalPlacementController.is_placing()`,
  the live state, not off `_bought_type` — so the frailejon path steps straight
  over it into the closing narrative. Skipping is a loop, not recursion, so a
  table of nothing but inapplicable steps ends the FTUE rather than the stack.
- Its copy comes from `_ENDPOINT_KEYS` (ladder / bridge / fence only), each line
  saying what the x marks MEAN for that structure — the ladder's are landings on
  top of the ledge, the bridge's the far bank, the fence's the end of the run.
- **Escape or a right click drops the placement without building.** Step 8 then
  rewinds to step 7 (`_on_placement_ended` → `_show_step(_step - 1)`) rather than
  waiting forever on a click the player can no longer make.
- **The placement opens from anywhere, and the walk comes after the aim** (2026-09-12). The build actions carry `TileAction.executes_from_afar`, so picking one on a far tile enters `AWAITING_ENDPOINT` at once. A valid second click either builds on the spot (player already beside the origin) or enters `APPROACHING`: the ghost stays, the player walks to a cell beside the origin that the validator will accept them on (never inside a fence run or a bridge span), and the traversal is re-validated, **charged** and built on arrival. `is_placing()` is true in both modes, so step 8 stays up during the walk and `placement_paid` still completes it, just later. Right click / Escape stop the walk and cancel; a left-click move cancels through `ClickToMoveController.path_dispatched`; both emit `placement_ended(built = false)`, so step 8 rewinds as above.

That rewind is why `TraversalPlacementController` gained **two** signals rather
than one. `cancel()` is its single teardown for success, cancellation AND
rejection alike, so `placement_ended` carries a `built` flag (set from
`_pay_placements`) — without it, a finished ladder and an abandoned one are the
same event. On the success path `placement_paid` fires first, inside the same
click, so step 8 has already completed and disconnected by the time
`placement_ended(built = true)` goes out.

**Removed 2026-08-13:** a pulsing 1px outline that marked what to click (the
journal button, the open shop page, a target cell) — recomputed per frame from
the live rect so it tracked the camera, the player and the book's rise. Cut as
noise: the lines are short enough to be unambiguous, and a rectangle chasing the
cursor competes with the world it is pointing into. It took
`UXOverlay.cell_visual_center`, the reachable-ring target search and four peer
lookups with it.

The order of the instruction steps is load-bearing, and `tests/test_tutorial.gd`
asserts it (after filtering the narrative out): the shop step is only doable
inside the journal the step before it opened, and the build step is only doable
with the tool the shop step bought, in a world the close step got back to — and
the second-click step is only doable inside the placement the build step opened.
The fire arc runs last because it is the only part that needs the player already
able to walk away, and inside it the order is the whole lesson: the strip has to
be gone before the fire starts (or the player learns that fires are announced),
and the fire has to be found before it can be put out (or the aura teaches
nothing).

## The fire arc (steps 9-11)

Steps 1-8 describe the game. The arc is the FTUE **acting on the world**: it
goes quiet, lets a fire start where the player cannot see it, and teaches the
last verb by making them go and put it out.

It exists because the douse is the one thing in the slice a player can lose the
run to without ever having been shown it, and because the game already carries
an off-screen fire indicator — `FireAuraOverlay`, a warm glow baked into the
screen edge in the bearing of any fire outside the frame — that nothing in the
run ever introduces. The arc is one scripted meeting with it.

### The quiet beat

Step 9 has **no copy at all**, and that is its content. `"quiet": true` fades the
strip away and leaves it away for 12 s; the skip button stays. An FTUE that
never lets go teaches the player to wait for the next line rather than to look at
the world — and the aura only works on a player who has stopped watching the
bottom of the screen. It is also what buys the arc its distance: the fire is lit
relative to where the player wandered to, not to where the build step left them.

`_arm_step_timer` is the narrative dwell's timer, factored out. Both are bound to
the step INDEX for the same reason.

### Where the fire is lit

**Changed 2026-09-14: the pick is by WALK, not by screen distance.** The old rule (reachable, and closest to 0.35 screen-heights off the edge) lit fires across rivers and across the map: reachable only says a walk exists, and a cell just over the water is reachable by a bridge thirty steps upstream. Now `_pick_fire_cell` asks `Pathfinder.walk_costs_from(player, _FIRE_MAX_WALK = 30)` (a bounded Dijkstra over the same edges and costs `find_path` uses) and `_rank_fire_cells` (pure, tested without a viewport) takes, among candidates that are

- **burnable** — `FireManager.can_ignite`, so never water, rock or dirt,
- at least `_FIRE_MIN_CELLS` (4) away,
- **not a detour** — walk cost ≤ `_FIRE_MAX_DETOUR` (2) × Chebyshev distance, which is the river rule,

the **cheapest walk** inside the off-screen band [0.10, 0.60] (`sd`, the same signed metric `FireAuraOverlay` shapes its glow with; ties to the smaller `sd`). In practice that is a fire just past the edge in the direction the terrain lets the player go straight. If the band is empty the cheapest non-detour walk at all is taken, on screen or not. The old fallback, the FARTHEST burnable cell, is gone: it was the across-the-map fire.

The band's rationale below still holds; the 0.35 target no longer exists.

**0.60 is the load-bearing number: the aura's `REACH` is 0.9, past which a fire
contributes nothing to the strip at all.** A fire lit beyond it is a line telling
the player to follow a glow that is not being drawn. `test_tutorial.gd` asserts
the max stays under `FireAuraOverlay.REACH`.

If the band is empty (a wide window, a player standing at the edge of the
mountain) the search **widens to the farthest burnable reachable cell there is**,
even an on-screen one. If that finds nothing either, `_fire_cell` stays `NO_CELL`
and both fire steps skip themselves — `"fire_only"`, the same mechanism
`"placement_only"` uses — and the FTUE closes exactly as it did before the arc
existed.

**MEASURED 2026-08-17** (`level1`, 686 reachable cells, 1920×1080 → 360×202
logical): the pick took 2.9 ms plus a **27 ms cold `reachable_from`**. That flood
fill is not new — `tile_interaction_controller.gd:250` pays the same one on every
right-click from a cell it hasn't cached, so this is the hitch normal play
already has, moved into a fade where nothing is expected of the player. It lands
once.

### Two concessions in FireManager

Both are optional arguments on the public `ignite(cell, contained, fuel)`,
unreachable from the natural ignition path and from spread:

- **`contained`** — the entry carries `"contained": true` and `_advance_burns`
  skips its spread roll. A fire lit to be walked to must still be ONE fire when
  the player arrives; the step asks for a single right click, and a front that
  has crossed six tiles by then is a different and unwinnable lesson. It lives on
  the burn entry rather than in a side table so it cannot outlive the fire.
- **`fuel`** — 30 against `FireDynamics.FUEL_DEFAULT`'s 1.0. A default tile burns
  out in ~9 s and the walk over is longer than that. 30 is ~4.5 minutes: not a
  timer the player can feel, which is the point. `fuel_max` takes the same value,
  so the flame still looks like a fire at full burn rather than a tile that has
  barely started.

A tutorial fire left burning by a skip is harmless by construction — it never
spreads, and it chars its own tile and stops.

### The polled step

`fire_follow` is the FTUE's **one** polled completion, and it is the exception
that proves the rule: "the fire is on screen now" is not an event any system
emits, it is a relationship between a camera that moves continuously and a cell
that does not. `_tick_fire_follow` reads it off the viewport's canvas transform
(not off a camera node — the free-camera debug mode swaps which one is current),
with `_FIRE_ONSCREEN_INSET` (0.12) of margin, because a flame half off the edge
has been found in the sense that matters.

The same tick covers the fire going out from under the step: `_fire_cell` is
cleared and the arc drops rather than asking the player to walk to a fire that
isn't burning.

### The douse

`FireManager` gained **`tile_extinguished(cell)`**, emitted from the one private
`_extinguish` — so the player's bucket, rain and every other route report
identically, and `ActionExtinguishFire` needed no change at all (it already calls
the public `extinguish`). It is the counterpart to `tile_burned` and deliberately
a separate signal: the two leave the cell in opposite states, grass restored
versus dirt.

The step takes **any** extinguish, not only the scripted cell's — a player who
found a second fire and doused that instead has learned the verb, and refusing to
advance would be pedantry. `tile_burned` is wired too (that one IS matched
against `_fire_cell`): the fire cannot burn out inside four minutes, but a step
whose only exit is an action on an object that can cease to exist is a strip that
hangs.

No new `TutorialGate` bit. Dousing goes through the tile action menu, which
`BUILD` opened three steps earlier — there is nothing left to withhold.

A **hold to skip tutorial** button sits in its own row under the strip for the whole FTUE: it fades in once in `_begin` and never fades out — not on the hand-off beats, not on the quiet step (since 2026-09-12; before that it followed the strip's fades). Centred, with `_SKIP_GAP` (5px) of clear air between
the two — they are
separate objects (one is the tutorial talking, the other is a control that ends
it) and touching edges read as one widget. It ends the whole FTUE; the tutorial
runs on every run rather than once, and the skip is what makes that acceptable.

**It is a hold, not a click, since 2026-08-14.** The button is on screen for the
entire FTUE and ending the FTUE cannot be undone, so
`pressed` is not connected at all: `button_down` starts a fill that sweeps across
the button, `skip()` fires when it reaches the far edge at `_SKIP_HOLD` (1.1 s),
and `button_up` **or `mouse_exited`** drains it at `_SKIP_DECAY` × the fill rate
(4×, so repeated stabs at the button can't accumulate into a skip —
`test_tutorial.gd` asserts the ratio is above 1, and the hold is in [0.75, 2.0]).

The fill is a `PixelUI.make_solid_ninepatch` child **of the button**, so it draws
after the button's own background *and* after its label — hence `ACCENT` at alpha
0.45, which leaves the copy readable under the sweep. Its width is `round()`ed:
it is a 9-sliced pixel sprite, and a half-texel edge resamples into a blurred
column. The bar is driven from `_process`, not from a tween, so releasing
mid-hold drains from where the bar actually is instead of restarting an
animation.

Nothing pauses. The strip never holds `get_tree().paused` and never covers the
world.

## TutorialGate: a verb doesn't exist until its step

`scripts/ui/tutorial_gate.gd`, a static class (no autoload — CLAUDE.md's UI
non-goals). Five bits: `MOVE`, `INSPECT`, `JOURNAL`, `SHOP`, `BUILD`, plus a shop allowlist (`restrict_purchases` / `allows_purchase`, see the step table above). Each instruction step
carries the one it teaches in `"grants"`, and `_show_step` sets the mask to the
union of every step **up to and including** the one on screen. The opening
narrative grants nothing, so the run starts with the player able to read and
nothing else; the build step grants the last bit, so the closing narrative and
everything after it is an unrestricted game.

| Bit | Refused at | Effect while withheld |
|---|---|---|
| `MOVE` | `ClickToMoveController._unhandled_input`, `UXOverlay._process` | left-click doesn't path, and no hover reticle is drawn |
| `JOURNAL` | `FieldJournal._input` (`toggle_journal`) | Space doesn't open the book |
| `INSPECT` | `TileInteractionController._unhandled_input` | no tile action menu at all (with it but without `BUILD`: a menu holding only the magnifier) |
| `SHOP` | `JournalShopInput._try_buy` | the page is readable but sells nothing; with it, only the allowlist sells |
| `BUILD` | `TileInteractionController._unhandled_input` | no placement entries in the tile menu |

Two rules hold at all four sites:

- **The refusal never consumes the event.** The click refused during the opening
  narrative is the same click that dismisses the line refusing it, and Space
  refused before the journal step still belongs to whatever else wants it.
- **The cursor follows the verb.** `UXOverlay` clears its hovered cell while
  `MOVE` is withheld, so the in-world reticle isn't drawn during the opening
  narrative — it exists to say "this cell is a destination", which is a claim the
  game is refusing at that moment. It clears the cell WITHOUT a state change
  (entering `LOCKED` would plant the locked X and square on a cell), so
  `_clear_hovered_cell` calls the two refreshers itself.
- **The gate is refused as late as possible.** `BUILD` sits *below*
  `TileInteractionController`'s right-click brake, because stopping a walk is
  part of the movement already taught; `SHOP` sits at the buy rather than at the
  click, because the shop page is readable from the moment the journal opens,
  which is the step before.

The default is **open**, and it reopens in `_exit_tree` rather than only in
`_finish` — a `static var` is per-process, so a skip, a scene change or a
restart mid-FTUE must not leave the next run unable to walk. That default is
also what keeps the balance simulator and every suite that never instantiates
the controller on an unrestricted game; `test_tutorial.gd` asserts it, asserts
the mask at every step, and greps the four call sites so a granted verb that
nothing checks fails.

## Three things it changed elsewhere


**The day opens just after dawn.** `TitleIntro.day_time_of_day` on
`gameplay_base.tscn` went 0.4 (09:36) → **0.29** (~06:58, the last of
TimeManager's dawn window, grading into morning as play starts). This is the
value that decides the run's start time, not `TimeManager.reset_clock` —
`RunController` waits on `TitleIntro.begun`, so `start_run`'s reset to midnight
happens FIRST and the intro's cut to `day_time_of_day` lands after it.

**No spontaneous fire on the opening day.** `FireManager.first_ignition_day = 1`
gates `_roll_ignitions` only, via the public `spontaneous_ignition_allowed()`.
Spread (`_roll_spread`) and the public `ignite()` are untouched on purpose:
there is nothing to spread from on day 0, and gating `ignite()` would silence
the debug ignite action and the balance simulator's scripted burns.

**Unlocks are priced per type, and the run opens with 25 tokens** (15 until 2026-09-14, when the FTUE started buying a frailejón AND a ladder on day one; the 15-token reasoning below is kept for the history). Was one flat
price of 20 for everything and a 10-token opening balance, which made the
tutorial's last step literally uncompletable. Now:

| Type | Unlock |
|---|---|
| ladder | 10 |
| frailejon | 10 |
| bridge | 20 |
| fence | 30 |

The journal's buildings page is authored in that order too — `tile_kinds`,
`entry_ids` and `cell_sizes` on `KnownBuildings` are parallel arrays, so all
three move together or the page sells the wrong thing under the wrong picture.
`test_journal_shop.gd` asserts the ids are in non-decreasing price order.

`UnlockState.unlock_costs`, with `unlock_cost` (20) as the fallback for an
unpriced type. The journal's shop page already drew a per-entry cost, so it
picked the ladder up for free once `journal_shop_input` started asking per id —
including the affordable/faded state, which is now also per entry.

The frailejon sits at the cheap end deliberately: a ladder needs an altitude
step and a bridge needs a gap, so the frailejon is the only build with no
terrain precondition and therefore the FTUE's guaranteed path through the build
step whatever the generator dealt. `test_tutorial.gd` asserts it stays
affordable at spawn, in water as well as tokens.

15 buys the cheap end and 5 tiles of placement, but NOT a bridge or a fence —
the opening choice stays a real one. It is still ~1 perfect day of visitor
income handed over at spawn: **rerun `sim/balance_sim.gd` against the old arm
before trusting any number downstream of the economy.** (See
[balance-sim](balance-sim.md); compare seed by seed.) `SimBot` still buys in
strict priority order and `break`s on the first thing it cannot afford, rather
than skipping down to something cheaper.

## Why it is built the way it is

**Advancing is signal-driven, with two documented exceptions.** Each instruction
step names the signal that proves the player did the thing, so there is no "close
enough" heuristic and no timeout. The narrative and quiet steps advance on a
timer, and are safe for the same reason: they ask for nothing, so nothing the
player does is being guessed at. The one genuinely polled step is `fire_follow`,
because what it waits for is not an event (see the fire arc above);
`test_tutorial.gd` requires every step to appear in either `STEP_SIGNALS` or
`UNSIGNALLED_STEPS`, so a new step that advances on nothing at all fails there
instead of hanging the strip in play. Three of the five use signals added for it: `FieldJournal.opened`/`closed`, and
`UnlockState.placement_paid(type, count)` — the latter emitted inside
`try_pay_placements`, which is the ONE place every build funnels through
(frailejones go via TileInteractionController, traversals via
TraversalPlacementController). `test_tutorial.gd` asserts those signals still
exist by name, because a rename would leave a step that silently never
completes.

**Pointing, 2026-09-14.** Four presentation cues on top of the copy, none of which change what completes a step:

- **The discover step pulses the nearest frailejón toward white** (`Frailejon.set_highlight`, driven by `_update_pulse` at up to `_PULSE_MAX` 0.35 over `_PULSE_PERIOD` 2.2 s). It rides the flash material (the same per-plant duplicate and `flash_amount` mix as SpawnFlash, colour `BUILD_COLOR`), so it sways with the plant and is alpha-only under the palette rule. The plant is picked once when the line appears, so it doesn't hop as the player walks. A real flash outranks it: `set_highlight` only records the amount while a tween runs, which is what lets the gold discovery flash play out when the step ends.
- **Captions ride above the strip.** `TileInteractionController`'s toast asks `TutorialController.caption_floor()` each frame and eases up over the strip, back down when it leaves (the quiet step, the end). Read off the strip's layout rect, not its alpha, so a hand-off fade doesn't bounce the caption.
- **The dock side follows the spread** (it slides, `_DOCK_SPEED`): beside the left page on the bitácora, so the species plate reads, and beside the right page on resources, so the shop does.
- **The book bobs what the step names.** `FieldJournal.set_cue(tab, entries)` (the tutorial says what; the book animates it on its own `PROCESS_MODE_ALWAYS` clock, `CUE_PERIOD` 1.6 s). The fore-edge tab travels ±`JournalForeEdge.WIGGLE_PX` (2, off the paper) with its hit rect; shop swatches ±`JournalKnownSet.WIGGLE_PX` (1), no further than the hover lift, so no new warp-block crossings. `_cue_for` decides: the bitácora step bobs the tab; a shop step bobs the tab back to resources while on the bitácora, and its entries once the shop shows.

**While the book is open the strip docks beside a page** (`_update_dock`, per frame off `FieldJournal.page_right_rect()`), because centred it covered the shop row the steps are asking about. **MEASURED 2026-09-14** with the shop step up: centred at 480×270 the strip spans y 209–244 against the frailejón swatch at 187–210 plus its buy tag below; at 360×202 (1440×810 windowed) 141–176 against 153–176, fully covered. Moving it DOWN was the first idea and does not fit: at 360×202 there are 26 px under the row for a 35 px strip and an 18 px skip row. The right page starts at x 264 / 204 and the strip is 200 wide, so docking puts it at x 62–262 / 2–202, over the bottom of the left page (the calendar, or the species plate on the bitácora spread), which none of the book steps point at. Those 360×202 numbers predate the book fitting the window (journal.md, "Fitting the window"): at 1440×810 the book now draws at 3 device pixels per texel, so the right page starts at logical x 198 and the left page ends at 162.75. The dock clamps to the screen, giving the strip x 0–200 on resources and 160–360 on the bitácora, 2–3 logical px over each page's spine edge (computed from the measured page rects, not rendered).

**Layer TUTORIAL (150) is above JOURNAL (140)** because several steps are read
with the book open, and `PROCESS_MODE_ALWAYS` + `TWEEN_PAUSE_PROCESS` keep the
strip and its fade alive while the journal holds `get_tree().paused`.

**The strip is containers all the way down** — `MarginContainer` → `VBoxContainer`
(END) → `PanelContainer` → `MarginContainer` → `HBoxContainer` → glyph + Label.
Not decoration: Spanish runs ~25% longer, `TUTORIAL_BUILD` wraps to two lines,
and the panel has to grow upward to hold it. Every wrapper is
`MOUSE_FILTER_IGNORE`; a container defaults to STOP, and a full-rect STOP here
would eat click-to-move across the whole window.

**Two steps lead their copy with a mouse glyph** (`click.tres` / `rightclick.tres`
— one 16px mouse with the left or the right button cut out of it), named by a
`click` tag on the step: `move` is left, `build` is right, and nothing else has
one. Left-vs-right is the only thing in this FTUE a player can get wrong having
read the line correctly, and it is the part a shape carries better than a word in
a second language. The steps that ask for a KEY (the journal is Space) carry no
glyph — a mouse over "press space" teaches the wrong input, and
`test_tutorial.gd` asserts exactly which steps have one. The glyphs are white
masks tinted from the theme's `Label/font_color`, so they cannot drift from the
copy's colour. One node, its texture swapped per step: rebuilding children per
line would relayout the panel mid-fade.

The glyph costs the copy ~21px of the strip's 200 (16 + a 5px gap), so it takes
the wrapping with it — measured below.

**The skip button is the column's second row**, below the strip and outside the
panel — a sibling of it, not a child. Inside the `PanelContainer` it drove the
panel's width and added a row of height to every step. Below it, it does
neither: the strip keeps `custom_minimum_size.x = 200` and `SIZE_SHRINK_CENTER`,
so even the longer Spanish label ("mantén para saltar el tutorial") widens only
the column, never the panel. The one thing it does not get free is the fade —
it doesn't inherit the panel's modulate, so the tween drives both.

**Superseded 2026-08-14:** the button used to be a free-floating sibling parked
half over the centre of the strip's bottom edge by a `_position_skip_button()`
that ran every frame, `reset_size()` included, because nothing else sized it to
its own translated label. Moving it into the column deleted that method and the
per-frame layout work with it.

## Space, not J

`toggle_journal` is the spacebar. That collides with the title screen's language
gate, which commits on `ui_accept` — Space too — so without a guard, picking a
language with the keyboard also throws the journal open over the cinematic.
`FieldJournal._input` therefore ignores the action unless the run is ACTIVE
**and** no `title_intro` node is left in the tree; the phase check alone is not
enough, because `RunController` starts the run when the cinematic *begins*. The
guard returns without consuming the event, since consuming it would eat the
gate's own keypress.

## preview_tutorial_strip.gd

Renders every step in both locales, plus the four per-type build lines, the
three per-type second-click lines, and one
state of the skip button mid-hold. Needs a rendering context — **no
`--headless`**.

The `roam` state renders an **empty frame on purpose** — that step's whole
content is the strip being gone, and a panel appearing in that capture means the
quiet flag stopped being honoured. The two fire states need `_fire_cell` injected
the way `_bought_type` and the `_FakePlacement` stub are: both fire steps skip
themselves unless a cell was lit, and there is no world here to light one on.
This is also why `_step_applies` tests `_fire_cell` alone and **not** whether the
fire is still burning — a live world query there would make the step
unrenderable. The "fire went out during the hand-off" case is handled in
`_connect_step_signal` instead, deferred and guarded on `_running`.

```bash
G="../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe"
$G --path . --script res://scripts/tools/preview_tutorial_strip.gd -- --out preview_out/
```

What it exists to catch: Spanish clipping, a missing `á` in `página` (the strip
uses Tiny5, which has the full set — Eggmode does not), a skip button that
stopped sizing to its own label, and a cue outline that stopped being a crisp
1px rect.

**MEASURED 2026-08-13:** at 200px wide, English fits one line for all five
instruction steps; Spanish wraps `TUTORIAL_BUILD` to two and clears the frame in
all five. (The skip-button clearance measured that day was for the old
straddling geometry and no longer applies.)

**MEASURED 2026-08-14 (glyph):** with the mouse glyph in the row, `TUTORIAL_MOVE`
still fits one line in English; the Spanish `build` line wraps to two and the
longest copy in the FTUE (`TUTORIAL_BUILD_FRAILEJON`, Spanish) to three, all
inside the panel and inside the crop. The glyph sits vertically centred against a
three-line block, which is what `SIZE_SHRINK_CENTER` on it buys.

**Fixed the same day:** the tool's four per-type build states were rendering the
CLOSING NARRATIVE, not the build step — `step` was `mini(state, size - 1)`, which
clamps to the last step, and the closing line ignores `_bought_type` entirely. So
the four states that exist to compare the four build lines were four copies of
one picture. It now looks the build step up by id.

**MEASURED 2026-08-14:** the narrative lines wrap to two rows in English and two
or three in Spanish (`NARRATIVE_CHARGE` is the three), the panel grows upward to
hold them, and all of it stays inside the crop. Accents render (`páramo`,
`más`, `día`, `mantén`). The hold fill is a crisp whole-pixel column and the
button's label reads through it. With the button moved below the panel, the
longest label in the project's UI ("mantén para saltar el tutorial") still
centres under a 200px strip without widening it or leaving the screen.

**MEASURED 2026-08-17 (fire arc):** `TUTORIAL_FIRE_FOLLOW` and
`TUTORIAL_FIRE_DOUSE` each wrap to two rows in both locales, frame clear, accents
rendering (`pantalla`, `resplandor`). The `roam` state captures an empty frame in
both locales, which is the pass condition. The two lines carry the left/right
glyph pair, matching the build steps.

**MEASURED 2026-08-14 (second click):** the rewritten `TUTORIAL_BUILD_LADDER`
(which now also names the ring pick) wraps to three rows in Spanish and two in
English, and every `TUTORIAL_ENDPOINT_*` line fits two rows in both locales,
frame clear. The endpoint states carry the LEFT-click glyph against the build
states' right-click one, which is the pair worth eyeballing side by side.

The tool carries a `_FakePlacement` inner class for those states: the endpoint
step skips itself unless a placement is open, and there is no
`TraversalPlacementController` here to open one. It answers `is_placing()` and
declares the two signals the step connects to — connecting to a signal a node
doesn't have is an error, not a no-op.

The tool must **not** name `TutorialController` at compile time — it loads the
script at runtime in `_process` instead. A `--script` tool is compiled before
autoloads exist, and the controller reads `SeasonManager`, so a compile-time
reference fails the whole chain with `Identifier not found: SeasonManager` and
every later `.new()` dies with `nonexistent function 'new'`. Same family of trap
as doing tool work in `_init`.
