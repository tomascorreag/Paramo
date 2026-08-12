extends Node

## Autoload. Locks the pixel upscale to an integer chosen from the MONITOR
## resolution — a 1080p monitor is 4×, a 2160p monitor is 8× — independent
## of window size. Resizing the window shows more/less world at the same
## pixel size.
##
## Mechanism: CANVAS_ITEMS + STRETCH_INTEGER. We set
## `content_scale_size = floor(window / N)` on every resize, so the
## window/content ratio lands in [N, N+1) and the engine's integer snap
## picks exactly N — every logical texel is exactly N device pixels
## (fractional scale = uneven texel widths = banding). The px the snap
## can't cover (window mod the snapped size, ≤~2N-1 per axis after the
## EXPAND aspect rewrite) become centered black margins outside the
## viewport blit; they are unpaintable and small enough to accept.
## `config.base_width/height` is only the DESIGN reference used to pick
## N from the monitor; the runtime logical viewport is ~`window / N`.
##
## Note: `content_scale_factor` is ignored in CANVAS_ITEMS mode (engine
## only applies it in VIEWPORT mode), so don't bother setting it.

signal base_resolution_changed(width: int, height: int)
signal scale_changed(new_scale: int)

const CONFIG_PATH: String = "res://resources/display_config.tres"

var config: DisplayConfig
var current_scale: int = 1
var effective_viewport_size: Vector2i = Vector2i.ZERO
var _last_screen: int = -1
var _last_win_size: Vector2i = Vector2i.ZERO


func _ready() -> void:
	# The journal/pause freeze the tree; window resizes must still retile the
	# canvas while paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	config = load(CONFIG_PATH) as DisplayConfig
	if config == null:
		push_error("DisplayManager: failed to load %s, using defaults" % CONFIG_PATH)
		config = DisplayConfig.new()

	var win := get_window()
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	win.content_scale_aspect = config.stretch_aspect
	# INTEGER: with content_scale_size = floor(window/N) the engine's snap
	# factor is exactly N (see _recompute_scale). FRACTIONAL let the real
	# scale drift to window/round(window/N) — e.g. 3.990 at 810px tall,
	# N=4 — and fractional nearest-neighbor upscale bands.
	win.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_INTEGER

	if not OS.has_feature("editor") and config.fullscreen_in_exports:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)

	_recompute_scale()


func _recompute_scale() -> void:
	var win := get_window()
	var screen_idx: int = DisplayServer.window_get_current_screen(win.get_window_id())
	var screen_size: Vector2i = DisplayServer.screen_get_size(screen_idx)
	_last_screen = screen_idx
	_last_win_size = win.size

	# Integer scale from the MONITOR.
	var screen_ratio: float = minf(
		float(screen_size.x) / float(config.base_width),
		float(screen_size.y) / float(config.base_height)
	)
	var new_scale: int = maxi(1, int(floor(screen_ratio + config.scale_round_bias)))

	# floor, not round: the window/vp ratio must land in [N, N+1) so the
	# engine's STRETCH_INTEGER snap picks exactly N. round() could make vp
	# too large (ratio < N -> snap = N-1) on windows just under a multiple.
	var win_size: Vector2i = win.size
	var vp := Vector2i(
		maxi(1, int(floor(float(win_size.x) / float(new_scale)))),
		maxi(1, int(floor(float(win_size.y) / float(new_scale))))
	)
	# Guard: this also runs on window moves now, and assigning
	# content_scale_size re-runs the engine viewport update (and re-emits
	# size_changed) even when nothing changed.
	if vp != win.content_scale_size or new_scale != current_scale:
		win.content_scale_size = vp
	# EXPAND may rewrite one axis by a pixel or two to match the window
	# aspect — report what anchors/get_visible_rect actually see, not our input.
	effective_viewport_size = Vector2i(win.get_visible_rect().size)

	if new_scale != current_scale:
		current_scale = new_scale
		# Screen size here should be PHYSICAL px; if a machine reports the
		# DPI-virtualized size instead, N halves and texels shrink — this
		# line is the tell.
		print("DisplayManager: screen %d %s -> scale %dx (viewport %s)"
				% [screen_idx, screen_size, new_scale, effective_viewport_size])
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


func toggle_fullscreen() -> void:
	var mode := DisplayServer.window_get_mode()
	if mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_fullscreen"):
		toggle_fullscreen()


# Per-frame poll instead of signals/notifications. The viewport's
# size_changed signal is unusable here: under STRETCH_INTEGER it only emits
# when the FINAL logical size changes, and a window resize that quantizes to
# the same logical rect under a stale content_scale_size emits nothing — the
# recompute never ran and the stale rect left thick black margins (e.g.
# 1442x811 → 1600x900 kept csize 360x202: a 160x92 px frame). And
# NOTIFICATION_WM_SIZE_CHANGED is not delivered to autoloads on desktop
# resizes (verified empirically). Cost: two compares per frame.
# The screen check is because N is derived from the MONITOR: dragging onto
# another monitor must re-derive it, and that changes no size at all.
func _process(_delta: float) -> void:
	var win := get_window()
	var screen_idx: int = DisplayServer.window_get_current_screen(win.get_window_id())
	if win.size != _last_win_size or screen_idx != _last_screen:
		_recompute_scale()
