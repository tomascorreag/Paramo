class_name DisplayConfig
extends Resource

## Configuration for the game's display/viewport scaling.
## Consumed by DisplayManager at startup. Edit in inspector to change
## base resolution without touching project.godot.

@export_group("Base Resolution")
## Logical render width in pixels. Real screen is upscaled by an
## integer factor from this.
@export var base_width: int = 480
## Logical render height in pixels.
@export var base_height: int = 270

@export_group("Window Mode")
## In exported builds, start in borderless fullscreen.
@export var fullscreen_in_exports: bool = true
## Integer scale used when the editor runs the project windowed.
@export var editor_window_scale: int = 3

@export_group("Stretch")
## Where the scene is rasterized.
## CANVAS_ITEMS = rasterize at WINDOW resolution; the logical viewport is only a
##   coordinate space. Sprites still look like pixel art (nearest filter on an
##   already-pixel-art source) but shaders, fonts and any fractional position
##   resolve at full window res — smooth edges, and fullscreen shader passes cost
##   N² more fragments.
## VIEWPORT = rasterize into a `content_scale_size` framebuffer, then upscale by N.
##   Enforces the pixel grid on EVERYTHING (shaders, UI, motion) and cuts fill by
##   N². Costs pixel crawl wherever something rests on a fractional position — see
##   DisplayManager's note on Camera2D smoothing.
##   CanvasLayers cannot opt out: the framebuffer itself is low-res and the upscale
##   happens downstream of all canvas rendering, so the post-process ColorRect AND
##   the UI both go through it. Font oversampling is also skipped in this mode
##   (window.cpp never sets final_size_override here), so the 8px Tiny5 UI
##   rasterizes at a true 8px and upscales — chunkier glyph edges than now, same
##   apparent size.
## Same framing either way: the camera is at zoom 1, so this changes rasterization,
## not how much world is on screen.
@export var stretch_mode: Window.ContentScaleMode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
## How the canvas handles non-matching screen aspect ratios.
## EXPAND = show more world on wider screens; KEEP = letterbox/pillarbox.
@export var stretch_aspect: Window.ContentScaleAspect = Window.CONTENT_SCALE_ASPECT_EXPAND
## Rounding bias for picking the integer upscale factor from screen/base ratio.
## 0.0 = always floor (strict; never crop — e.g. 960p with base 270 → 3×).
## 0.5 = round to nearest (960p → 4×; accepts up to ~9% content crop).
## 1.0 - eps = always ceil (most aggressive upscale; most crop).
@export_range(0.0, 0.999, 0.01) var scale_round_bias: float = 0.5
