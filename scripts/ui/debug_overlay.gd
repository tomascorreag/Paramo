extends CanvasLayer
## Visible iff `Debug.enabled`. Hosts the in-game debug controls.
##
## Time tools (current set):
##   - "Time passage" CheckButton mirrors `TimeManager.paused` (inverted: ON = time passes).
##   - "Current time" HSlider writes `TimeManager.time_of_day` via `set_time()`.
##     Dragging auto-pauses the clock; release restores prior pause state.
## New debug rows are expected to be added as siblings inside the overlay's VBox.

const _SLIDER_MAX: float = 0.999

@onready var _passage_toggle: CheckButton = %PassageToggle
@onready var _time_slider: HSlider = %TimeSlider
@onready var _time_label: Label = %TimeLabel
@onready var _indices_toggle: CheckButton = %IndicesToggle
@onready var _altitudes_toggle: CheckButton = %AltitudesToggle
@onready var _free_move_toggle: CheckButton = %FreeMoveToggle
@onready var _pixel_toggle: CheckButton = %PixelToggle
@onready var _rain_slider: HSlider = %RainSlider
@onready var _rain_label: Label = %RainLabel
@onready var _perf_label: Label = %PerfLabel

# Rolling wall-clock frame-time window (ms). Wall clock, not TIME_FPS, matches
# profile_scene.gd — TIME_FPS is smoothed and published once/second. On web the
# main loop is requestAnimationFrame-driven, so these samples are vsync-capped:
# the number is only meaningful once the GPU drops the frame BELOW refresh. If it
# sits pinned at your refresh rate, that mode has GPU headroom at this resolution
# and the fill delta is invisible here — read the DevTools GPU track instead.
const _PERF_WINDOW: int = 90
var _dt_samples: Array[float] = []
var _last_usec: int = 0
var _perf_refresh: int = 0

var _dragging: bool = false
var _prev_paused: bool = false

# Rain slider mirrors the controller's current intensity while idle; grabs
# control via set_rain_override during a drag, then releases on drag_ended.
# When no controller is in the scene (e.g. tileset_test) the slider falls back
# to writing rain_amount on the RainLayer directly.
var _rain_dragging: bool = false
var _controller: DayNightSceneController


func _ready() -> void:
	# Authoritative layer (kept in sync with the .tscn); always on top so the dev
	# panel is never occluded by HUD / post-process.
	layer = UILayers.DEBUG
	visible = Debug.enabled
	Debug.enabled_changed.connect(_on_debug_enabled_changed)

	_time_slider.min_value = 0.0
	_time_slider.max_value = _SLIDER_MAX
	_time_slider.step = 0.001

	_sync_from_time_manager()

	_passage_toggle.toggled.connect(_on_passage_toggled)
	_time_slider.drag_started.connect(_on_slider_drag_started)
	_time_slider.drag_ended.connect(_on_slider_drag_ended)
	_time_slider.value_changed.connect(_on_slider_value_changed)
	_indices_toggle.toggled.connect(_on_indices_toggled)
	_altitudes_toggle.toggled.connect(_on_altitudes_toggled)
	_free_move_toggle.toggled.connect(_on_free_move_toggled)
	_pixel_toggle.toggled.connect(_on_pixel_toggled)
	_rain_slider.drag_started.connect(_on_rain_drag_started)
	_rain_slider.drag_ended.connect(_on_rain_drag_ended)
	_rain_slider.value_changed.connect(_on_rain_slider_changed)
	# Deferred so RainLayer._ready and DayNightSceneController._ready (which
	# both add themselves to groups) have run.
	call_deferred(&"_resolve_rain_refs")
	TimeManager.time_changed.connect(_on_time_changed)


func _on_debug_enabled_changed(is_enabled: bool) -> void:
	visible = is_enabled
	if is_enabled:
		# Drop stale timing so the first frame after re-showing isn't logged as a
		# multi-second "frame" (_last_usec == 0 skips the first sample).
		_last_usec = 0
		_dt_samples.clear()
		_sync_from_time_manager()


func _sync_from_time_manager() -> void:
	_passage_toggle.set_pressed_no_signal(not TimeManager.paused)
	_time_slider.set_value_no_signal(min(TimeManager.time_of_day, _SLIDER_MAX))
	_update_time_label(TimeManager.time_of_day)
	_indices_toggle.set_pressed_no_signal(Debug.show_tile_indices)
	_altitudes_toggle.set_pressed_no_signal(Debug.show_tile_altitudes)
	_free_move_toggle.set_pressed_no_signal(Debug.free_movement)
	var spv := _get_smooth_pixel_viewport()
	_pixel_toggle.set_pressed_no_signal(spv != null and spv.smoothing_enabled)


func _on_indices_toggled(button_pressed: bool) -> void:
	Debug.show_tile_indices = button_pressed


func _on_altitudes_toggled(button_pressed: bool) -> void:
	Debug.show_tile_altitudes = button_pressed


func _on_free_move_toggled(button_pressed: bool) -> void:
	Debug.free_movement = button_pressed


