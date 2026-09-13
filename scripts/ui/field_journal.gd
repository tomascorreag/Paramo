class_name FieldJournal
extends CanvasLayer

## Full-screen "field journal" the player opens deliberately to read run status.
## Holds the season/weather gauge (a disc showing through a slot cut in the left
## page, PageSlit) and the run calendar beneath it (RunCalendar). Opened by the HUD
## journal button, the `toggle_journal` action
## (Space), and closed by that action or `pause` (Esc). Opening freezes the game with
## get_tree().paused; this layer runs PROCESS_MODE_ALWAYS so its slide animation and
## input keep working while everything else is frozen (same trick as PauseMenu).
##
## The Book (Book.png, 480x270 = the logical resolution) RISES up from below the
## bottom edge on open and DROPS back down on close. It slides by animating the
## full-rect Book's offset_top/offset_bottom together (both at _park_offset() hides it below, 0
## rests it) rather than `position` — a full-rect-anchored Control recomputes
## `position` from its anchors, so a position tween fights the layout; the offsets
## slide it vertically while keeping the horizontal anchoring and resolution
## independence intact. A dim scrim fades alongside the slide.

## Emitted the frame the book starts rising / dropping, not when the slide ends —
## a listener that wants "the player asked for the journal" must not wait 0.22 s
## for the animation. The FTUE hint strip advances off these.
signal opened
signal closed

## The book has two SPREADS — "run" (calendar, supplies, the shop) and
## "bitacora" (two discovered species, one page each) — and they share the
## two pages: every section under a page's Content carries a `spread` tag and
## `show_spread` flips visibility by it. Same SubViewports, same warp, same ink.
## Emitted whenever the spread or the species on the bitacora changes; the
## fore-edge tabs redraw off these. `species_changed` carries the LEFT page's.
signal spread_changed(spread: StringName)
signal species_changed(id: StringName)
## The set of browsable species changed (a find, or the codex binding): what
## the tabs and the corners can offer just moved.
signal browsable_changed

## Every species the bitacora can show, in AUTHORED order (the sprite sheet's
## row order). Filtered by the run's FloraCodex at read time: only identified
## species are browsable, and with no codex in the tree (preview tools, layout
## tests) all of them are — the same null-means-unrestricted rule the shop
## sections follow for UnlockState.
##
## Authored order rather than discovery order so prev/next is a stable ring:
## a species found later slots into its place instead of reshuffling the
## sequence the player has learnt.
@export var bitacora_species: Array[PlantObjectData] = []

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

var _spread: StringName = &"run"
## The LEFT page's species; the right page shows the next browsable one.
var _species: StringName = &""
var _codex: Node = null
## Per species, how many times its page has been shown this run — the field
## note printed is `fact_keys[count % size]`, so it rotates per showing.
var _fact_cursor: Dictionary = {}
## Every Content child of both pages: the sections `show_spread` toggles.
var _sections: Array[Control] = []


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
	_collect_sections()
	_apply_spread()
	# Deferred: FloraCodex joins its group in its own _ready, order unknown —
	# the same story as JournalKnownSet._bind_codex and JournalShopInput.
	_bind_codex.call_deferred()
	# Start the book parked below the bottom edge so the first open rises cleanly.
	var h := _park_offset()
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
	# Nothing here while the pause menu holds the game — this layer is
	# PROCESS_MODE_ALWAYS, so without the guard Space would throw the book open
	# on top of the modal (and Esc would close the book behind it). Returns
	# WITHOUT consuming: the key belongs to the pause menu.
	if PauseMenu.is_blocking():
		return
	# Space toggles from either state.
	if event.is_action_pressed(&"toggle_journal"):
		# ...but not before the run exists. `toggle_journal` is Space, and the
		# title screen's language gate commits on ui_accept, which Space also
		# fires: without this guard, picking a language with the keyboard also
		# throws the journal open over the opening cinematic. Anything that
		# consumes the event here would ALSO eat the gate's own key, so this
		# returns without handling it rather than swallowing it.
		# The cinematic keeps playing AFTER start_run (begun fires as it starts),
		# so the phase check alone still leaves Space opening the book over the
		# title. Both conditions, or neither is enough.
		if SeasonManager.phase != SeasonManager.Phase.ACTIVE \
				or not get_tree().get_nodes_in_group(&"title_intro").is_empty():
			return
		# ...and not before the FTUE has said what the book is. Same
		# no-consume rule: the key belongs to whatever else wants it.
		if not TutorialGate.allows(TutorialGate.Action.JOURNAL):
			return
		get_viewport().set_input_as_handled()
		toggle()
		return
	# Left/right page the bitacora while it is showing. Consumed: nothing
	# else under a paused tree wants them, and a key that fell through would
	# scroll whatever UI has focus.
	if _open and _spread == &"bitacora":
		if event.is_action_pressed(&"ui_left"):
			get_viewport().set_input_as_handled()
			prev_species()
			return
		if event.is_action_pressed(&"ui_right"):
			get_viewport().set_input_as_handled()
			next_species()
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
	opened.emit()
	# Opening the book on the bitacora is a showing too: the notes rotate.
	if _spread == &"bitacora":
		_set_species(_species, true)
	# Re-park stale offsets: if the window was resized while closed, the
	# stored park offset may no longer clear the bottom edge and the book
	# would pop in mid-rise.
	var h := _park_offset()
	_book.offset_top = maxf(_book.offset_top, h)
	_book.offset_bottom = _book.offset_top
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
	closed.emit()
	var h := _park_offset()
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


