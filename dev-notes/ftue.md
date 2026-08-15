# FTUE — the first fifteen minutes

The opening of a run: what time the day starts, what the world is allowed to do
on that first day, and the hint strip that frames the run in narrative and
teaches the verbs.

Everything here is in `scripts/ui/tutorial_controller.gd`, plus three small
concessions in systems it depends on.

## The shape

| Step | Copy key | Advances on |
|---|---|---|
| 1 | `NARRATIVE_WELCOME` | dwell, or any key/click |
| 2 | `NARRATIVE_CHARGE` | dwell, or any key/click |
| 3 | `TUTORIAL_MOVE` | `ClickToMoveController.path_dispatched`, **twice** |
| 4 | `TUTORIAL_JOURNAL` | `FieldJournal.opened` |
| 5 | `TUTORIAL_SHOP` | `UnlockState.unlock_changed` |
| 6 | `TUTORIAL_CLOSE_JOURNAL` | `FieldJournal.closed` |
| 7 | `TUTORIAL_BUILD_*` | `TraversalPlacementController.placement_began`, or `UnlockState.placement_paid` |
| 8 | `TUTORIAL_ENDPOINT_*` | `UnlockState.placement_paid` (skipped unless a placement is open) |
| 9 | `NARRATIVE_CLOSING` | dwell, or any key/click |

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

Every step carries a **hold to skip tutorial** button in its own row under the
panel, centred, with `_SKIP_GAP` (5px) of clear air between the two — they are
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
non-goals). Four bits: `MOVE`, `JOURNAL`, `SHOP`, `BUILD`. Each instruction step
carries the one it teaches in `"grants"`, and `_show_step` sets the mask to the
union of every step **up to and including** the one on screen. The opening
narrative grants nothing, so the run starts with the player able to read and
nothing else; the build step grants the last bit, so the closing narrative and
everything after it is an unrestricted game.

| Bit | Refused at | Effect while withheld |
|---|---|---|
| `MOVE` | `ClickToMoveController._unhandled_input`, `UXOverlay._process` | left-click doesn't path, and no hover reticle is drawn |
| `JOURNAL` | `FieldJournal._input` (`toggle_journal`) | Space doesn't open the book |
| `SHOP` | `JournalShopInput._try_buy` | the page is readable but sells nothing |
| `BUILD` | `TileInteractionController._unhandled_input` | no tile action menu, so no placement |

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

**Unlocks are priced per type, and the run opens with 15 tokens.** Was one flat
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

**Advancing is signal-driven, never polled.** Each instruction step names the
signal that proves the player did the thing, so there is no "close enough"
heuristic and no timeout. The narrative steps are the exception and the reason
the exception is safe: they teach nothing, so nothing is gated on a timer. Three of the five use signals added for it: `FieldJournal.opened`/`closed`, and
`UnlockState.placement_paid(type, count)` — the latter emitted inside
`try_pay_placements`, which is the ONE place every build funnels through
(frailejones go via TileInteractionController, traversals via
TraversalPlacementController). `test_tutorial.gd` asserts those signals still
exist by name, because a rename would leave a step that silently never
completes.

**Layer TUTORIAL (150) is above JOURNAL (140)** because steps 3 and 4 are read
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
