# Web engine template

The "Web" and "Web Profile" presets do not use Godot's stock web template. They
point `custom_template/release` at `res://engine/templates/web_nothreads_release.zip`,
a Godot 4.6.1-stable build with every subsystem the game never reaches compiled
out. The zip is committed; `engine/.gdignore` keeps the editor from scanning it and
`engine/*` is in both presets' `exclude_filter`.

## Why

MEASURED 2026-10-08 on the live site, fresh profile, no service worker: a first
visit transferred 11.51 MB before the player did anything, and 9.57 MB of that
was `index.wasm`, the stock engine.

| first visit, before any input | engine (gzip) | pck (gzip) | total |
|---|---|---|---|
| stock template (live, measured) | 9.57 MB | 1.57 MB | 11.51 MB |
| stripped v1 (staging, measured) | 5.28 MB | 1.57 MB | 7.22 MB |
| stripped v2 (this note; local export, projected at Pages' gzip) | ≈4.45 MB | ≈1.25 MB | ≈5.8 MB |

v2's projection uses the local export's `gzip -6` sizes scaled by what Pages added
over `gzip -6` on v1 (+1.6% wasm, +0.2% pck). Confirm on staging.

## What is stripped (`engine/paramo_web.py`)

Checked before stripping: every engine class named in a `.tscn`, `.tres` or
runtime `.gd` (`scripts/tools/` excluded) is 2D canvas, core GUI, or one of the
modules kept below.

- `disable_3d`, physics 2D and 3D, navigation 2D and 3D, XR. Routing is
  `AStar2D` (core); nothing has a collision shape or a tile physics/navigation layer.
- `disable_advanced_gui` (MEASURED −487 KB gzip). Removes dialogs, `PopupMenu`,
  `OptionButton`, `RichTextLabel`, `Tree`, `TextEdit`... and `SubViewportContainer`,
  which the journal pages used to extend. They now extend `ViewportPanel`
  (`scripts/ui/viewport_panel.gd`), which reproduces the container for
  `stretch = false`: draw each SubViewport child's texture at its own size, render
  it only while visible, report its size as the minimum. Input forwarding is not
  reproduced; the journal never used it (pages are `mouse_filter = IGNORE` with
  `gui_disable_input` viewports, and `JournalShopInput` maps clicks itself). Read the
  `#ifndef ADVANCED_GUI_DISABLED` block in `scene/register_scene_types.cpp` before
  adding a control: a grep for the obvious widgets missed `SubViewportContainer`
  the first time.
- `deprecated=no` (MEASURED −98 KB gzip). Drops every binding Godot wraps in
  `#ifndef DISABLE_DEPRECATED`. Desktop and GUT still have them, so a deprecated
  call only fails on web, as a script parse error at load. The first build hit
  `Image.create()` in four shipped scripts (now `Image.create_empty()`).
  `engine/find_deprecated_uses.py <godot src> .` lists every shipped use of the
  188 deprecated bindings; run it after a Godot upgrade.
- `modules_enabled_by_default=no`, then back on: `gdscript`, `text_server_fb`,
  `noise` (`FastNoiseLite`), `webp` (every Lossless texture is stored as lossless
  WebP, plus the lossy bitácora photographs). Gone: FreeType, the advanced text
  server (ICU/HarfBuzz), svg, every image decoder except png/webp,
  ogg/vorbis/mp3/theora (all audio is QOA-compressed WAV, which is core), regex
  (tools only), networking, mbedtls, gltf and the 3D modules.
- No FreeType (MEASURED −233 KB gzip). The shipped fonts are bitmap bakes, see below.
- `brotli=no` (no WOFF2 fonts), `minizip=no` (the pck is loaded directly).
- `lto=full`. `optimize` stays at the web platform's own `size` (-Os): Godot's
  comment in `platform/web/detect.py` puts -Oz at ~100 KiB smaller for a runtime cost.

**Rejected: dropping `webp`.** −95 KB engine, but every lossless texture would have
to be re-stored as PNG and the pck grows by about as much.

**Known cost:** without svg the default theme's icons are empty. Every
player-facing control is styled by `paramo_theme.tres`; the only default-themed
controls are the `CheckButton`s in the debug overlay, which lose their toggle glyph
on web. Without FreeType, outlines on text cannot be drawn: `profile_web.gd`'s
overlay loses its outline.

## Fonts: bitmap bakes

`assets/fonts/bitmap/tiny5_8.res` and `fantastic_boogaloo_16.res` are what the theme
and the journal use. `scripts/tools/bake_bitmap_fonts.gd` writes them from the TTFs:
every glyph the face has, rasterised once at the face's em, fixed-size with
integer-only scaling. Fixed-size fonts skip the display's oversampling, so the text
server never asks for a size that was not baked. The TTFs stay in the repo as the
source and are dropped from the export (`assets/fonts/*.ttf`).

Consequences:
- A face is only legal at whole multiples of its baked size. Tiny5 always was (8 px
  em); FantasticBoogaloo, a true outline face, was legal at any size as a TTF and
  now only at 16, 32...
- No kerning. The web build never had any: its fallback text server reads only the
  legacy `kern` table, and neither face has one (Tiny5 kerns through GPOS).
- A glyph the face lacks draws as a missing glyph, as it did on web before (no
  system fonts there).

MEASURED: `scripts/tools/verify_bitmap_fonts.gd` draws every string in
`paramo.csv` (both locales) plus a glyph line with the TTF and with the bake, at
every size used, at 1× and under 4× oversampling: 1290 renders, 0 differing pixels.
It runs on the HarfBuzz text server, because the official editor binaries do not
include the fallback one. That is the stricter test: the rasters come from the same
FreeType, and HarfBuzz additionally applies the TTF's GPOS kerning and GSUB.

Re-run the bake after swapping a TTF or its import settings, then the verify tool.

## Rebuilding

Needed after a Godot upgrade (the template must match the editor version exactly)
or when a stripped feature is wanted back. A new engine class in a scene or a
script must be checked against the list above; if it lives in a disabled
subsystem the web build fails at load with "Cannot get class" or a script parse
error, while desktop runs fine.

```bash
# toolchain, once: emscripten pinned to Godot 4.6's CI (.github/workflows/web_builds.yml)
git clone --depth 1 --branch 4.6.1-stable https://github.com/godotengine/godot.git ../godot-4.6.1-src
git clone --depth 1 https://github.com/emscripten-core/emsdk.git ../emsdk
../emsdk/emsdk install 4.0.11 && ../emsdk/emsdk activate 4.0.11   # needs Python >= 3.10
source ../emsdk/emsdk_env.sh && pip install scons

engine/build_web_template.sh ../godot-4.6.1-src    # ~4 min on an M1, writes engine/templates/
python3 engine/find_deprecated_uses.py ../godot-4.6.1-src .
```

The web platform's `get_flags()` overrides `target` and `optimize` from a profile
file, so the script passes `platform`/`target` on the command line. Builds are on
macOS with emscripten 4.0.11 from 4.6.1-stable `14d19694e`.

Verify a rebuild in a browser, not just by exporting: the export succeeds with a
missing class. Serve the export, open the console, and expect no
"Cannot get class" / "Parse Error" lines before `RunController: run started`.

## What else ships less (2026-10-08)

- `scripts/tools/*` and the three test scenes are in `exclude_filter` (−295 KB
  pck gzip). The runtime scripts that lived there moved to `scripts/systems/`
  (`procedural_world`, `ground_layer_configurator`), `scripts/objects/`
  (`frailejon`) and `scripts/debug/` (`web_profile_boot`, `profile_web`).
  `tests/test_export_exclusions.gd` fails if shipped code reaches an excluded file
  through the resource graph from `main.tscn`, a path string, or a tool class_name.
- The music engine (255 KB) is no longer in the HTML head; `paramo-music.js` loads
  it on the first interaction, when the music starts anyway. The drum samples are
  lossless FLAC (`docs/music/samples/README.md`).

## Returning players: one build, never two

Changing the engine exposed a bug in Godot 4.6's generated service worker. It
caches `index.js` at install but `index.wasm` / `index.pck` only when a page it
controls fetches them later, and it checks that its cache is complete for the HTML
request alone. A player whose cache holds an old `index.js` and no wasm got new
HTML from the network, the old `index.js` from the cache and the new wasm from the
network, and the load died at the end of the progress bar with
`Aborted(Assertion failed: missing Wasm export: _emwebxr_on_input_event)`.
REPRODUCED locally (stock live build, then this branch's build, HTTP cache expired),
and seen on staging.

Two fixes, both needed:

- **`scripts/tools/patch_service_worker.gd`**, run by CI on every deploy. Install
  caches every file (`addAll` is all-or-nothing, so a worker version holds one
  complete build), the completeness check runs for every request, only OK
  responses are cached, and the offline page only answers navigations. Every
  replacement must match exactly once or the deploy fails, so a Godot upgrade that
  changes the generated file cannot ship an unpatched worker. Local exports to
  `docs/` are not patched.
- **The stale-build guard**, inline in both presets' `head_include`. Workers already
  installed keep the old behaviour until replaced, and the HTML always comes from
  the network, so the guard always arrives. On `missing Wasm export` or a
  `LinkError` it unregisters this scope's worker, deletes the `Paramo-*` caches,
  revalidates `index.js` / `index.wasm` / `index.pck` (`cache: 'no-cache'`, bodies
  read so the HTTP cache keeps them) and reloads, once per tab session.

MEASURED with a logging server that sends Pages' `max-age=600`:

| case | result |
|---|---|
| first visit, patched worker | each file downloaded once; install reuses the page's HTTP-cached copies |
| second visit, HTTP cache cleared | js / wasm / pck all from the worker cache, 0 bytes from the server |
| old stock worker, deploy, revisit | one failed start, guard reload, game starts; extra cost one `index.js` (≈72 KB gzip) and two 304s |
| patched worker, deploy of a different engine, revisit | old build served whole and starts, new build downloaded once in the background; next visit runs the new build from cache |

Rejected: `skipWaiting()` in the new worker. It would take over mid-load, after the
page has its `index.js` and before the wasm arrives, which is this bug again.

## Not done, measured

- Brotli. Pages only gzips. Brotli-11 would take the engine to ≈2.95 MB and, with
  `script_export_mode=1` (uncompressed tokens, which gzip does not care about), the
  pck to ≈0.9 MB. Chrome/Edge cannot decompress brotli in the page
  (`DecompressionStream`), so on Pages it needs a ~98 KB wasm decoder and a custom
  shell, and the engine loses streaming compilation. Cloudflare Pages reportedly
  compresses at level 4 (≈4.6 MB for the v1 engine), which is worse.
- An extra `wasm-opt -Oz` pass: −130 KB gzip, ≈0 under brotli.
