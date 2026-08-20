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
## How the canvas handles non-matching screen aspect ratios.
## EXPAND = show more world on wider screens; KEEP = letterbox/pillarbox.
@export var stretch_aspect: Window.ContentScaleAspect = Window.CONTENT_SCALE_ASPECT_EXPAND
## Rounding bias for picking the integer upscale factor from screen/base ratio.
## 0.0 = always floor (strict; never crop — e.g. 960p with base 270 → 3×).
## 0.5 = round to nearest (960p → 4×; accepts up to ~9% content crop).
## 1.0 - eps = always ceil (most aggressive upscale; most crop).
##
## Quantization survey at bias 0.5 (fullscreen visible rows = height/N,
## target 270 so a texel stays ~1/270 of screen height on every monitor):
##   1280x720   → N=3 → 240 rows (-11%)
##   1366x768   → N=3 → 256 rows (-5%)
##   1600x900   → N=3 → 300 rows (+11%)
##   1920x1080  → N=4 → 270 rows (0%)
##   2560x1440  → N=5 → 288 rows (+7%)
##   3440x1440  → N=5 → 288 rows (+7%, height-limited, ultrawide OK)
##   3840x2160  → N=8 → 270 rows (0%)
## Worst is ±11% on the x.33-ratio panels and their neighboring N is
## strictly worse (900p at N=4 → 225 rows, -17%), so 0.5 stays.
@export_range(0.0, 0.999, 0.01) var scale_round_bias: float = 0.5
