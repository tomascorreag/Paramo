extends Node

## Autoload. Locks the pixel upscale to an integer chosen from the MONITOR
## resolution — a 1080p monitor is 4×, a 2160p monitor is 8× — independent
## of window size. Resizing the window shows more/less world at the same
## pixel size.
##
## Mechanism: the canvas transform scales by `window_size / content_scale_size`,
## uniformly, always. To lock the render scale to N, we set
## `content_scale_size = window_size / N` on every window resize.
## `config.base_width/height` is only the DESIGN reference used to pick N from
## the monitor; the runtime logical viewport is `window / N`. So 480×270 is NOT
## the shipped viewport — a 1440×810 window on a 1080p monitor (N=4) runs
## 360×203 (MEASURED); only 1080p/2160p FULLSCREEN lands exactly on 480×270.
##
## `stretch_mode` (config, live-togglable via set_stretch_mode) picks where that
## logical viewport is rasterized:
##   CANVAS_ITEMS — rasterize at window res; the viewport is just a coordinate
##     space. Fullscreen shader passes cost N² more fragments.
##   VIEWPORT — rasterize into a window/N framebuffer and upscale by N. Fill
##     drops N²; the pixel grid binds shaders, UI and motion.
## The same `content_scale_size = window/N` maths drives both, so N stays the
## upscale factor either way and the framing never changes (both cameras are at
## zoom 1) — only the rasterization resolution does.
##
## VIEWPORT caveat — pixel crawl: anything resting on a fractional position
## resamples against a fixed low-res grid, so it shimmers as it drifts.
## `Player/Camera2D` has position_smoothing_enabled with speed 1.0, which parks
## the camera on fractional positions by construction. That is the thing to judge
## when A/B-ing the modes, and it is not fixed here (snapping the camera fights
## the smoothing, and CLAUDE.md lists grid-snap as a deliberate non-goal).
##
## Note: `content_scale_factor` is live in BOTH modes and is pinned to 1.0 below.
## (An earlier comment here claimed it was ignored under CANVAS_ITEMS — that is
## false; window.cpp assigns `final_size_override = viewport_size /
## content_scale_factor` in that branch too, it just becomes a 2D transform
## rather than a framebuffer size. Under VIEWPORT it divides the framebuffer
## outright: `final_size = floor(viewport_size / content_scale_factor)`.)

signal base_resolution_changed(width: int, height: int)
signal scale_changed(new_scale: int)
signal stretch_mode_changed(mode: Window.ContentScaleMode)

const CONFIG_PATH: String = "res://resources/display_config.tres"

var config: DisplayConfig
var current_scale: int = 1
var effective_viewport_size: Vector2i = Vector2i.ZERO


func _ready() -> void:
	config = load(CONFIG_PATH) as DisplayConfig
	if config == null:
		push_error("DisplayManager: failed to load %s, using defaults" % CONFIG_PATH)
		config = DisplayConfig.new()

	var win := get_window()
	win.content_scale_mode = config.stretch_mode
	win.content_scale_aspect = config.stretch_aspect
	# FRACTIONAL because we drive the integer snap ourselves by assigning
	# content_scale_size = window/N (see _recompute_scale).
	#
	# Do NOT "upgrade" this to CONTENT_SCALE_STRETCH_INTEGER to harden the pixel
	# grid under VIEWPORT — MEASURED, it makes things worse. window.cpp does
	# `screen_scale = floor(screen_size / viewport_size)`, and
	# CONTENT_SCALE_ASPECT_EXPAND grows viewport_size a row PAST content_scale_size
	# to fill the aspect. At a 1440x810 window (N=4) the viewport expands 202->203,
	# floor(810/203) = 3, and the whole image drops to 3x with a large letterbox.
	# It only holds when the window divides evenly by N, and silently costs a full
	# scale step when it doesn't (also reproduced at 1365x767). EXPAND+INTEGER is
	# additionally an open upstream bug (godotengine/godot#92055). INTEGER also
	# floors content_scale_factor IN PLACE, so the property stops reading back what
	# you wrote. FRACTIONAL is exactly N whenever the window divides — which every
	# fullscreen target does (1080p->4, 1440p->5, 2160p->8) — and ~N±0.01 in a
	# non-divisible dev window, which is not worth a letterbox.
	win.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_FRACTIONAL
	# Live in both modes (see class doc). Pin it so our window/N maths is the only
	# thing deciding the scale.
	win.content_scale_factor = 1.0

	if not OS.has_feature("editor") and config.fullscreen_in_exports:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)

	win.size_changed.connect(_on_window_size_changed)
	_recompute_scale()


