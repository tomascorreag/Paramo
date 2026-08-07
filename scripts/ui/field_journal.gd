class_name FieldJournal
extends CanvasLayer

## Full-screen "field journal" the player opens deliberately to read run status.
## Holds the season/weather gauge (a disc showing through a slot cut in the left
## page, PageSlit) and the run calendar beneath it (RunCalendar). Opened by the HUD
## journal button, the `toggle_journal` action
## (J), and closed by that action or `pause` (Esc). Opening freezes the game with
## get_tree().paused; this layer runs PROCESS_MODE_ALWAYS so its slide animation and
## input keep working while everything else is frozen (same trick as PauseMenu).
##
## The Book (Book.png, 480x270 = the logical resolution) RISES up from below the
## bottom edge on open and DROPS back down on close. It slides by animating the
## full-rect Book's offset_top/offset_bottom together (both +H hides it below, 0
## rests it) rather than `position` — a full-rect-anchored Control recomputes
## `position` from its anchors, so a position tween fights the layout; the offsets
## slide it vertically while keeping the horizontal anchoring and resolution
## independence intact. A dim scrim fades alongside the slide.

const _OPEN_DURATION: float = 0.22
const _CLOSE_DURATION: float = 0.14

## Season wheel sprite is 64x64; rotate around its center (mirrors the old HUD gauge).
const _WHEEL_PIVOT: Vector2 = Vector2(32, 32)

@onready var _book: Control = %Book
@onready var _dim: ColorRect = %Dim
@onready var _season_wheel: TextureRect = %SeasonWheel

## The three page/gauge SubViewports. Each is its own render target, so leaving
## them on UPDATE_ALWAYS costs three extra render passes (plus a page_warp and a
## journal_ink pass) EVERY frame of the run, for a book that is off screen almost
## all of it — UPDATE_ALWAYS does not consult visibility, that is the whole
## difference from UPDATE_WHEN_VISIBLE. They are authored DISABLED and switched on
## with the layer below. UPDATE_WHEN_VISIBLE would not do this on its own: these
## hang under a CanvasLayer, and a CanvasLayer's `visible` is not part of the
## CanvasItem visible-in-tree chain the viewport tests.
var _page_viewports: Array[SubViewport] = []

var _open: bool = false
var _tween: Tween


func _ready() -> void:
	# ALWAYS so the slide + input keep running under get_tree().paused (like PauseMenu).
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = UILayers.JOURNAL
	add_to_group(&"journal")
	visible = false
	# Click anywhere on the scrim (outside the book art — BookHit absorbs clicks on
	# the book itself) closes the journal.
	_dim.gui_input.connect(_on_dim_gui_input)
	_season_wheel.pivot_offset = _WHEEL_PIVOT
	# Driven off `visibility_changed` rather than from open()/close() so the
	# preview/verify tools — which skip open() and set `visible` directly to
	# render a still — get their pages rendered too.
	_collect_page_viewports()
	visibility_changed.connect(_sync_page_viewports)
	_sync_page_viewports()
	# Start the book parked below the bottom edge so the first open rises cleanly.
	var h := _viewport_height()
	_book.offset_top = h
	_book.offset_bottom = h
	_dim.modulate.a = 0.0


# The season wheel turns continuously with the season clock: a half-turn (180°)
# per season, so the current season's weather sits at the top exactly when that
# season begins. (day_count + time_of_day) is a continuous, monotonic season clock.
# While the journal is open the game is paused, so the clock is frozen and the
# wheel holds a snapshot of the moment you opened it. (Logic moved verbatim from
# the old HUD gauge; ungated by visibility so test_season_wheel can drive it.)
func _process(_delta: float) -> void:
	if SeasonManager.phase == SeasonManager.Phase.IDLE:
		_season_wheel.rotation = 0.0
		return
	var dps: float = maxf(1.0, float(SeasonManager.days_per_season))
	var seasons_elapsed: float = (TimeManager.day_count + TimeManager.time_of_day) / dps
	_season_wheel.rotation = deg_to_rad(seasons_elapsed * 180.0)


func _input(event: InputEvent) -> void:
	# J toggles from either state.
	if event.is_action_pressed(&"toggle_journal"):
		get_viewport().set_input_as_handled()
		toggle()
		return
	# Esc closes ONLY while open, and is consumed here in _input — which runs before
	# PauseMenu's _unhandled_input — so Esc backs out of the journal instead of
	# opening the pause menu on top of it. When closed, Esc falls through to the
	# pause menu unchanged.
	if _open and event.is_action_pressed(&"pause"):
		get_viewport().set_input_as_handled()
		close()


func _on_dim_gui_input(event: InputEvent) -> void:
	if not _open:
		return
	if event is InputEventMouseButton and event.pressed \
			and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		get_viewport().set_input_as_handled()
		close()


func toggle() -> void:
	if _open:
		close()
	else:
		open()


func open() -> void:
	if _open:
		return
	_open = true
	visible = true
	get_tree().paused = true
	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = create_tween().set_parallel(true)
	_tween.tween_property(_book, "offset_top", 0.0, _OPEN_DURATION) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_tween.tween_property(_book, "offset_bottom", 0.0, _OPEN_DURATION) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_tween.tween_property(_dim, "modulate:a", 1.0, _OPEN_DURATION * 0.6)


func close() -> void:
	if not _open:
		return
	_open = false
	var h := _viewport_height()
	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = create_tween().set_parallel(true)
	_tween.tween_property(_book, "offset_top", h, _CLOSE_DURATION).set_ease(Tween.EASE_IN)
	_tween.tween_property(_book, "offset_bottom", h, _CLOSE_DURATION).set_ease(Tween.EASE_IN)
	_tween.tween_property(_dim, "modulate:a", 0.0, _CLOSE_DURATION)
	# Unpause + hide only once the drop finishes, so the animation actually plays.
	_tween.chain().tween_callback(func() -> void:
		visible = false
		get_tree().paused = false
	)


func _viewport_height() -> float:
	return get_viewport().get_visible_rect().size.y


func _collect_page_viewports() -> void:
	# "*" not "" — the pattern goes through String.match(), where an empty
	# pattern matches only an empty name, i.e. nothing.
	for node: Node in find_children("*", "SubViewport", true, false):
		_page_viewports.append(node as SubViewport)


# ALWAYS while shown: the pages animate (the book slides, the calendar and the
# wheel move), so UPDATE_ONCE would freeze the first frame. DISABLED while
# hidden keeps the last rendered frame in the target, which is what the container
# shows for the one frame between `visible = true` and the child viewport's next
# render — harmless, since the book is still parked off the bottom edge then.
func _sync_page_viewports() -> void:
	var mode := SubViewport.UPDATE_ALWAYS if visible else SubViewport.UPDATE_DISABLED
	for vp: SubViewport in _page_viewports:
		vp.render_target_update_mode = mode
