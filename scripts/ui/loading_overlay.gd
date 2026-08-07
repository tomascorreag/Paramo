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
#   set_status(key)     — phase label, by translation key (LOADING_TERRAIN, etc.)
#   set_progress(f)     — absolute bar fill, 0..1
#   pulse_toward(t)     — ease bar toward `t` (used while threaded generation
#                         runs and there's no fine-grained progress to show)
#   fade_out()          — await a short fade; caller frees the node after
# ============================================================================

# Colors from Palette.* (palette2). The progress bar + label text pick up the
# global theme (resources/ui/paramo_theme.tres); only the full-screen backdrop
# (ColorRect, no theme hook) and the dimmed status line are set here.
const _COL_BG := Palette.PANEL_BG    # 30 deep night
const _COL_DIM := Palette.TEXT_DIM   # 01 warm grey

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
	layer = UILayers.LOADING
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
	# The game's name — a proper noun, identical in both locales, so it is left as
	# literal text rather than given a key.
	title.text = "Páramo"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 24)
	box.add_child(title)

	_status_label = Label.new()
	_status_label.text = "LOADING_LOADING"
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_color_override("font_color", _COL_DIM)
	box.add_child(_status_label)

	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(220, 10)
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.value = 0.0
	_bar.show_percentage = false
	# Track + fill styleboxes come from the global theme's ProgressBar entry.
	box.add_child(_bar)


## Phase label. Takes a TRANSLATION KEY, not text — Label re-translates whatever
## sits in `text` when the locale changes, so a pre-translated string would freeze
## in whichever language was active when generation reached that phase.
func set_status(key: String) -> void:
	if _status_label != null:
		_status_label.text = key


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
