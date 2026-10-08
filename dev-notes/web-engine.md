# Web engine template

The "Web" and "Web Profile" presets do not use Godot's stock web template. They
point `custom_template/release` at `res://engine/templates/web_nothreads_release.zip`,
a Godot 4.6.1-stable build with every subsystem the game never reaches compiled
out. The zip is committed; `engine/.gdignore` keeps the editor from scanning it and
`engine/*` is in both presets' `exclude_filter`.

## Why

MEASURED 2026-10-08 on the live site, fresh profile, no service worker: a first
visit transferred 11.51 MB before the player did anything, and 9.57 MB of that
was `index.wasm`, the stock engine. The game's own data (`index.pck`) is 1.57 MB.
Nothing in the pck is worth chasing next to the engine.

| | stock | stripped |
|---|---|---|
| `index.wasm` raw | 37.69 MB | 22.08 MB |
| `index.wasm` gzip -6 (≈ what Pages serves) | 9.43 MB (served: 9.57) | 5.20 MB |
| first visit, projected | 11.51 MB | ≈ 7.3 MB |

The projection swaps only the wasm; Pages served the stock wasm ~1.5% above
`gzip -6`, so expect ~5.28 MB on the wire. Confirm on the live site after the
first deploy (DevTools → Network, disable cache, or `performance.getEntriesByType`).

## What is stripped (`engine/paramo_web.py`)

Checked before stripping: every engine class named in a `.tscn`, `.tres` or
runtime `.gd` (`scripts/tools/` excluded) is 2D canvas, core GUI, or one of the
modules kept below.

- `disable_3d`, physics 2D and 3D, navigation 2D and 3D, XR. Routing is
  `AStar2D` (core); nothing has a collision shape or a tile physics/navigation layer.
- `modules_enabled_by_default=no`, then back on: `gdscript`, `freetype` (TTF faces),
  `text_server_fb`, `noise` (`FastNoiseLite`), `webp` (the lossy bitácora photographs).
  Gone: the advanced text server (ICU/HarfBuzz), svg, every image decoder except
  png/webp, ogg/vorbis/mp3/theora (all audio is QOA-compressed WAV, which is core),
  regex (tools only), networking, mbedtls, gltf and the 3D modules.
- `brotli=no` (no WOFF2 fonts), `minizip=no` (the pck is loaded directly).
- `lto=full`. `optimize` stays at the web platform's own `size` (-Os): Godot's
  comment in `platform/web/detect.py` puts -Oz at ~100 KiB smaller for a runtime cost.

**Rejected: `disable_advanced_gui`.** MEASURED: saves another ~0.5 MB gzip, but it also
removes `SubViewportContainer`, which `page_warp.gd` and `page_slit.gd` extend
and the HUD's `SeasonGaugeHolder` node is. The first stripped build booted with the journal and HUD
failing to compile. A grep for "advanced" widgets (`PopupMenu`, `OptionButton`,
...) missed it; read the `#ifndef ADVANCED_GUI_DISABLED` block in
`scene/register_scene_types.cpp` before trying again. A class-level build profile
(`build_profile=`) that disables only the unused advanced classes is untried.

**Known cost:** without the svg module the default theme's icons are empty. Every
player-facing control is styled by `paramo_theme.tres`; the only default-themed
controls are the `CheckButton`s in the debug overlay, which lose their toggle glyph
on web.

**Text on the fallback server:** Latin copy with `á`/`ñ` renders correctly (language
gate and loading screen checked in a browser). It has no shaping or ligatures,
which neither face uses. Re-check wrapping in both locales if a non-Latin locale is
ever added; that would need `text_server_adv` back.

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
```

The web platform's `get_flags()` overrides `target` and `optimize` from a profile
file, so the script passes `platform`/`target` on the command line. Builds are on
macOS; the committed zip (sha256 `e70eef6f…18e9`) came from 4.6.1-stable
`14d19694e` with emscripten 4.0.11.

Verify a rebuild in a browser, not just by exporting: the export succeeds with a
missing class. Serve the export, open the console, and expect no
"Cannot get class" / "Parse Error" lines before `RunController: run started`.
