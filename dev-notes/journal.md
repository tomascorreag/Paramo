# Field journal (and the title-screen language gate)

`...` = `"../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" --path .`
Every tool here needs a rendering context — **do NOT pass `--headless`.**

## Page warp — `scripts/tools/preview_page_warp.gd`

`assets/shaders/page_warp.gdshader` bends each page's content to follow the
perspective drawn into Book.png (each page edge sweeps 9px outward toward the
spine). The failure it prevents is content floating a few pixels off the paper —
a 1..9px error you cannot judge from a 480x270 still, so the tool **measures**:
it lays a 1px marker rule along the top and bottom of each page's Content, finds
it column by column in the render, and diffs against the expected row (Book.png's
own displacement at that column, scaled by the page's amplitude/9 — content
deliberately follows only *part* of the art's sweep). Exit 0 if every column is
within `--tol` (default 1px). The residual gap to the drawn edge is printed, not
failed.

```bash
... --script res://scripts/tools/preview_page_warp.gd -- --out /tmp/pagewarp
# A/B the line-quantised mode against the per-pixel warp
... --script res://scripts/tools/preview_page_warp.gd -- --out /tmp/pagewarp --no-markers --rows 0
```

### Measured findings

- The warp is a uniform vertical **stretch** (231/213), not just edge
  displacement: zero *translation* at the page's vertical centre, but never zero
  scale. Snapped to whole pixels that duplicates 18 scanlines; per-pixel
  (`--rows 0`) they land inside 8px glyphs and mangle letters. `row_block_px` =
  the font's line height moves every duplicated row into the leading.
- **Two axes of artefact, and `row_block_px` only fixes one.** The offset is also
  a stair across **columns**: `round` turns the sweep into one 1px step per texel
  of amplitude at fixed columns, and a step landing mid-glyph shears the letter.
  Measured at the full 9px sweep: 9 steps per line, ~1 glyph in 4 cut. Two
  mitigations, both in place — `col_block_px` (4, Tiny5's advance) snaps the steps
  onto the glyph grid so they fall between letters, and the content amplitude is
  tuned down to 5 of the art's 9. At amplitude 5 the content sits up to 4px off
  the paper near the spine; that is the price of crisp type. **Text that must be
  crisp belongs near the page's vertical centre**, where the weighting is ~0.
- `row_block_px` quantises from the Content rect's top, so page text must start
  at a **multiple** of it below that top, or every line straddles two blocks.
  `tests/test_journal_pages.gd` guards this.
- **The seams are real, and measured.** `audit_page_blocks.gd` replays the
  shader's own arithmetic: on both pages, at block 18 and amplitude 5, **every**
  block boundary steps across ~50% of the page's columns — the spine half, x
  0..~120 of 156. The one exception is y=108, at 18%, because it sits where the
  weighting crosses zero. A seam is a certainty for anything drawn inboard of the
  outer third, not a risk to be weighed.
- **The contract is about INK, not about node tops** (`JournalBlocks`). A run of
  height `h` at top `y` must touch no more blocks than its height forces:
  `ceil(h/block)`. Everything else follows — a run shorter than a block gets
  `block - h` texels of freedom in where it starts; a run **taller** than a block
  cannot avoid seams at all, so the goal is to cross the fewest, which it does
  anywhere in a `ceil(h/block) * block` window; a run exactly as tall as its block
  (Tiny5-16's 18-row line box) has none and must start on a boundary.
  This replaced "the header must be a whole number of blocks", a proxy that was
  **wrong in both directions**: it forbade the 6 other phases a 30-row fence
  legally has, and it never inspected a swatch, so art straddling three blocks
  passed. Measured ink: ladder 21, bridge 24, fence 30, frailejón 23.
- **The known sets sit one block higher than they used to** (`header_gap_px` -12,
  row top 24), and the cells were cut 36 → 30 to allow it. Both are needed: at a
  row top of 24 the fence's 30 rows of ink land on phase 9 when centred in a
  36-texel cell, which is three blocks. Cutting the cell to the fence's own ink
  zeroes its centring offset and puts it back on phase 6, the last legal one.
  **Cut every cell in the row, not just the binding one** — the arts are centred
  per cell, so shrinking one alone lifts that swatch off the row's shared line.
  The reclaimed 18 texels stay between the two known sets rather than closing the
  page up: section tops must be multiples of the block, so inter-section air
  quantises to 18 and there is nothing between "cramped" and "generous".
- **`header_gap_px` is a request, not the answer.** `header_row_px()` snaps it to
  the nearest legal row top (ties resolve **upward** — a negative gap is a request
  to tighten), floored at the heading's own rule so content can never print
  through it. Authoring an impossible gap is therefore not a build failure, it is
  a no-op with an Inspector warning; `test_journal_pages.gd` sweeps all 73 values
  of the range on every section and asserts each one still renders clean.
- **That floor must include the rule's WOBBLE.** `JournalPen.rule` displaces whole
  segments up to `wobble_px` off true, so the line inks `2 * wobble` rows more
  than its thickness. The old floor counted thickness only and was one row short.
- **`JournalTitle.Underline` chooses what a gap of 0 means**, not where the rule
  is drawn (that is the same row either way). `OWN_BLOCK` gives the rule a block
  and costs two; `SHARE_ROW` charges one and puts the rule in the top of the
  content's own first block. Deliberately **not** an "auto that picks the tighter":
  the page's rhythm must not move because a swatch was repainted a few texels
  shorter. Worth a whole block on a known set whose cell is near its ink; worth
  nothing on `JournalResources`, where a 16px glyph and an 18-row line box leave
  no rows to share and the snap pushes the row straight back down.
- A line must **not** sit flush against a block's top edge: the shader translates
  each block rigidly and the seam duplicates or drops the row next to it — flush
  at the top, that is the row every ascender and digit uses. Tiny5 at 8 has room
  (ink rows 1..7 of a 9-row line box); Eggmode at 16 does not (17 ink rows in an
  18-row block, one slack row, spent at the top via
  `RunCalendar.TITLE_INK_INSET_PX`). Symptom: an isolated 1px bar floating over
  one line. Scan a render for ink rows with a blank row above *and* below.
- The check skips each page's two innermost columns (215..216, 263..264) — that
  is the curl where the paper turns into the binding, drawn as a partial-height
  sliver, not a page edge the warp reproduces.

### Type on the pages

- **Pages are split by subject.** LEFT = the run (season slot at the top, the
  `RunCalendar` season log below). RIGHT = state + reference (a
  `JournalResources` supplies row, then two `JournalKnownSet` sections, "buildings"
  and "flora"). Both use `row_block_px` 18.
- **Nothing is a Label** — every piece of type is drawn (`RunCalendar`,
  `JournalKnownSet`, `JournalResources`), which is why the preview tool brings
  its own type specimen instead of retexting one out of the scene.
- **Two faces, split by role:** Eggmode for **titles only** (via
  `header_font`/`header_font_size`), Tiny5 at 8 for every piece of **data**. A
  title is drawn with `draw_string`, never a Label: Eggmode-16's line height is 16
  and 18 % 16 != 0, which fails the "whole number of text lines" test. A page of
  16px handwriting doesn't fit, hence the split. Both import with antialiasing,
  hinting and subpixel positioning OFF — Godot's TTF defaults ship blurry.
- The two pages set type at deliberately different weights: supplies is the
  headline figure (16x16 glyphs, Tiny5 at 16); the calendar's day stats are a
  dense record (8x8, Tiny5 at 8). Both are multiples of Tiny5's 8px em, the only
  constraint.
- **Every pixel face has a native em**, and a size that is not a multiple of it
  duplicates ~one pixel row per em at a different place in each glyph, so the
  line staggers. Tiny5/Bytesized 8px, Eggmode 16px. Don't trust the specimen or
  upem — measure the glyph outline grid (fraction of glyf points on a upem/em
  grid): Eggmode is 1024 upem, 99.9% on 64 units (16px) vs 49% on 128 (8px);
  FantasticBoogaloo is ~8% on *any* grid, a true outline face legal at any size.
  Line height as a ratio of size: Tiny5 9/8, Bytesized 10/8, Eggmode 1/1.
- `row_block_px` need not *be* one line — it must be a **whole number** of them.
  18 holds two Tiny5-8 lines or one Eggmode-16 title row, which is what lets both
  faces print on the same page. `RunCalendar` rounds its title row and
  day-number row each up to a whole block independently.
- **Headings are cased at draw time, by locale.** The CSV keeps the chrome lowercase; `JournalTitle.cased` puts Spanish sentence case (`Temporadas`, `Obras`) or English title case (`Season Log`, `Buildings`) on inside `draw`, and the bitácora's species name goes through the same function (`Frailejón`, `Frailejon Motoso`) while the shop tooltip and the toast keep the key as authored. `test_journal_pages.gd` measures every heading CASED — a capital is wider — and checks the face has the glyphs the casing adds. The bitácora's six fact phrases are sentence-cased the same way (`Hasta 3 m de alto`, `En Chingaza, Guerrero y Nevados` — the mountains as proper nouns) over lowercase `JOURNAL_VAL_*` / `ECOSYSTEM_*` keys; the field notes are authored in sentence case.
- **Headings are centred and ruled under** via `JournalTitle` (strokes from
  `JournalPen`, shared with the calendar grid). The title face at 16 (FantasticBoogaloo since 2026-09-11; Eggmode before, same box) inks 17 of an 18-row
  block, so the rule always lands in the block below; whether that costs an extra
  block depends on what is under the heading, and the caller decides via
  `underline_y`. Known sets / supplies: a 36px swatch or 16px glyph row fills its
  block, so the rule needs one to itself (`header_row_px()` = 36). Calendar:
  8px day numbers only need the bottom of their block, so the rule takes the top
  of the same block (`header_row_px()` = 18). `header_underline_offset_px`,
  `day_number_offset_px` and `header_gap_blocks` tune it; the gap can only change
  in whole blocks.

## Left page — `scripts/tools/preview_run_calendar.gd`

The left page holds two things that are blank at rest and therefore invisible to
a static render: `RunCalendar` (a grid of the run's days, X stamped per day
lived) and `PageSlit` (the slot the season wheel shows through). The tool drives
`SeasonManager` to four run states and saves each at 1:1 and 4x NEAREST:
`0_idle`, `1_early` (3/24), `2_mid` (12/24), `3_survived` (24/24).

```bash
... --script res://scripts/tools/preview_run_calendar.gd -- --out /tmp/cal
... --script res://scripts/tools/preview_run_calendar.gd -- --out /tmp/cal --full            # whole 480x270 book
... --script res://scripts/tools/preview_run_calendar.gd -- --out /tmp/cal --full --locale es_CO
... --script res://scripts/tools/preview_run_calendar.gd -- --out /tmp/cal --full --shop 20 --hover 0  # the shop, live
```

`--hover <i>` parks the pointer on "known buildings" entry `i` by calling
`JournalShopInput.handle_hover` directly — hover is resolved by arithmetic, not
by a real cursor, so the lift, the ink-up, the price and the verb glyphs can all
be rendered without one. Needs `--shop`, and it is now **the only way to see a
price at all**: an unhovered page prints none.

`--shop <n>` puts an `UnlockState` in the tree and stocks the ledger with `n`
tokens. Without it there is no economy, so the right page renders every entry
owned and can print no price whatever the pointer does — the shop is invisible in
the only tool that draws it. 20 is the state worth looking at: ladder (10) and bridge (20)
affordable, fence (30) not, which is the only arrangement where the per-entry
fade has anything to say.

Render both locales after touching copy — the journal is where a longer
translation shows up as a *layout* fault rather than as odd wording.

The locale is applied on the first **frame**, not in `_initialize`: project
autoloads do run under `--script`, and `LocaleManager._ready()` sets the boot
locale after `_initialize`, silently overwriting an override set there. Any tool
forcing engine-wide state that an autoload also owns has this problem.

It also **seeds DayLog** (`_PREVIEW_YIELD`), because each stamped cell prints what
that day yielded and a zero prints nothing — without the seed every still shows
bare stamps and the feature is invisible in the tool built to look at it.
`_write_state` teleports the clock rather than advancing it, so DayLog's
accumulation never runs; `DayLog.seed_day` is the hook (tools, tests and
save/load — never gameplay). The seeded series is deliberately **uneven**,
including days that yielded nothing: an even fill hides whether a sparse grid
still reads as a record rather than a texture.

### The slot is the exact complement of the page warp

| | moves | leaves |
|---|---|---|
| `page_warp.gdshader` | the CONTENT | the rect (ink printed on paper) |
| `page_slit.gdshader` | the RECT | the content (a cut in the paper) |

So in the stills the slot's two lips must step toward the spine while the wheel
behind them stays put. If the wheel steps too, the mask went on the wrong node.
`PageSlit` reads its curves/amplitudes/row_block off the `PageWarp` it points at,
so a `page_curl_*.tres` edit re-bends the text and re-cuts the slot together —
never re-author those numbers on the slit.

- A thin band needs only **one** warp offset per column, not a per-row function:
  a cut cannot change width as it slides. `page_slit.gd` evaluates the weighting
  once at the band's centre row (through the same row quantisation) and folds it
  into `amp_px`.
- The slot's container is padded by the amplitude top and bottom exactly like a
  page's Content — the shader has no clamp, so a smaller inset crops it near the
  spine.
- The wheel is a **disc**, so any horizontal band leaves paper showing in the
  band's top corners where the disc is narrowest. A shade on the top lip has
  nothing to fall on and reads as a bar floating over the page — hence
  **bottom-only** lip shade. There the disc is nearly as wide as the slot, so the
  shade survives only in the last few texels at each end, and
  `shadow_feather_px` tapers its height so those wedges round off. 5 texels
  reads; 10 erases the wedges entirely (they live exactly in the tapered zone).

## Right page: buildings / flora — and the shop

Two `JournalKnownSet` sections (`scripts/ui/journal_known_set.gd`) listing what
the player can put on the mountain, printed in brown ink. Render with `--full`.

- **"known flora" is a discovery list; "known buildings" is not.** The flora section sets `require_discovery`, and then draws only the species the run's `FloraCodex` (group `flora_codex`) holds — filled by walking up to a plant and picking the magnifier (`ActionInspect`). The buildings section lists what you CAN build and is complete from the first page turn. Everything index-based on the node counts through `entries()`, the DRAWN list, so a hidden entry costs no cell, no hit rect and no ink run and the row closes up; cell sizes and ids are still read at the entry's AUTHORED position. With no codex in the tree — every preview tool, every layout test, the editor — the whole authored list draws, which is the premise `test_journal_pages.gd` and `test_journal_shop.gd` rest on. `preview_run_calendar.gd --known frailejon,hypericum` renders a partly-filled page; `--known ""` renders the empty one a run actually opens with.
- **Two sources, because the two kinds of thing are built differently.** Bridges
  and ladders exist only as tiles in `resources/tiles/base_tileset.tres`
  (`scenes/traversals/bridge.tscn` is an empty Node2D — there is no Bridge
  sprite), so a swatch is cut out of the atlas at runtime via
  `TileKindIndex.coord()` + `get_tile_texture_region()`. Frailejones are Node2D
  world objects whose growth stages are already `AtlasTexture` `.tres`, so those
  go in the `textures` export directly. `get_tile_texture_region` accounts for
  `size_in_atlas`, which stops a ladder (1x2 cells) coming back as its bottom half.
- **The ink is a gradient map, not a desaturate**, and that is a palette
  decision: a luminance mix invents colours in no palette.
  `assets/shaders/journal_ink.gdshader` looks luminance up in a Gradient whose
  `interpolation_mode` is **CONSTANT**, so the output can only be an authored
  palette stop. Flipping to LINEAR silently reintroduces off-palette blends —
  `test_journal_pages.gd` checks the **sampled image**, not the stops.
- **Four ramps, picked per-fragment by hue:** `journal_ink_warm.tres`
  (wood/earth, and both ends of the hue wheel), `_green` (flora), `_cool`
  (stone/water/snow), `_neutral` (anything under `sat_threshold`). One ramp made
  a plant and a plank the same colour. Verified on the render: every pixel of all
  three shipped swatches is a palette2 entry; bridge and ladder draw warm-only;
  the frailejon takes greens in its leaves while its stem stays warm.
- The split applies to **UI glyphs** too, so the water drop inks blue and the
  coin gold. That colour is wanted — it is what tells the two channels apart at
  8px. A single-ramp "everything is brown ink" variant was built and rejected: it
  made the page cohesive and the data illegible.
- **The ramp pick is a hard selection, never a mix.** Blending two ramps averages
  two palette colours into one in neither. All four are sampled unconditionally
  and selected by 0/1 weights — also the WebGL2-safe shape, since a texture fetch
  inside non-uniform control flow has undefined derivatives.
- **`_neutral` is not decoration.** `hue_of()` returns 0 (red) for a fully
  desaturated colour, so without the saturation cutoff every grey would come out
  **brown**. `sat_threshold` and that ramp are a pair.
- The ramps are **low contrast by authoring**: shadows lifted off near-black
  (P07, P29, P30 excluded) while the light ends run up into the paper. That lives
  only in the `.tres`, so `test_journal_pages.gd` guards a minimum stop luminance.
- `_cool` and `_neutral` are currently unexercised — nothing on the page is blue
  or grey yet. If you add a rock/water swatch and it comes out wrong, suspect the
  hue boundaries before the art.
- A 32px swatch spans two 18px warp blocks, so it *can* shear by a texel across
  its middle. Measured on the real page: not visible at this amplitude. Don't
  "fix" it by shrinking the art — a 32px sprite cannot avoid a seam on an 18px grid.
  What shrinking the **cell** buys is different and real: the swatch is centred by
  its ink, so a tighter cell moves the art's phase and changes which row tops the
  whole section may take. `audit_page_blocks.gd` prints the list.
- **The binding entry is the one with the most ink, not the biggest cell.** A
  section's legal row tops are the intersection across its entries, so "known
  buildings" is set by the fence (30 rows, 6 texels of slack) while the ladder's
  21 rows would have allowed 15. Shortening the fence's art is the only thing that
  widens that section's freedom.
- **A swatch's hit rect is what is drawn, not the cell it was allotted.**
  `_rebuild` centres art at its own size and never scales it, so a cell smaller
  than the art leaves most of the picture visible but dead ("hover only works
  near the centre"). `JournalKnownSet.entry_rect` merges cell with drawn art and
  adds `hit_padding_px`; horizontal padding goes only on the **outer** ends, since
  cells abut and `entry_at` returns the first match. Every hit-test in the tests
  aimed at a cell *centre*, so none could catch this — hence
  `test_journal_shop.gd`'s corner walk.
- **The known sets are also the shop.** `JournalShopInput` (on BookHit) resolves
  clicks by pure arithmetic — page Controls stay mouse-IGNORE and the SubViewports
  keep `gui_disable_input`; nothing is forwarded. A locked entry (`UnlockState`)
  fades via the ink shader's `dim` uniform (the shader overwrites COLOR, so
  `self_modulate` is silently ignored). Contents
  are authored in the `.tscn`; `set_known` remains the hook for a discovery
  system (the shop tracks purchase, not discovery).
- **An entry the player cannot afford does not react to hover**, and neither does
  anything while `TutorialGate` withholds `SHOP`. The lift and the ink-up both
  say "this is available"; saying it over a price the player cannot meet turns
  the refusal into a surprise at click time, when the price in the tag was
  already the reason. `_hovered` still tracks the pointer — the input node resolves that
  and the two must not disagree about where the cursor is; what changes is
  whether the entry answers (`JournalKnownSet.reacts_to_hover`). Affording it
  mid-hover wakes it up without a mouse move, because the ledger's
  `resource_changed` runs the same refresh. OWNED entries still react: they are
  not blocked, they are done, and the section is a reference list as well as a
  shop. The click-time recoil (`flash_denied`) is unchanged — hover is
  affordance, a click is intent, and only intent earns a refusal.
- **NOTHING IS PRICED UNTIL IT IS POINTED AT, and the price is not in the page.**
  Every price printed at once turned a reference page into a price list — eleven
  small numbers competing with eleven pictures, on a spread whose whole argument
  is that it is a book. The price now belongs to the verb that pays it: it is
  drawn by `JournalTooltip`, beside the click glyph, only for the hovered entry.
  `JournalKnownSet` keeps the *state* (`set_entry_state` → locked / cost /
  affordable, read back with `cost_of`) because the swatch's own fade runs off it,
  but it draws no text and owns no coin. An entry the player cannot afford still
  shows its price even though it does not lift: it is the entry whose price
  matters most, and hiding it would hide the reason for the refusal.
- **A hovered entry gets two lines of mouse verbs** (`JournalTooltip`, code-built
  by `JournalShopInput`):

  ```
        [right click] [info]      over the art — read about it (a STUB)
             ( art )
        [left click] [coin] 20    under the art — buy it, for this much
  ```

  Nothing on a book says a picture in it is a button, and a price alone does not
  say which button. The buy line follows the same refusals as the click
  (`_is_for_sale`), so it never promises a purchase that would be denied; the info
  line is not a promise about money, so it stays up over owned and unaffordable
  entries. Buying drops the buy line without a mouse move, since the pointer does
  not move when you click and nothing else would re-ask.
- **Moving the price out of the page dropped three constraints it never earned.**
  In the cell it had to fit 20 texels, sit clear of both seams of a warp block,
  and be a child `TextureRect` to get its own `dim`. Outside the paper it is a
  `draw_texture` + `draw_string` in a node that is not warped and not clipped, so
  the cell-fit test and the block-phase reasoning for prices are both gone.
- **Bare glyphs in the page's own brown — no panel, no frame, no word.** The
  journal is a diegetic object and a framed UI tag over the paper reads as the
  game interrupting the book. They also need no translation: the verb is the glyph
  and the price is a number. The mice and the info disc are white masks, so
  drawing them in the ink colour is the whole recolour, and that colour comes from
  the section's own `text_color` — glyphs and page ink are the same palette entry
  by construction. NOT the `journal_ink` shader: that overwrites `COLOR` and would
  map a flat white mask to one ramp stop whatever the page is set to.
- **The coin keeps its own gold; only its alpha follows the price.** It is the one
  thing in the tag that is not a white mask, and the gold is what makes it read as
  the same currency as the supplies count a few rows above it. Tinting it with the
  page ink (the first attempt) rendered a brown disc that read as a hole. The
  denial red is the one case that overrides the art — a refusal has to read at a
  glance.
- **Both lines are centred on the art, clamped into `_tag_bounds`.** Two measured
  constraints, not preferences. Hung off the entry's corner (which is what a
  single glyph did) a multi-glyph line floats over the NEXT entry's column — seen
  on the ladder, whose line reached across the bridge. And a swatch sits a few
  texels down inside its cell, so a line placed above the ART lands squarely on
  the heading's rule, in the same brown: `JournalShopInput._tag_bounds` raises the
  allowed top to `header_row_px()`, which parks the read line on the upper part of
  the picture. `OVERLAP_PX` is what keeps each line reading as a cursor resting on
  the picture rather than a loose object beside it.
- **The refusal has two halves in two places now.** The swatch recoils where it
  sits (`JournalKnownSet.flash_denied`) and the price reddens where *it* sits
  (`JournalTooltip.flash_denied`, driven from `_try_buy`). The tooltip sets full
  red synchronously before starting its tween — a tween writes its start value a
  frame later, and a refusal has to answer the click that caused it.
- **The info glyph was painted into the UX atlas at (32,144)**, beside the two
  mice and in their idiom: a 9x9 white silhouette with the letterform knocked out
  of it, the way the mice knock out the pressed button.
  `assets/sprites/UX/icons/info.tres` cuts it out. Editing `icons.png` needs a
  `--headless --import` before a headless run sees the new pixels.
- **Anchored to `entry_ink_rect`, not `entry_rect`.** The latter is the HIT rect:
  it covers the whole cell and is grown by `hit_padding_px` again on top, so a tag
  placed on it drifts off the picture it names.
- **It is NOT inside the page, and cannot be.** Everything under the page's
  SubViewport goes through `page_warp.gdshader` and is clipped to the paper; a
  glyph drawn there would shear across a warp block and be cut off at the page
  edge. It floats over the book instead. The book and the page are 1:1, so 8px
  type in the tag is the same 8px type the page sets.
- **Parented to BookHit's PARENT, not to BookHit.** `BookHit` sits BEFORE `Pages`
  in `field_journal.tscn`, so anything under it is painted UNDER the paper —
  invisible, in a way no geometry assertion catches. Appended to `BookArt` it is
  the last child and therefore on top.

- **Swatches are laid out and centred by their ink, not their texture**, and each
  entry can carry its own cell size (`cell_sizes`, falling back to `cell_size`).
  These are atlas cut-outs that don't fill their cells: a ladder inks cols 16..29
  of its 32-wide tile, a fence 4..27. Centring the *textures* lines up their
  transparent margins and leaves the pictures lopsided and touching (measured: 4
  texels of overlap while both cells stayed clear). Cells **abut**, so
  `entry_rect` sums the widths before it — `index * pitch` silently stacks entries
  the moment widths stop being equal.
- `_ink_rect` caches by **atlas RID + region**, never `tex.get_rid()`: an
  `AtlasTexture` reports the RID of the sheet it cuts from, so every swatch
  sharing a spritesheet would collide on one cache entry.
- A calendar cell is 29x18, split LEFT/RIGHT: a red X stamped in the left band,
  and to its right two rows of "glyph + count" (water over tokens). The stamp
  needs its own band because it prints at **full opacity** — layered under the
  numbers it makes 8px digits unreadable, and fading it makes it read as a smudge.
  Only **two** of DayLog's three channels fit: a third row needs a 36-texel cell
  and 6 of those overflow the page. Visitors is dropped, being an input to the
  token count printed beside it.
- The stamp is the **one** mark on either page that is not journal ink:
  palette2's B55945, not an ink ramp stop, because a stamp is pressed onto paper
  rather than written on it and none of the low-contrast ramps holds a red.
  `test_journal_pages.gd` encodes that exception by name.

## Bitácora spread — `scripts/tools/preview_bitacora.gd`

The book's second spread: one discovered species per PAGE, two per spread, turned in pairs by the BENT PAGE CORNERS (`JournalPageCorners`, which replaced the chevrons under the tabs), jumped to by the fore-edge tab (`JournalForeEdge`) or opened by right-clicking a plant on the shop row. Both pages are a `JournalSpeciesPlate`. Until something is identified the bitácora is CLOSED: no tab, no page after the calendar, `show_spread` refuses. Render with the tool below; `--known ""` is that closed book.

```bash
... --script res://scripts/tools/preview_bitacora.gd -- --out preview_out/bitacora --locale es_CO
... --script res://scripts/tools/preview_bitacora.gd -- --out preview_out/bitacora --locale en_GB --species chusquea   # the pair chusquea is in
... --script res://scripts/tools/preview_bitacora.gd -- --out preview_out/bitacora --known ""                          # closed bitácora
... --script res://scripts/tools/audit_page_blocks.gd -- --locale es_CO                                                # per-species block audit
... --script res://scripts/tools/verify_journal_palette.gd -- --spread bitacora                                         # per pair, photos exempt
```

The page, in blocks (18 rows): name (0) · binomial, one Tiny5-8 line at 18 (1, top half) · the four growth stages in ONE ROW, packed by ink 4 columns apart and centred, stood on row 52 as REQUESTED, two rows clear of the quadrants, resolved by `stage_stand_px()` to the nearest row where every stage inks clean with the row moving as one — *E. barclayana*'s third stage is exactly 18 rows, legal only on a block, so that one row stands on 54 (1–2: the tallest ink of any species is 24 rows, so nothing reaches above row 28, under the binomial's line ending at 26) · then FOUR QUADRANTS, 78 columns by 79 rows from row 54 (top row blocks 3–7, bottom row 7–11, ending on row 212 of 213), each holding one thing: the six fact phrases, the herbarium-sheet polaroid, the field-photo polaroid, and the field note. A polaroid is 79 rows, so it fills its quadrant, flush with the top and centred; text starts on the first 9-row line top at or under the quadrant's top (54, or 135 for the bottom row) and has EIGHT lines to the quadrant's foot. Which quadrant holds what is one of 12 arrangements from `hash(id) % 12`: the field NOTE is always on the bottom row (its parity picks left or right), and the other three kinds take the remaining quadrants in one of their six orders (Lehmer code on the rest). Stable per species, different between species, the same in every locale and test. The old rule under the name is gone — the binomial is the divider now — and so is the note's `-` bullet.

- **Two spreads, one pair of pages, switched by `visible`.** Every section under a page's `Content` carries `@export var spread: StringName` (`run` or `bitacora`), and so does the season slit beside the pages (`PageSlit`) — it is a `SubViewportContainer` under `Pages`, not a section inside one, and it hung over the species name until it was tagged. `FieldJournal.show_spread` flips visibility per tag; the SubViewports, `page_warp`, the ink material and every audit that walks `Content.get_children()` are shared. A wrapper node per spread was rejected for exactly that reason: `audit_page_blocks.gd` and `test_journal_pages.gd` look one level down.
- **The book turns in pairs, from the first browsable species, in AUTHORED (sheet-row) order.** `show_species(id)` lands `id` on the left page when its ring position is even and on the right when odd — the same two pages it would be on if you paged there — so a right-click never shows a pair the chevrons cannot reach. An odd ring leaves the last right page BLANK (`set_blank`: no ink at all). There is no "empty state" any more: with nothing identified the bitácora cannot be opened, so the "nothing identified yet" copy that used to fill the left page (and its two CSV keys) went with it — the player now gets no hint in the book that a bitácora exists until the first inspect, which is a design choice to revisit if the FTUE does not carry it. Discovery order was rejected: the ring is something the player learns, and a later find should slot into place, not reshuffle it.
- **`JournalKnownSet` was not reused for the growth-stage grid.** Its heading is Eggmode (no accents — a species name is exactly the word that carries one) and `requested_header_row_px` floors the swatch row under the heading's rule. The plate stands its stages by `JournalKnownSet.ink_rect` (promoted to public for this) in ONE ROW on row 52, packed by ink width — the sprites carry a lot of transparent margin, and the earlier 2x2 grid of 36-px cells spread four small plants across half the page — so the widest row (*E. hartwegiana*, 80 columns of ink) is 92 wide and the narrowest (*Arcytophyllum*) 42; any ink of ≤36 rows ending on a boundary spans ≤2 blocks, the `align_ink_bottom` argument twice over.
- **The name is the title face, set like a JournalTitle heading without the rule.** Its first cut was Tiny5-16, because the title face then was Eggmode, which has no accented glyph and a plant's name cannot be re-worded around that (*frailejón*, *paja de páramo*); it read as body copy. The journal's title face is **FantasticBoogaloo at 16** since 2026-09-11 — full Spanish set, a true outline face with no native em, a 17-row line box (ascent 13, descent 4) that JournalTitle's 1-row inset fits in a block with zero slack, exactly as Eggmode-16 did. Widest name is *frailejón motoso* at 115 px (Eggmode: 124; Eggmode's *known buildings* was 199). `test_journal_bitacora.gd` asserts the face, `name_row_px() == 18`, the (1, 17) ink run and `has_char` on every letter of every name in both locales; `test_journal_pages.gd` measures every other heading in the new face. The accent-free heading words (`temporadas`, `obras conocidas`) were no longer forced by the face; the two reference headings were later shortened to `obras` / `flora` (`buildings` / `flora`) as a copy choice, the keys unchanged.
- **The photos are polaroids, they are NOT drawn in the page, and they are exempt from the palette like the disc.** Two per page — the herbarium sheet (`PlantObjectData.photo`) and the field photograph (`photo_live`, iNaturalist CC0; *E. barclayana* has none, so its second plate is a 2x detail of the sheet from the bake) — each in its own quadrant with its own pair of floats, `frame_rects()` / `photo_rects()` in float order. The rest of this entry describes one of them. The page's content is a 157x231 SubViewport at one texel per logical pixel, so a picture inside it is pixel art by construction — the first cut printed the herbarium sheets in there and they came out as 64x72 blocks. The species' sheet (GBIF CC0 voucher) is instead baked to **216x216** by `bake_flora_photos.gd` (centre-crop + LANCZOS; four times the frame's 54x54 logical window, one texture pixel per physical pixel at the 4x upscale) and drawn by a `JournalPhotoFloat` the plate owns: a LINEAR-filtered `TextureRect` OVER `BookArt` at window resolution, beside the tooltip and the tabs. A second float on top carries `PolaroidFrame.png` (68x79, NEAREST — it is pixel art at 1:1; the window is at (7, 7), 54x54, and the gold corners overhang the white body). A flat picture over a warped page floats off it near the spine, so `photo_warp.gdshader` bends both floats' rects with page_warp's own arithmetic on the page's own curve textures (pushed from the `PageWarp`, so a curve edit re-bends type and polaroid together); the rects are padded by the warp's reach so the displaced picture never leaves them. The plate keeps the GEOMETRY (`frame_rect()`, `photo_rect()` in page space) and the floats render it. The frame is reported to the block audit as ONE 79-row run at 28 — the fewest five blocks 79 rows can take — and the photograph takes its phase. Nothing is drawn by a float's own `_draw`: its warp material would sample a `draw_rect`'s 1x1 white TEXTURE and print the stroke white (measured, when tape strips lived there: 10 off-palette pixels a page). `verify_journal_palette.gd --spread bitacora` masks the whole polaroid rect **grown by (1, 6)** — the frame's white is not a palette entry (it is an art asset, covered at authoring time, and its gold is P12) and the warp displaces edge rows by up to its amplitude; everything else on the spread is audited and passes. `preview_bitacora.gd --hires` renders the spread through a 4x canvas transform, the only still that can show the difference (a 1:1 still upscaled with NEAREST cannot).
- **The photographs shown are the PALETTE-SNAPPED copies — an experiment.** `bake_flora_photos.gd` writes four PNGs per species: `<id>.png` and `<id>_live.png`, the photographs, and `<id>_palette.png` / `<id>_live_palette.png`, every pixel replaced by the nearest of the 33 palette2 entries by RGB distance, no dithering. `PlantObjectData.photo` points at the palette copy for now; pointing it back at the plain one is a one-line `.tres` edit per species and needs no code. Note that linear filtering at the upscale blends neighbouring entries, so even the snapped copy is not palette-legal pixel for pixel, which is one more reason the polaroid is exempt rather than audited.
- **The facts are phrases, not `label: value` pairs, and words, not floats.** `hasta 3 m de alto`, `3450-4000 m`, `suelo seco`, `resiste el pisoteo`, `crecimiento lento`, `crece en chingaza` — six lines, no colons, no price (a notebook page, not a tag). `water_affinity` 0.005 and `growth_chance` 0.01 are tuning values in units nothing shows; each is bucketed at thresholds set from the authored range (table in [flora](flora.md#bitácora)), and `altitude_band` is turned back into metres with the placement note's `h ≈ (m − 3000)/37.5`, rounded to 50.
- **One field note, rotating.** A species has 2–3 researched facts and the page prints ONE; `FieldJournal._fact_cursor` counts each species' showings and the plate prints `fact_keys[count % size]`, so it changes every time the page is shown — a right-click, a chevron, a tab, or opening the book while it is on that spread (`open()` re-shows the pair). A silent re-validation (a codex change) does not count. It word-wraps (`draw_multiline_string`, advancing by exactly `Font.get_height(8)` = 9 per line — Godot 4.6, verified in source, and the test asserts the 9) from the first free line after the facts, on the 9-row grid, which nests every line in its block. The test measures EVERY fact's wrapped end against the page's foot on the narrower (right) page in both locales; the budget is ≤90 chars en / ≤110 es and the longest Spanish fact ends at row 207 of 213.
- **The pages turn by their corners.** `BookPageCrease.png` is a 480x270 overlay of the cover with all four corners bent up; `JournalPageCorners` (under `BookArt`, authored AFTER `ForeEdge`, so it draws over the paper and picks before `BookHit`, inside whose rect every corner lies) draws ONE corner by region — the pointer is in a page's outer-edge STRIP (`zone_rect`: from the cover's rim to 20 px inside the page's outer edge, that corner's half of the page's height, grown to the corner's own ink where that reaches further in) and that corner is ENABLED — and a click ANYWHERE in that strip turns the page that way: `_has_point` is the zone that lifted the corner, not the corner's ink, because the first cut hit-tested the ink alone and the corner lifted for a pointer its click did not reach. The tab sits inside one of the strips and keeps priority (`_on_a_tab` asks `ForeEdge._has_point`). The book is one sequence for this: `FieldJournal.page_index()` is 0 on the run spread, then one per browsable pair (or the empty page), so the right corner on the calendar opens the first species and the left corner on the first species goes back to the calendar; no wrap, so the calendar has no left corner and the last pair no right one. The pointer is watched from `_input`, not `_gui_input` — a node that is only hit inside its corners would never hear the pointer approaching one — and `_has_point` is the shown corner's rect only, so the shop row's hover and the scrim's close keep their input; when a corner lifts over the shop row `BookHit` gets `mouse_exited` and drops its tooltip. The sheet is a full repaint of the cover, so a corner rect is where it DIFFERS from `Book.png` per quadrant (35x79 each since the 2026-09-12 enlargement) and `test_journal_page_corners.gd` re-measures them that way (a repaint cannot silently move a hit box) and checks the colours inside the rects: ONE off-palette colour, `A39870` (796 texels, the crease shadow; nearest entries are P14 `D4C692` and P06 `734C44`), which the page audit never sees because no corner is lifted in a still — flagged for Aseprite, not repainted here. `preview_bitacora.gd --corner br` renders a lifted corner. The arrow keys still page the bitácora pairs only.
- **ONE tab, the way to the OTHER spread, on the side that spread lies** (`JournalForeEdge`, under `BookArt` spanning it, authored AFTER `Pages` so it draws over them and picks before `BookHit`). On the run spread the bitácora tab hangs off the RIGHT page (the notes are forward); on the bitácora the run tab hangs off the LEFT (the shop is back); with nothing identified there is no tab at all. It is one frame of `BookTab.png` (a 16x16 sheet: TUCKED on top, 12 wide, the rest state; EXTENDED below, 16 wide, while the pointer is over it — each P11 rim on the page side, P12 fill, a lit two-row top cap and a shadowed three-row bottom cap round three identical middle rows) drawn with its flat side ONE texel off the page's outer edge (x 421 on the right, ending at 59 on the left; tucked it reaches the cover's rim, extended it hangs 4 past), stretched ALONG the tab to `label + 2 × 6` by three region draws — caps at 1:1, the middle rows to whatever is left, which is exact because they are alike (the test asserts it per frame) — and MIRRORED for the left side with a negative-width rect: Godot flips the texture for a negative size and keeps `position` as the top-left, it does not move the rect (the first cut passed `x + w` and drew the tab under the page). The tab is centred on the page's rows (21..252). The hover is `_input` mouse motion → `hover(local)`, and the hit rect is the tab AS DRAWN plus its REACH (`reach_rect`: the paper beside it, 20 px in from the page's edge — the corners' strip — over the tab's own rows), so a pointer near the tab on the paper extends it and clicks it, an extended tab stays out until the pointer leaves its wider rect, and a click anywhere on it or beside it turns the book; the corners ask `ForeEdge._has_point` first, so beside the tab no corner lifts, and above or below its rows the strip is the corner's again; `preview_bitacora.gd --tab` renders it extended. Anything inside a page is warped and clipped; a tab that does not stick out is not a tab. `_has_point` is the shown tab's rect only — the paper beside it still falls through to the corners' strips and the scrim. The label is Tiny5-8 turned a quarter turn with `draw_set_transform` at an integer origin (exact 90° keeps texels on the grid) and ANCHORED TO THE OUTER EDGE — the letters' far column is 3 inside the rounded edge, so the label slides out with the tab — reading top to bottom on the right (clockwise) and bottom to top on the left (anticlockwise), so on both sides the letters' feet face the page; a descender would point outward, onto the outer column, still inside the frame's full-width middle rows (neither label has one now). The tab length follows the locale (`resources` and `recursos` are a texel apart); `test_journal_bitacora.gd` measures both. A re-authored sheet needs `--headless --import` before a render: the old 10x8 import clamped the rows past its edge and drew the extended frame as a solid rim-colour block. The tab redraws on `spread_changed` and on `FieldJournal.browsable_changed`, which `_revalidate_species` emits after every codex change — the first find is what makes the tab appear, and nothing else was telling the fore-edge about it.
- **Right click reads.** `JournalShopInput.handle_read` runs the same arithmetic as `handle_click`, so the entry under the info glyph is the one whose page opens. Not gated by `TutorialGate.SHOP` (reading is not buying; the hover gate already hides the glyph during the FTUE). `JournalTooltip.show_for` gained a trailing `can_read`: the read line is drawn only where `FieldJournal.is_readable` says yes, so buildings — which have no page — lost the stub glyph, and an OWNED building now has no tag at all. `hide_tip` resets `buyable`/`price`/`readable`, since the tests read those back.
- **Hidden sections take no pointer.** The plates sit over the same texels the shop row does, so `handle_hover`/`handle_click`/`handle_read` skip any section not `is_visible_in_tree()` — without that, a click on the bitácora bought a hidden frailejón.
- **`verify_journal_palette.gd` had audited an empty viewport** since `FieldJournal._ready` started hiding and parking the book: it opened the journal from `_initialize`, before that `_ready` ran, and reported the clear colour as the pages' one off-palette pixel. It now poses on the first frame like every other journal tool.

