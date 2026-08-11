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
  `JournalResources` supplies row, then two `JournalKnownSet` sections, "known
  buildings" and "known flora"). Both use `row_block_px` 18.
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
- **Headings are centred and ruled under** via `JournalTitle` (strokes from
  `JournalPen`, shared with the calendar grid). Eggmode-16 inks 17 of an 18-row
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
```

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

## Right page: known buildings / known flora — and the shop

Two `JournalKnownSet` sections (`scripts/ui/journal_known_set.gd`) listing what
the player can put on the mountain, printed in brown ink. Render with `--full`.

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
  `self_modulate` is silently ignored) with the cost printed beside it. Contents
  are authored in the `.tscn`; `set_known` remains the hook for a discovery
  system (the shop tracks purchase, not discovery).
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
