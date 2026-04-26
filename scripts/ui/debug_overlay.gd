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

var _dragging: bool = false
var _prev_paused: bool = false


func _ready() -> void:
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
	TimeManager.time_changed.connect(_on_time_changed)


func _on_debug_enabled_changed(is_enabled: bool) -> void:
	visible = is_enabled
	if is_enabled:
		_sync_from_time_manager()


func _sync_from_time_manager() -> void:
	_passage_toggle.set_pressed_no_signal(not TimeManager.paused)
	_time_slider.set_value_no_signal(min(TimeManager.time_of_day, _SLIDER_MAX))
	_update_time_label(TimeManager.time_of_day)
	_indices_toggle.set_pressed_no_signal(Debug.show_tile_indices)
	_altitudes_toggle.set_pressed_no_signal(Debug.show_tile_altitudes)


func _on_indices_toggled(button_pressed: bool) -> void:
	Debug.show_tile_indices = button_pressed


func _on_altitudes_toggled(button_pressed: bool) -> void:
	Debug.show_tile_altitudes = button_pressed


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