## Language gate — `scripts/tools/preview_language_gate.gd`

The gate (two boxes: español/colombia, english/uk) is invisible to a plain
screenshot — `title_intro.gd` hides it until `ProceduralWorld` reports
`generation_finished`, and each box's alpha is then driven per frame by mouse
proximity to *that* box. The tool activates the gate, drives a cursor, and saves
four states: `0_idle`, `1_hover_es`, `2_hover_en`, `3_preselect` (a saved locale
marked, **not** chosen).

```bash
... --script res://scripts/tools/preview_language_gate.gd -- --out /tmp/gate
```

- `prompt_falloff_px` is sized to the **gap between the boxes** (60), not to the
  screen. The old single-prompt value (200) put the far box at ~75% brightness
  while the near one was at 100% — both read as lit and hovering stopped meaning
  anything.
- `prompt_min_alpha` is 0.45, not the old prompt's 0.08. "click to begin" could
  be a whisper because it only said "press anything"; these boxes carry a
  decision the player must **read**.
- The pre-selected box is marked with a raised floor alpha **and** the
  `frame_accent` stylebox — not a modulate. Tinting the normal frame would
  multiply two palette colours into a third that is in no palette; alpha is free,
  and so is a swapped authored stylebox.
- When adding a state, **place the cursor explicitly**. The viewport remembers
  where the previous state left it, so "don't move the mouse" silently renders
  the next state hovered.

## Rendered-pixel palette audit — `scripts/tools/verify_journal_palette.gd`

Renders both journal pages and checks **every rendered pixel** against the
journal's reduced ink palette, exiting non-zero on anything else.

```bash
... --script res://scripts/tools/verify_journal_palette.gd
```

Why this exists rather than a unit test: `tests/test_journal_pages.gd` can only
check colours somebody **authored**, not what they become once composited. The
calendar's rules were authored as P06 at alpha 0.7 — a legal palette entry —
and every rule pixel rendered as `9D7967`, a colour nobody authored and no RGB
check could catch. The fix made the rules an opaque lighter entry (P10), and the
test now also forbids alpha < 1 on journal ink: stricter than the project-wide
"alpha is free" rule, for exactly this reason.
