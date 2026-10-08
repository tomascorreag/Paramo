# SCons profile for Paramo's web export template (Godot 4.6.1-stable, no threads).
# Used by engine/build_web_template.sh via `scons profile=...`. Each line strips
# engine code the shipped game never reaches; see dev-notes/web-engine.md for what
# each one removed and what was checked before removing it.
#
# platform and target are passed on the command line by the build script: the
# web platform's get_flags() forces target=template_debug and optimize=size over
# anything set here. optimize=size (-Os) is kept on purpose; Godot measured -Oz at
# ~100 KiB smaller for a runtime cost (platform/web/detect.py).

threads = "no"  # GitHub Pages cannot send COOP/COEP; matches variant/thread_support=false
lto = "full"

# Whole subsystems. The game is 2D canvas only, routes with AStar2D (core), and
# has no collision shapes, navigation layers, or XR.
disable_3d = "yes"
disable_physics_2d = "yes"
disable_physics_3d = "yes"
disable_navigation_2d = "yes"
disable_navigation_3d = "yes"
disable_xr = "yes"
# Dialogs, PopupMenu, OptionButton, RichTextLabel, Tree, TextEdit, and
# SubViewportContainer, which the journal pages used to extend; they now extend
# ViewportPanel (scripts/ui/viewport_panel.gd) instead.
disable_advanced_gui = "yes"
# Compatibility shims for renamed/removed APIs. Every scene and script is 4.6.
deprecated = "no"

# Fonts are TTF (no WOFF2); the pck is loaded directly, not from a zip.
brotli = "no"
minizip = "no"

# Every module off, then back on only what the game reads at runtime.
modules_enabled_by_default = "no"
module_gdscript_enabled = "yes"
# No freetype: the shipped fonts are bitmap bakes (scripts/tools/bake_bitmap_fonts.gd),
# drawn from their glyph cache. A TTF loaded at runtime would draw nothing.
module_text_server_fb_enabled = "yes"  # Latin-only copy: no ICU / HarfBuzz needed
module_noise_enabled = "yes"  # FastNoiseLite in terrain and weather
module_webp_enabled = "yes"  # lossy-imported bitácora photographs
