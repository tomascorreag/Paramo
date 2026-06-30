class_name LoadingOverlay
extends CanvasLayer

# ============================================================================
# LoadingOverlay
# ============================================================================
#
# Full-screen cover shown during procedural world generation at startup. Lives
# above all gameplay layers (high `layer`) so the freshly-painted terrain and
# its shaders draw BENEATH it — by the time the overlay fades out, WebGL has
# already compiled the water / post-process / rain shaders, so the first visible
# gameplay frame doesn't stutter.
#
# Built entirely in code (no .tscn) so it has no scene/import dependency and
# can be spawned from any context. All RGB values come from
# assets/palettes/palette2.txt (alpha is free; RGB is locked).
#
# Driving API (called by ProceduralWorld's async startup):
#   set_status(text)    — phase label ("Generando terreno…", etc.)
#   set_progress(f)     — absolute bar fill, 0..1
#   pulse_toward(t)     — ease bar toward `t` (used while threaded generation
#                         runs and there's no fine-grained progress to show)
#   fade_out()          — await a short fade; caller frees the node after
# ============================================================================

# Palette indices: 30 (deep night), 23 (near-white), 01 (warm grey),
# 28 (dusk blue), 20 (paramo green).
const _COL_BG := Color(0x14 / 255.0, 0x23 / 255.0, 0x3A / 255.0, 1.0)
const _COL_TEXT := Color(0xF1 / 255.0, 0xF6 / 255.0, 0xF0 / 255.0, 1.0)
const _COL_DIM := Color(0x87 / 255.0, 0x85 / 255.0, 0x7C / 255.0, 1.0)
const _COL_TRACK := Color(0x40 / 255.0, 0x52 / 255.0, 0x73 / 255.0, 1.0)
const _COL_FILL := Color(0x89 / 255.0, 0xA4 / 255.0, 0x77 / 255.0, 1.0)

# Easing factor for pulse_toward — per-call lerp weight. Called once per frame
# during the generation poll loop, so this is effectively per-frame smoothing.
const _PULSE_WEIGHT: float = 0.08

var _canvas: Control
var _bar: ProgressBar
var _status_label: Label
var _bar_value: float = 0.0


func _ready() -> void:
	# Above HUD / world; PROCESS_MODE_ALWAYS so the fade tween runs even if the
	# tree is paused (planning phase pauses the simulation in this game).
	layer = 128
	process_mode = Node.PROCESS_MODE_ALWAYS

	_canvas = Control.new()
	_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Eat input so clicks during load don't reach gameplay underneath.
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_canvas)

	var bg := ColorRect.new()
	bg.color = _COL_BG
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(bg)

	var box := VBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 10)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(box)

	var title := Label.new()
	title.text = "Páramo"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_color", _COL_TEXT)
	title.add_theme_font_size_override("font_size", 24)
	box.add_child(title)

	_status_label = Label.new()
	_status_label.text = "Cargando…"
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_color_override("font_color", _COL_DIM)
	box.add_child(_status_label)

	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(220, 10)
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.value = 0.0
	_bar.show_percentage = false
	var sb_bg := StyleBoxFlat.new()
	sb_bg.bg_color = _COL_TRACK
	sb_bg.set_corner_radius_all(3)
	var sb_fg := StyleBoxFlat.new()
	sb_fg.bg_color = _COL_FILL
	sb_fg.set_corner_radius_all(3)
	_bar.add_theme_stylebox_override("background", sb_bg)
	_bar.add_theme_stylebox_override("fill", sb_fg)
	box.add_child(_bar)


func set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text


func set_progress(f: float) -> void:
	_bar_value = clampf(f, 0.0, 1.0)
	if _bar != null:
		_bar.value = _bar_value


# Ease the bar toward `target` without overshooting it — used while the worker
# thread generates the grid (no measurable sub-progress), so the bar drifts
# forward instead of sitting frozen.
func pulse_toward(target: float) -> void:
	_bar_value = lerpf(_bar_value, clampf(target, 0.0, 1.0), _PULSE_WEIGHT)
	if _bar != null:
		_bar.value = _bar_value


func fade_out() -> void:
	var tw := create_tween()
	tw.tween_property(_canvas, "modulate:a", 0.0, 0.35)
	await tw.finished
