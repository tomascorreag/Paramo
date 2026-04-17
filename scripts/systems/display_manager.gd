extends Node

## Autoload. Locks the pixel upscale to an integer chosen from the MONITOR
## resolution — a 1080p monitor is 4×, a 2160p monitor is 8× — independent
## of window size. Resizing the window shows more/less world at the same
## pixel size.
##
## Mechanism: CANVAS_ITEMS mode's canvas transform scales by
## `window_size / content_scale_size`, uniformly, always. To lock the
## render scale to N, we set `content_scale_size = window_size / N` on
## every window resize. `config.base_width/height` is only the DESIGN
## reference used to pick N from the monitor; the runtime logical
## viewport is `window / N`.
##
## Note: `content_scale_factor` is ignored in CANVAS_ITEMS mode (engine
## only applies it in VIEWPORT mode), so don't bother setting it.

signal base_resolution_changed(width: int, height: int)
signal scale_changed(new_scale: int)

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
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	win.content_scale_aspect = config.stretch_aspect
	# FRACTIONAL because we drive the integer snap ourselves by assigning
	# content_scale_size = window/N (see _recompute_scale).
	win.content_scale_stretch = Window.CONTENT_SCALE_STRETCH_FRACTIONAL

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


func toggle_fullscreen() -> void:
	var mode := DisplayServer.window_get_mode()
	if mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_fullscreen"):
		toggle_fullscreen()