# Offset at which the book is fully below the bottom edge. BookArt is a
# centered 270-tall rect, so its top sits at offset + vp.y/2 - 135; hiding
# needs offset >= vp.y/2 + 135. The old `offset = vp.y` only cleared it when
# vp.y >= 270 — at the default windowed logical height (202) the book's top
# 34 px popped in/out. +2 covers EXPAND nudging the logical height a pixel.
func _park_offset() -> float:
	return get_viewport().get_visible_rect().size.y * 0.5 + 137.0


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


# --- Spreads -----------------------------------------------------------------

# Every tagged section under both pages' Content, plus anything tagged
# directly under Pages — the season slit is a SubViewportContainer beside the
# pages, not a section inside one, and it belongs to the run spread too.
func _collect_sections() -> void:
	_sections.clear()
	var pages := get_node_or_null("Book/BookArt/Pages") as Control
	if pages == null:
		return
	var parents: Array[Node] = [pages]
	for page_name: String in ["PageLeft", "PageRight"]:
		var content := pages.get_node_or_null("%s/SubViewport/Content" % page_name)
		if content != null:
			parents.append(content)
	for parent: Node in parents:
		for child: Node in parent.get_children():
			var c := child as Control
			if c != null and c.get(&"spread") != null:
				_sections.append(c)


## The spread showing right now: &"run" or &"bitacora".
func spread() -> StringName:
	return _spread


## Turn to a spread. Persists across close/open — a book stays where you left
## it. Turning to the bitacora with no species chosen picks the first
## browsable one; with NOTHING identified the bitácora is closed and the
## turn is refused.
func show_spread(name_: StringName) -> void:
	if name_ != &"run" and name_ != &"bitacora":
		return
	if name_ == &"bitacora":
		if not has_bitacora():
			return
		if _species == &"" or not is_readable(_species):
			_set_species(_first_browsable(), true)
	var changed: bool = name_ != _spread
	_spread = name_
	_apply_spread()
	if changed:
		spread_changed.emit(_spread)


func _apply_spread() -> void:
	for c: Control in _sections:
		if is_instance_valid(c):
			c.visible = StringName(c.get(&"spread")) == _spread


## The LEFT page's species, or &"" while the book has never been turned to
## the bitácora.
func species() -> StringName:
	return _species


## Both pages' species, left then right; a page with nothing on it is &"".
func page_species() -> Array[StringName]:
	var right: StringName = &""
	var ids := browsable_species()
	var i: int = ids.find(String(_species))
	if i >= 0 and i + 1 < ids.size():
		right = StringName(ids[i + 1])
	return [_species, right]


## Whether `id` is on either open page right now.
func shows(id: StringName) -> bool:
	return id != &"" and page_species().has(id)


## Species ids the bitacora may show, in authored order: those the run's codex
## has recorded, or all of them with no codex in the tree.
func browsable_species() -> PackedStringArray:
	var out := PackedStringArray()
	var codex_live: bool = _codex != null and is_instance_valid(_codex)
	for data: PlantObjectData in bitacora_species:
		if data == null:
			continue
		if not codex_live or bool(_codex.call(&"is_known", data.id)):
			out.append(String(data.id))
	return out


## Whether the bitacora may open at `id` — i.e. whether the shop's read verb
## has anywhere to go. False for anything that is not a species at all.
func is_readable(id: StringName) -> bool:
	return id != &"" and browsable_species().has(String(id))


## Whether the bitácora can be opened at all: something has been identified.
## Until then it has no tab, no page and no corner.
func has_bitacora() -> bool:
	return not browsable_species().is_empty()