func _on_window_size_changed() -> void:
	_recompute_scale()


func _recompute_scale() -> void:
	var win := get_window()
	var screen_idx: int = DisplayServer.window_get_current_screen(win.get_window_id())
	var screen_size: Vector2i = DisplayServer.screen_get_size(screen_idx)

	# Integer scale from the MONITOR.
	var screen_ratio: float = minf(
		float(screen_size.x) / float(config.base_width),
		float(screen_size.y) / float(config.base_height)
	)
	var new_scale: int = maxi(1, int(floor(screen_ratio + config.scale_round_bias)))

	# Lock render scale at new_scale by making logical viewport = window / N.
	# Engine's canvas transform = window_size / content_scale_size = N exactly.
	var win_size: Vector2i = win.size
	var vp := Vector2i(
		maxi(1, int(round(float(win_size.x) / float(new_scale)))),
		maxi(1, int(round(float(win_size.y) / float(new_scale))))
	)
	win.content_scale_size = vp
	effective_viewport_size = vp

	if new_scale != current_scale:
		current_scale = new_scale
		scale_changed.emit(new_scale)


## Change the design reference used to pick N from the monitor.
## Runtime logical viewport is window/N, so this only affects N (which
## integer scale the monitor resolves to).
func set_base_resolution(w: int, h: int) -> void:
	if w <= 0 or h <= 0:
		return
	config.base_width = w
	config.base_height = h
	_recompute_scale()
	base_resolution_changed.emit(w, h)


## Where the scene rasterizes. See the class doc: CANVAS_ITEMS = window res,
## VIEWPORT = window/N framebuffer upscaled by N. Live-togglable so the two can
## be A/B'd on the same frame of gameplay — the deciding artifacts (shader
## chunkiness, pixel crawl under the smoothed camera) only show in motion.
func get_stretch_mode() -> Window.ContentScaleMode:
	return get_window().content_scale_mode


## DEPRECATED path. Low-res rasterization now lives in the world's SubViewport
## (see SmoothPixelViewport), which gives low-res world + full-res UI + a
## subpixel-smooth camera — strictly better than VIEWPORT stretch, which dragged
## the UI onto the low-res grid and could not smooth the camera. The root window
## stays CANVAS_ITEMS; do NOT switch it to VIEWPORT or you double-downscale on top
## of the SubViewport. Kept only so old callers don't break.
func set_stretch_mode(mode: Window.ContentScaleMode) -> void:
	var win := get_window()
	if win.content_scale_mode == mode:
		return
	win.content_scale_mode = mode
	config.stretch_mode = mode
	# content_scale_size is mode-independent (window/N), but re-assert it: under
	# VIEWPORT it sizes the real framebuffer, so a stale value is now visible.
	_recompute_scale()
	stretch_mode_changed.emit(mode)


func toggle_stretch_mode() -> void:
	if get_stretch_mode() == Window.CONTENT_SCALE_MODE_VIEWPORT:
		set_stretch_mode(Window.CONTENT_SCALE_MODE_CANVAS_ITEMS)
	else:
		set_stretch_mode(Window.CONTENT_SCALE_MODE_VIEWPORT)


func toggle_fullscreen() -> void:
	var mode := DisplayServer.window_get_mode()
	if mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_fullscreen"):
		toggle_fullscreen()