# ON = subpixel-smooth camera (world snaps to texels, display slides by the
# sub-texel remainder). OFF = the old choppy, per-texel-jump camera. Toggle it
# WHILE THE CAMERA MOVES — a still frame is identical either way; the whole point
# is the motion. (The world always rasterizes low-res now via the SubViewport;
# this only governs whether the smooth scroll is re-added on top.)
func _on_pixel_toggled(button_pressed: bool) -> void:
	var spv := _get_smooth_pixel_viewport()
	if spv != null:
		spv.smoothing_enabled = button_pressed


func _get_smooth_pixel_viewport() -> SmoothPixelViewport:
	return get_tree().get_first_node_in_group(&"smooth_pixel_viewport") as SmoothPixelViewport


func _on_rain_drag_started() -> void:
	_rain_dragging = true
	if _controller != null:
		_controller.set_rain_override(_rain_slider.value)


func _on_rain_drag_ended(_value_changed: bool) -> void:
	_rain_dragging = false
	if _controller != null:
		_controller.clear_rain_override()


func _on_rain_slider_changed(v: float) -> void:
	if _rain_dragging:
		if _controller != null:
			_controller.set_rain_override(v)
		else:
			# No controller in this scene — slider drives the shader directly.
			var rain := get_tree().get_first_node_in_group(&"rain_layer") as RainLayer
			if rain != null:
				rain.set_amount(v)
	_rain_label.text = "%.2f" % v


func _resolve_rain_refs() -> void:
	_controller = get_tree().get_first_node_in_group(&"day_night_controller") as DayNightSceneController
	# Initial slider value: prefer the controller's current intensity if it
	# exists, otherwise fall back to whatever the shader is showing.
	if _controller != null:
		var v: float = _controller.get_rain_current_intensity()
		_rain_slider.set_value_no_signal(v)
		_rain_label.text = "%.2f" % v
		return
	var rain := get_tree().get_first_node_in_group(&"rain_layer") as RainLayer
	if rain == null:
		return
	var amount: float = rain.get_amount()
	_rain_slider.set_value_no_signal(amount)
	_rain_label.text = "%.2f" % amount


# While the overlay is visible and the user isn't actively dragging the rain
# slider, mirror the controller's current rain intensity into the slider so
# the user can SEE the event system working without having to read the shader.
func _process(_delta: float) -> void:
	if not visible:
		return
	_update_perf()
	if _rain_dragging or _controller == null:
		return
	var v: float = _controller.get_rain_current_intensity()
	_rain_slider.set_value_no_signal(v)
	_rain_label.text = "%.2f" % v


# fps / median+p95 frame time / draw calls / current stretch mode, sampled every
# frame and shown while the overlay is open. This is the readout for the fill A/B:
# force worst-case fill (rain slider -> 1.0), then flip "Pixel Grid" and compare.
# VIEWPORT recovering frames that CANVAS drops == fill-bound. See _dt_samples note
# on the web vsync cap — below refresh is the only regime this readout can see.
func _update_perf() -> void:
	var now := Time.get_ticks_usec()
	if _last_usec != 0:
		_dt_samples.append(float(now - _last_usec) / 1000.0)
		if _dt_samples.size() > _PERF_WINDOW:
			_dt_samples.remove_at(0)
	_last_usec = now

	# Refresh text a few times a second, not every frame — the string format is
	# far dearer than the sample and would itself perturb a fill measurement.
	_perf_refresh += 1
	if _perf_refresh < 6:
		return
	_perf_refresh = 0
	if _dt_samples.size() < 8:
		return
	var s := _dt_samples.duplicate()
	s.sort()
	var med: float = s[s.size() / 2]
	var p95: float = s[clampi(int(0.95 * float(s.size())), 0, s.size() - 1)]
	var draws: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var mode: String = (
		"VIEWPORT" if DisplayManager.get_stretch_mode() == Window.CONTENT_SCALE_MODE_VIEWPORT
		else "CANVAS"
	)
	_perf_label.text = "%.0f fps  %.1fms  p95 %.1fms\ndraws %d   %s" % [
		1000.0 / maxf(med, 0.001), med, p95, draws, mode
	]


func _on_passage_toggled(button_pressed: bool) -> void:
	TimeManager.paused = not button_pressed
	if _dragging:
		# Drag-restore should respect the user's new explicit choice.
		_prev_paused = TimeManager.paused


func _on_slider_drag_started() -> void:
	_dragging = true
	_prev_paused = TimeManager.paused
	TimeManager.paused = true


func _on_slider_drag_ended(_value_changed: bool) -> void:
	_dragging = false
	TimeManager.paused = _prev_paused
	_passage_toggle.set_pressed_no_signal(not TimeManager.paused)


func _on_slider_value_changed(v: float) -> void:
	if not _dragging:
		return
	TimeManager.set_time(v)
	# set_time emits time_changed; label refresh happens in _on_time_changed.


func _on_time_changed(t: float) -> void:
	if not _dragging:
		_time_slider.set_value_no_signal(min(t, _SLIDER_MAX))
	_update_time_label(t)


func _update_time_label(t: float) -> void:
	var total_min: int = int(t * 24.0 * 60.0)
	_time_label.text = "%02d:%02d" % [total_min / 60, total_min % 60]