## Open the bitacora with `id` in view. The book turns in PAIRS from the first
## browsable species, so `id` lands on the left page when it is at an even
## position in the ring and on the right when odd — the same two pages it
## would be on if you paged there. False (and no change) when not browsable.
func show_species(id: StringName) -> bool:
	if not is_readable(id):
		return false
	var ids := browsable_species()
	var i: int = ids.find(String(id))
	_set_species(StringName(ids[i - (i % 2)]), true)
	show_spread(&"bitacora")
	return true


## The book as ONE sequence of spreads, for the page corners: the run spread
## is page 0, then the bitácora's pairs in browsable order — none while
## nothing is identified. `page_index()` is where the book is open now.
func page_index() -> int:
	if _spread != &"bitacora":
		return 0
	var i: int = browsable_species().find(String(_species))
	return 1 + maxi(0, i) / 2


func page_count() -> int:
	return 1 + (browsable_species().size() + 1) / 2


## Turn `delta` pages along that sequence; false at either cover (no wrap —
## a book does not).
func turn_page(delta: int) -> bool:
	var target: int = page_index() + delta
	if target < 0 or target >= page_count() or target == page_index():
		return false
	if target == 0:
		show_spread(&"run")
		return true
	show_species(StringName(browsable_species()[(target - 1) * 2]))
	return true


func next_species() -> void:
	_step_species(2)


func prev_species() -> void:
	_step_species(-2)


func _step_species(delta: int) -> void:
	var ids := browsable_species()
	if ids.is_empty():
		_set_species(&"", false)
		return
	var i: int = ids.find(String(_species))
	if i < 0:
		_set_species(StringName(ids[0]), true)
		return
	# Pairs: the ring is the even positions, wrapping.
	var pairs: int = (ids.size() + 1) / 2
	var pair: int = posmod(i / 2 + (delta / 2), pairs)
	_set_species(StringName(ids[pair * 2]), true)


func _first_browsable() -> StringName:
	var ids := browsable_species()
	return StringName(ids[0]) if not ids.is_empty() else &""


func _data_for(id: StringName) -> PlantObjectData:
	for data: PlantObjectData in bitacora_species:
		if data != null and data.id == id:
			return data
	return null


## The left and right plates, in that order (null where the scene lacks one).
func _plates() -> Array[JournalSpeciesPlate]:
	return [
		get_node_or_null("%SpeciesPlateLeft") as JournalSpeciesPlate,
		get_node_or_null("%SpeciesPlateRight") as JournalSpeciesPlate,
	]


# Writes the pair starting at `id` into the two plates; a page with no
# species is blank. `showing` counts as a showing for the note rotation; a
# silent re-validation does not.
func _set_species(id: StringName, showing: bool) -> void:
	var changed: bool = id != _species
	_species = id
	var pair := page_species()
	var plates := _plates()
	for n: int in plates.size():
		var plate := plates[n]
		if plate == null:
			continue
		var pid: StringName = pair[n]
		if pid == &"":
			plate.set_blank()
			continue
		if showing:
			_fact_cursor[pid] = int(_fact_cursor.get(pid, -1)) + 1
		plate.set_species(_data_for(pid), int(_fact_cursor.get(pid, 0)))
	if changed:
		species_changed.emit(_species)


func _bind_codex() -> void:
	if not is_inside_tree():
		return
	var codex: Node = get_tree().get_first_node_in_group(FloraCodex.GROUP)
	if codex == null:
		return
	_codex = codex
	codex.connect(&"discovered", _on_codex_changed)
	_revalidate_species()


func _on_codex_changed(_species_: StringName) -> void:
	_revalidate_species()


# The codex clears at season 0 and grows on every find. The left page keeps
# its species if it is still browsable AND still on an even position (a find
# earlier in the ring shifts the pairs); otherwise the book drops back to the
# pair that species is now in, or to the first pair — or, with nothing left
# to show, closes the bitácora and turns back to the run spread.
func _revalidate_species() -> void:
	if _spread != &"bitacora":
		# Nothing is showing; the next turn to the bitacora re-picks anyway.
		if _species != &"" and not is_readable(_species):
			_species = &""
	elif not has_bitacora():
		_species = &""
		show_spread(&"run")
	else:
		var ids := browsable_species()
		var i: int = ids.find(String(_species))
		if i < 0:
			_set_species(_first_browsable(), false)
		else:
			_set_species(StringName(ids[i - (i % 2)]), false)
	browsable_changed.emit()
