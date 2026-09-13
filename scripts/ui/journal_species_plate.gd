@tool
class_name JournalSpeciesPlate
extends Control

## One species' PAGE in the journal's bitacora spread — everything the book
## knows about it on one sheet. The spread shows two of these, one per page.
##
##     frailejón                       <- common name, the title face (block 0)
##     Espeletia grandiflora           <- binomial, Tiny5 at 8       (block 1)
##        [0] [1] [2] [3]              <- the four growth stages, one row,
##                                        stood on row 52             (blocks 1-2)
##     ┌─────────┬─────────┐
##     │ ╔═════╗ │ hasta.. │           <- four QUADRANTS, 78x79 each: the game
##     │ ║photo║ │ 3450..  │              facts, the pressed sheet, the field
##     │ ╚═════╝ │ ...     │              photograph, and ONE field note. Which
##     ├─────────┼─────────┤              goes where is drawn per species —
##     │ Its pith│ ╔═════╗ │              `arrangement()` — so no two pages
##     │ stores..│ ║photo║ │              are pasted up alike.
##     │         │ ╚═════╝ │           (blocks 3-7 and 7-11: a polaroid is 79 rows)
##     └─────────┴─────────┘
##
## Everything is drawn or a child TextureRect, nothing is a Label — the same
## rule as every other section on these pages (see JournalTitle's header: the
## page warp quantises to 18-row blocks and a Label's line box does not respect
## that).
##
## THE NAME IS THE TITLE FACE (`name_font`, FantasticBoogaloo at 16 — the
## journal's heading face since 2026-09-11; it was Eggmode, which has no
## accented glyph, and a species' common name is exactly the kind of word
## that carries one: "frailejón", "paja de páramo"). Set the way JournalTitle
## sets a heading, without the rule: a 17-row line box pushed down by the
## 1-row inset fills block 0 with zero slack. The binomial is one Tiny5-8 line
## in the top half of block 1, in place of a rule.
##
## THE GROWTH STAGES stand in ONE ROW on row 52 — two rows clear of the
## quadrants' top at 54, so the plants do not touch the polaroids' corners —
## packed by their INK (the sprites carry a lot of transparent margin, and a
## grid of 36-px cells spread four small plants across half the page) and
## centred. The tallest ink of any species is 24 rows, so from 52 down a stage
## reaches row 28 at most, clear of the binomial's line (ends 26) and inside
## blocks 1-2, the two a 24-row run needs. 52 is a REQUEST, like every
## `header_gap_px` in the book: the row stands where `stage_stand_px()` puts
## it, the nearest row to the request at which every stage's ink is clean
## (JournalBlocks.snap_top, the whole row together so the feet stay level).
## One species needs it: E. barclayana's third stage is exactly 18 rows of
## ink, which is only clean sitting exactly on a block, so its row stands on
## 54 — the polaroids' top, as the whole row did before the request.
## Inked, as on the shop row — they ARE pixel art, so the ramps make them the
## book's brown-and-green.
##
## THE QUADRANTS. From row 54 the page is cut in four, 78 columns by 79 rows,
## and each holds one thing: the game facts (`Kind.FACTS`), the herbarium
## sheet (`Kind.SHEET`), the field photograph (`Kind.FIELD`) and the field note
## (`Kind.NOTE`). 79 rows is the polaroid frame's height, so a picture fills
## its quadrant exactly: the top row's from 54 spans blocks 3-7 and the bottom
## row's from 133 spans 7-11, five blocks each, the fewest 79 rows can take,
## and the bottom one ends on row 212 of 213. Text in a quadrant starts on the
## first 9-row line top at or under the quadrant's top (54, or 135 for the
## bottom row) and has eight lines to the quadrant's foot — every such line
## nests in its block, since two lines make one. The arrangement is one of
## 12: the NOTE is always on the bottom row (left or right — it is the one
## thing that reads as a caption, and a caption goes under the pictures), and
## the other three take the remaining quadrants in any order. Picked by a
## hash of the species id: stable for a species, different between species,
## and the same in every locale and test.
##
## THE PHOTOS ARE POLAROIDS, AND THEY ARE NOT DRAWN IN THE PAGE. The page's
## content is a 157x231 SubViewport at one texel per logical pixel, so a
## picture drawn inside it is pixel art by construction. Each photograph (the
## GBIF CC0 herbarium sheet and the iNaturalist CC0 field photo, baked to
## 216x216 by scripts/tools/bake_flora_photos.gd — the copies currently shown
## are the ones SNAPPED to the palette) is instead handed to a
## JournalPhotoFloat this plate owns: a linear-filtered TextureRect OVER the
## book at window resolution, bent to the page by photo_warp.gdshader with the
## page's own curves so it never floats off the warped type around it. A
## second float on top of each carries the polaroid frame (PolaroidFrame.png,
## 68x79 at 1:1, nearest-filtered): the 54x54 photograph sits in the frame's
## window at (7, 7), and the frame's gold corner ornaments are what say "stuck
## in". This plate keeps the GEOMETRY — `frame_rects()` and `photo_rects()` in
## its own space — and the floats render it. A polaroid stuck into a field
## notebook is the one thing on these pages that is not ink, the way the
## season disc is not ink either, so the polaroids are EXEMPT from the
## rendered-palette audit (verify_journal_palette.gd masks them on this spread).
##
## THE GAME FACTS ARE PHRASES, NOT "label: value" PAIRS — "Suelo seco",
## "Crecimiento rápido", sentence-cased here over lowercase CSV chrome, with
## the mountains as the proper nouns they are — and they are words, not numbers: `water_affinity`
## 0.005 and `growth_chance` 0.01 are tuning values in units nothing shows,
## bucketed at thresholds set from the authored range (dev-notes/flora.md,
## "Bitácora"). The altitude band is turned back into metres with the placement
## note's h ≈ (m − 3000)/37.5. No price: this is a notebook page, not a tag.
## In a 72-px column a phrase may wrap ("en chingaza, guerrero y nevados"
## does), and the six of them must fit the quadrant's eight lines.
##
## ONE FIELD NOTE, ROTATING. A species has 2-3 researched facts (`fact_keys`)
## and the page prints one; which one is `fact_index`, and FieldJournal advances
## it every time the page is shown, so the note changes each time the book is
## opened to it. It word-wraps (draw_multiline_string, which advances by exactly
## Font.get_height per line — 9 for Tiny5 at 8, two lines a block) in its
## quadrant, and tests/test_journal_bitacora.gd measures every fact's wrapped
## height in both locales against the quadrant's eight lines.

## What a quadrant holds.
enum Kind { FACTS, SHEET, FIELD, NOTE }

## Which spread this section belongs to. FieldJournal.show_spread flips
## visibility on every section by this tag.
@export var spread: StringName = &"bitacora"

## Every mountain the game can draw, so "grows in" can list the ones this
## species is on. The three resources/ecosystems/*.tres.
@export var ecosystems: Array[EcosystemProfile] = []:
	set(value):
		ecosystems = value
		queue_redraw()

@export_group("Type")
## The data face — Tiny5, at `font_size` for everything but the name. Null
## falls back to the theme's Label font.
@export var font: Font = null:
	set(value):
		font = value
		_relayout()

## The heading face, as on every other journal title. Null falls back to `font`.
@export var name_font: Font = null:
	set(value):
		name_font = value
		_relayout()

## Size of the common name. 16 in the title face is a 17-row line box: one
## block with JournalTitle's inset.
@export var name_font_size: int = 16:
	set(value):
		name_font_size = value
		_relayout()

## Size of the data lines. 8 gives a 9-row line box, two per block.
@export var font_size: int = 8:
	set(value):
		font_size = value
		_relayout()

@export var text_color: Color = Palette.P06:
	set(value):
		text_color = value
		queue_redraw()

## The polaroid frame around each photograph, drawn at 1:1 over the book.
@export var frame_texture: Texture2D = preload("res://assets/sprites/UX/Panels/PolaroidFrame.png"):
	set(value):
		frame_texture = value
		_relayout()

## Where the photograph sits inside the frame sprite, and how big it is.
## Measured on PolaroidFrame.png: a 3-texel white border from (4, 4), the
## window at (7, 7), 54x54, then a wider white foot; gold corners overhang.
@export var frame_window_px: Rect2i = Rect2i(7, 7, 54, 54):
	set(value):
		frame_window_px = value
		_relayout()

@export_group("Layout")
## The page's warp quantisation. Keep equal to the page's `row_block_px`.
@export var block_px: int = 18:
	set(value):
		block_px = value
		_relayout()

## Line-box top of the binomial: block 1's top, right under the name.
@export var subtitle_top_px: int = 18:
	set(value):
		subtitle_top_px = value
		_relayout()

## Row the growth stages' ink STANDS on (exclusive), as REQUESTED: two rows
## above the quadrants' top, the margin left under the plants. Resolved by
## `stage_stand_px()` to the nearest row that inks clean.
@export var stages_bottom_px: int = 52:
	set(value):
		stages_bottom_px = value
		_relayout()

## Columns between one stage's ink and the next's.
@export var stage_gap_px: int = 4:
	set(value):
		stage_gap_px = value
		_relayout()

## Top of the quadrants: a block boundary, so the top row's polaroid and text
## both start clean.
@export var quadrants_top_px: int = 54:
	set(value):
		quadrants_top_px = value
		_relayout()

## Height of a quadrant row: the polaroid frame's 79 rows, so a picture fills
## its quadrant and two of them fill the page to row 212.
@export var quadrant_rows_px: int = 79:
	set(value):
		quadrant_rows_px = value
		_relayout()

@export_group("Ink")
## Applied to the growth stages. Shared, not duplicated: nothing here fades per
## entry, so one material serves the page. The photos do NOT take it.
@export var ink_material: ShaderMaterial = null:
	set(value):
		ink_material = value
		_relayout()

## Lead-in from a quadrant's left edge to its text, on the 4-texel column grid.
const _TEXT_LEFT_PX: int = 4
## Right margin inside a quadrant, so a wrapped line never touches the next
## quadrant or the page's outer edge.
const _TEXT_RIGHT_PX: int = 2

## Real elevation from a placement half-step: dev-notes/flora.md, "Altitude".
const _M_PER_STEP: float = 37.5
const _M_AT_ZERO: float = 3000.0
const _M_ROUND: int = 50

## Bucket thresholds, set from the authored ranges of the eight species.
const _TRAMPLE_STURDY_FROM: float = 0.7
const _TRAMPLE_TOUGH_FROM: float = 1.6
const _GROWTH_STEADY_FROM: float = 0.025
const _GROWTH_FAST_FROM: float = 0.05

var _data: PlantObjectData = null
## Which of `fact_keys` prints; FieldJournal advances it per showing.
var fact_index: int = 0
## Print nothing at all (the facing page of an odd last species).
var _blank: bool = false
var _stage_rects: Array[TextureRect] = []
## The photographs and, above each, its polaroid frame, all floating over the
## book (see the header): [sheet, sheet frame, field, field frame]. Created on
## first use and parented to BookArt, the page container's grandparent — the
## same home as the shop tooltip, and for the same reason: above the paper.
var _floats: Array[JournalPhotoFloat] = []


func _ready() -> void:
	# Ink on paper takes no input, and the page's SubViewport sets
	# gui_disable_input anyway.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The floats live outside this node's subtree, so they have to be told.
	visibility_changed.connect(_sync_floats)
	tree_exiting.connect(_drop_floats)
	_relayout()


## The floating photographs, in `photos()` order. For the tests.
func photo_floats() -> Array[JournalPhotoFloat]:
	var out: Array[JournalPhotoFloat] = []
	for i: int in _floats.size():
		if i % 2 == 0 and is_instance_valid(_floats[i]):
			out.append(_floats[i])
	return out


## The floating polaroid frames, in `photos()` order.
func frame_floats() -> Array[JournalPhotoFloat]:
	var out: Array[JournalPhotoFloat] = []
	for i: int in _floats.size():
		if i % 2 == 1 and is_instance_valid(_floats[i]):
			out.append(_floats[i])
	return out


# The page container this plate is drawn into (Content -> SubViewport -> PageWarp)
# and the node the floats hang under (Pages -> BookArt).
func _page() -> PageWarp:
	var content := get_parent()
	if content == null or content.get_parent() == null:
		return null
	return content.get_parent().get_parent() as PageWarp


func _float_host() -> Control:
	var page := _page()
	if page == null or page.get_parent() == null:
		return null
	return page.get_parent().get_parent() as Control


func _sync_floats() -> void:
	var on: bool = is_visible_in_tree() and _data != null
	for f: JournalPhotoFloat in _floats:
		if is_instance_valid(f):
			f.visible = on and f.texture != null


# queue_free only: this fires from tree_exiting, when the parent may be in the
# middle of removing children and remove_child is refused.
func _drop_floats() -> void:
	for f: JournalPhotoFloat in _floats:
		if is_instance_valid(f):
			f.queue_free()
	_floats.clear()


## Show one species, printing its `fact_keys[index]`. Null is `set_blank`.
func set_species(data: PlantObjectData, index: int = 0) -> void:
	_data = data
	_blank = data == null
	fact_index = maxi(0, index)
	_relayout()


## Print nothing at all — the right page when the book has an odd number of
## species to show.
func set_blank() -> void:
	set_species(null)


func species() -> PlantObjectData:
	return _data


func is_empty() -> bool:
	return _data == null


## Rows the common name is charged: the whole blocks its line box needs
## (one) — JournalTitle's arithmetic, without a rule.
func name_row_px() -> int:
	return JournalTitle.row_px(active_name_font(), name_font_size, block_px, false)


func active_name_font() -> Font:
	return name_font if name_font != null else active_font()


## The common name as printed: translated, then cased like every other
## journal heading (JournalTitle.cased — "Frailejón", "Frailejon Motoso").
## The key itself stays lowercase; the shop tooltip and the discovery toast
## print it as authored.
func name_text() -> String:
	return JournalTitle.cased(tr(String(_data.name_key))) if _data != null else ""


## Height of one data line's box (9 for Tiny5 at 8).
func line_px() -> int:
	var f := active_font()
	return int(ceilf(f.get_height(font_size))) if f != null else font_size


func active_font() -> Font:
	return font if font != null else get_theme_font(&"font", &"Label")


# --- the quadrants ------------------------------------------------------------

## Quadrant `q` (0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right) in
## this node's local space. The left column takes the floor of half the page;
## the right takes the rest (79 of 157).
func quadrant_rect(q: int) -> Rect2i:
	var w: int = int(size.x)
	var half: int = w / 2
	var col: int = q % 2
	var row: int = q / 2
	return Rect2i(col * half, quadrants_top_px + row * quadrant_rows_px,
			half if col == 0 else w - half, quadrant_rows_px)


## What each quadrant holds, indexed by quadrant: the note on the bottom row,
## the other three kinds in one of their six orders over the rest — 12
## arrangements, drawn from the species id. Deterministic, so a page is
## pasted up the same way every time it is opened and in every test.
func arrangement() -> Array[Kind]:
	var kinds: Array[Kind] = [Kind.FACTS, Kind.SHEET, Kind.FIELD]
	if _data == null:
		return [Kind.FACTS, Kind.SHEET, Kind.FIELD, Kind.NOTE]
	var n: int = absi(hash(String(_data.id))) % 12
	var note_q: int = 2 + n % 2
	# Lehmer code: the rest, mod 6, decoded digit by digit into an order of
	# the three other kinds.
	n /= 2
	var order: Array[Kind] = []
	for radix: int in [2, 1]:
		order.append(kinds.pop_at(n / radix))
		n %= radix
	order.append(kinds[0])
	var out: Array[Kind] = []
	for q: int in 4:
		out.append(Kind.NOTE if q == note_q else order.pop_front())
	return out


## The quadrant holding `kind`.
func quadrant_of(kind: Kind) -> int:
	return arrangement().find(kind)


## Line-box top of the first text line in quadrant `q`: the first 9-row line
## top at or under the quadrant's top, so every line nests in its block.
func text_top_px(q: int) -> int:
	var line: int = maxi(1, line_px())
	var top: int = quadrant_rect(q).position.y
	return int(ceilf(float(top) / float(line))) * line


## Whole lines a text quadrant holds between its first line top and its foot.
func text_lines_max(q: int) -> int:
	var r := quadrant_rect(q)
	return (r.end.y - text_top_px(q)) / maxi(1, line_px())


## Left edge of a quadrant's text.
func text_left_px(q: int) -> int:
	return quadrant_rect(q).position.x + _TEXT_LEFT_PX


## Width a phrase or note line may wrap in inside quadrant `q`.
func text_width_px(q: int) -> int:
	return quadrant_rect(q).size.x - _TEXT_LEFT_PX - _TEXT_RIGHT_PX


## The photographs this page has, in float order: the herbarium sheet, then
## the field photo. Null slots are skipped, so a species with one picture has
## one polaroid and an empty quadrant.
func photos() -> Array[Texture2D]:
	var out: Array[Texture2D] = []
	if _data == null:
		return out
	for tex: Texture2D in [_data.photo, _data.photo_live]:
		if tex != null:
			out.append(tex)
	return out


## The quadrant each of `photos()` is pasted in.
func photo_quadrants() -> Array[int]:
	var out: Array[int] = []
	if _data == null:
		return out
	if _data.photo != null:
		out.append(quadrant_of(Kind.SHEET))
	if _data.photo_live != null:
		out.append(quadrant_of(Kind.FIELD))
	return out


## Where each polaroid frame is printed, in this node's local space: centred
## across its quadrant, flush with its top, 79 rows to its foot.
func frame_rects() -> Array[Rect2i]:
	var out: Array[Rect2i] = []
	if frame_texture == null:
		return out
	var fsz := Vector2i(frame_texture.get_size())
	for q: int in photo_quadrants():
		var r := quadrant_rect(q)
		out.append(Rect2i(r.position + Vector2i((r.size.x - fsz.x) / 2, 0), fsz))
	return out


## Where each photograph is printed — its frame's window — in this node's
## local space. For the palette audit's exemption and the tests.
func photo_rects() -> Array[Rect2i]:
	var out: Array[Rect2i] = []
	for fr: Rect2i in frame_rects():
		out.append(Rect2i(fr.position + frame_window_px.position, frame_window_px.size))
	return out


# --- what the page says --------------------------------------------------------

## The centred lines at the head of the page, with the size each is set at.
func text_lines() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _blank:
		return out
	out.append({"text": name_text(), "size": name_font_size, "font": active_name_font()})
	out.append({"text": _data.scientific_name, "size": font_size})
	return out


## The game facts, one phrase each, in print order. Empty with no species.
func fact_lines() -> PackedStringArray:
	var out := PackedStringArray()
	if _data == null:
		return out
	# Sentence case, put on here: the CSV keeps its phrases lowercase like the
	# rest of the chrome, and a notebook line starts with a capital ("Hasta 3 m
	# de alto"). The field notes are authored in sentence case already.
	out.append(_sentence(_height_text()))
	out.append(_sentence(_altitude_text()))
	out.append(_sentence(tr(_water_key())))
	out.append(_sentence(tr(_trample_key())))
	out.append(_sentence(tr(_growth_key())))
	var where := _where_text()
	if not where.is_empty():
		out.append(_sentence(where))
	return out


static func _sentence(text: String) -> String:
	return text.substr(0, 1).to_upper() + text.substr(1) if not text.is_empty() else text


## The field note printed this time, or "" with no species / no facts.
func note_text() -> String:
	if _data == null or _data.fact_keys.is_empty():
		return ""
	return tr(_data.fact_keys[fact_index % _data.fact_keys.size()])


## Every field note the species has, for the tests to measure all of them.
func all_note_texts() -> PackedStringArray:
	var out := PackedStringArray()
	if _data == null:
		return out
	for key: String in _data.fact_keys:
		if not key.is_empty():
			out.append(tr(key))
	return out


func _height_text() -> String:
	# "3 m" not "3.0 m": the table these come from prints whole and half metres.
	var h: float = _data.height_m
	var s: String = str(int(h)) if is_equal_approx(h, floorf(h)) else "%.1f" % h
	return tr("JOURNAL_VAL_HEIGHT").format([s])


func _altitude_text() -> String:
	var band: Vector2i = _data.altitude_band
	return tr("JOURNAL_VAL_ALTITUDE").format([_metres(band.x), _metres(band.y)])


static func _metres(step: int) -> int:
	var m: float = _M_AT_ZERO + float(step) * _M_PER_STEP
	return int(roundf(m / float(_M_ROUND))) * _M_ROUND


func _water_key() -> String:
	var a: float = _data.water_affinity
	if a > 0.0:
		return "JOURNAL_VAL_WATER_NEAR"
	if a < 0.0:
		return "JOURNAL_VAL_WATER_DRY"
	return "JOURNAL_VAL_WATER_ANY"


func _trample_key() -> String:
	var r: float = _data.trample_resistance
	if r >= _TRAMPLE_TOUGH_FROM:
		return "JOURNAL_VAL_TRAMPLE_TOUGH"
	if r >= _TRAMPLE_STURDY_FROM:
		return "JOURNAL_VAL_TRAMPLE_STURDY"
	return "JOURNAL_VAL_TRAMPLE_FRAGILE"


func _growth_key() -> String:
	var g: float = _data.growth_chance
	if g >= _GROWTH_FAST_FROM:
		return "JOURNAL_VAL_GROWTH_FAST"
	if g >= _GROWTH_STEADY_FROM:
		return "JOURNAL_VAL_GROWTH_STEADY"
	return "JOURNAL_VAL_GROWTH_SLOW"


# The mountains this species is on: every profile whose density table scales
# it above zero (a kind missing from the table never spawns there).
func _where_text() -> String:
	var names := PackedStringArray()
	for eco: EcosystemProfile in ecosystems:
		if eco == null or eco.scale_for(_data.id) <= 0.0:
			continue
		# Proper nouns: the mountains are capitalised whatever the chrome does.
		names.append(_sentence(tr(eco.display_key) if not eco.display_key.is_empty()
				else String(eco.id)))
	if names.is_empty():
		return ""
	# "a, b and c": the last joiner is a word.
	var listed: String = names[0]
	if names.size() > 1:
		listed = ", ".join(names.slice(0, names.size() - 1)) \
				+ tr("JOURNAL_VAL_AND") + names[names.size() - 1]
	return tr("JOURNAL_VAL_WHERE").format([listed])


# --- layout ---------------------------------------------------------------------

## Wrapped height of one text at `width`, in whole lines.
func lines_of(text: String, width: int) -> int:
	var f := active_font()
	if f == null or text.is_empty():
		return 0
	var h: float = f.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT,
			float(width), font_size).y
	return int(roundf(h / float(maxi(1, line_px()))))


## Lines the game facts take in their quadrant, every phrase wrapped.
func facts_lines() -> int:
	var q: int = quadrant_of(Kind.FACTS)
	var n: int = 0
	for text: String in fact_lines():
		n += maxi(1, lines_of(text, text_width_px(q)))
	return n


## Lines a note of `text` would take in the note's quadrant.
func note_lines(text: String) -> int:
	return lines_of(text, text_width_px(quadrant_of(Kind.NOTE)))


## Every run of ink this page draws, in its own local space, labelled — the
## surface the block audit and the tests check the warp contract against.
func ink_runs() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var line: int = line_px()
	if _blank:
		return out
	# The name's line box from JournalTitle's inset — 17 rows from row 1.
	var nr := JournalTitle.ink_run(active_name_font(), name_font_size)
	out.append({"name": "name", "top": nr.x, "height": nr.y})
	out.append({"name": "binomial", "top": subtitle_top_px, "height": line})
	var i: int = -1
	var stand: int = stage_stand_px()
	for tex: Texture2D in _stage_textures():
		i += 1
		var ink := JournalKnownSet.ink_rect(tex)
		out.append({
			"name": "stage %d" % i,
			"top": stand - int(ink.size.y),
			"height": int(ink.size.y),
		})
	# Each frame as ONE run: its white body and gold corners are one shape,
	# and the photograph inside it takes the frame's phase.
	i = -1
	for fr: Rect2i in frame_rects():
		i += 1
		out.append({"name": "polaroid %d" % i, "top": fr.position.y, "height": fr.size.y})
	var q: int = quadrant_of(Kind.FACTS)
	var y: int = text_top_px(q)
	i = -1
	for text: String in fact_lines():
		i += 1
		for k: int in maxi(1, lines_of(text, text_width_px(q))):
			out.append({"name": "fact %d" % i, "top": y, "height": line})
			y += line
	var note := note_text()
	if not note.is_empty():
		q = quadrant_of(Kind.NOTE)
		var top: int = text_top_px(q)
		for k: int in note_lines(note):
			out.append({"name": "note", "top": top + k * line, "height": line})
	return out


func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	for run: Dictionary in ink_runs():
		if not JournalBlocks.is_clean(run["top"], run["height"], block_px):
			out.append("%s inks %d rows at %d and crosses an avoidable seam"
				% [run["name"], run["height"], run["top"]])
	if _data != null and stage_stand_px() > quadrants_top_px:
		out.append("the growth stages stand on %d, below the quadrants' top at %d"
			% [stage_stand_px(), quadrants_top_px])
	return out


func _stage_textures() -> Array[Texture2D]:
	var out: Array[Texture2D] = []
	if _data == null:
		return out
	for tex: Texture2D in _data.variants:
		if tex != null:
			out.append(tex)
	return out


## The row the stages' ink actually stands on: `stages_bottom_px` if every
## stage is clean there, else the nearest row where all of them are — the
## row moves as one. Clears the binomial's line above; a resolution below
## `quadrants_top_px` is a design error the configuration warning reports.
func stage_stand_px() -> int:
	var texs := _stage_textures()
	if texs.is_empty():
		return stages_bottom_px
	var tallest: int = 0
	for tex: Texture2D in texs:
		tallest = maxi(tallest, int(JournalKnownSet.ink_rect(tex).size.y))
	var runs: Array[Vector2i] = []
	for tex: Texture2D in texs:
		var h: int = int(JournalKnownSet.ink_rect(tex).size.y)
		runs.append(Vector2i(tallest - h, h))
	var floor_px: int = subtitle_top_px + line_px()
	return JournalBlocks.snap_top(stages_bottom_px - tallest, runs, block_px, floor_px) + tallest


## Left edge of each stage's INK, packed `stage_gap_px` apart and centred
## across the page as a row. For the tests.
func stage_ink_lefts() -> Array[int]:
	var out: Array[int] = []
	var widths: Array[int] = []
	var total: int = 0
	for tex: Texture2D in _stage_textures():
		var w: int = int(JournalKnownSet.ink_rect(tex).size.x)
		widths.append(w)
		total += w
	if widths.is_empty():
		return out
	total += stage_gap_px * (widths.size() - 1)
	var x: int = (int(size.x) - total) / 2
	for w: int in widths:
		out.append(x)
		x += w + stage_gap_px
	return out


# The stages are child TextureRects rather than draw_texture calls so the ink
# material applies to THEM alone — a CanvasItem's material covers everything
# the item draws, and the type must stay flat ink.
func _relayout() -> void:
	if not is_inside_tree():
		return
	for r: TextureRect in _stage_rects:
		if is_instance_valid(r):
			remove_child(r)
			r.queue_free()
	_stage_rects.clear()

	if _data != null:
		var lefts := stage_ink_lefts()
		var stand: int = stage_stand_px()
		var i: int = -1
		for tex: Texture2D in _stage_textures():
			i += 1
			var r := PixelUI.make_icon_sized(tex)
			if ink_material != null:
				r.material = ink_material
			var ink := JournalKnownSet.ink_rect(tex)
			# Placed by INK: its left edge on the packed row, its bottom on
			# the stand row, whole texels.
			r.position = Vector2(
				floorf(float(lefts[i]) - ink.position.x),
				floorf(float(stand) - ink.size.y - ink.position.y))
			add_child(r)
			_stage_rects.append(r)
	_place_floats()
	update_configuration_warnings()
	queue_redraw()


# Hands each photograph and its frame to their floats, creating them on first
# use — photo first, frame second, so the frame draws on top. In the editor
# (@tool) the plate has no species, so nothing is ever created there.
func _place_floats() -> void:
	if _data == null or Engine.is_editor_hint():
		_sync_floats()
		return
	var page := _page()
	var host := _float_host()
	var content := get_parent() as Control
	if page == null or host == null or content == null:
		return
	var pics := photos()
	var frames := frame_rects()
	var windows := photo_rects()
	while _floats.size() < 2 * pics.size():
		var photo := JournalPhotoFloat.new(CanvasItem.TEXTURE_FILTER_LINEAR)
		_add_float(host, photo)
		_floats.append(photo)
		var frame := JournalPhotoFloat.new(CanvasItem.TEXTURE_FILTER_NEAREST)
		frame.name = "PolaroidFloat"
		_add_float(host, frame)
		_floats.append(frame)
	for i: int in _floats.size():
		var f: JournalPhotoFloat = _floats[i]
		var p: int = i / 2
		if p >= pics.size():
			f.texture = null
			continue
		if i % 2 == 0:
			f.texture = pics[p]
			f.place(page, content, windows[p])
		else:
			f.texture = frame_texture
			f.place(page, content, frames[p])
	_sync_floats()


# Parents a float to BookArt DIRECTLY AFTER the pages and any float already
# there — never at the end. Everything authored after Pages (the fore-edge
# tabs, the page corners, the shop tooltip) is meant to draw OVER the paper
# and whatever is stuck to it; a float appended at runtime would land on top
# of them, and did: a lifted page corner showed the polaroid through it.
static func _add_float(host: Control, f: JournalPhotoFloat) -> void:
	host.add_child(f)
	var pages := host.get_node_or_null("Pages")
	if pages == null:
		return
	var slot: int = pages.get_index() + 1
	while slot < host.get_child_count() and host.get_child(slot) is JournalPhotoFloat 			and host.get_child(slot) != f:
		slot += 1
	host.move_child(f, slot)


func _draw() -> void:
	var f := active_font()
	if f == null or _blank:
		return
	var w: int = int(size.x)
	# The name, set like a JournalTitle heading (inset, centred), no rule.
	var nf := active_name_font()
	draw_string(nf, Vector2(0, JournalTitle.INK_INSET_PX + nf.get_ascent(name_font_size)),
		name_text(), HORIZONTAL_ALIGNMENT_CENTER, w, name_font_size, text_color)
	_draw_centred(f, font_size, _data.scientific_name, subtitle_top_px, w)
	# The facts in their quadrant, the note in its. (The polaroids are the
	# floats'.)
	var ascent: float = f.get_ascent(font_size)
	var line: int = line_px()
	var q: int = quadrant_of(Kind.FACTS)
	var x: int = text_left_px(q)
	var width: int = text_width_px(q)
	var y: int = text_top_px(q)
	for text: String in fact_lines():
		draw_multiline_string(f, Vector2(x, y + ascent), text,
			HORIZONTAL_ALIGNMENT_LEFT, float(width), font_size, -1, text_color)
		y += maxi(1, lines_of(text, width)) * line
	var note := note_text()
	if not note.is_empty():
		q = quadrant_of(Kind.NOTE)
		draw_multiline_string(f, Vector2(text_left_px(q), text_top_px(q) + ascent),
			note, HORIZONTAL_ALIGNMENT_LEFT, float(text_width_px(q)), font_size, -1,
			text_color)


# A line centred across the page with its line box's TOP at `top`, so the
# rows it inks are the ones `ink_runs` reports.
func _draw_centred(f: Font, sz: int, text: String, top: int, width: int) -> void:
	draw_string(f, Vector2(0, top + f.get_ascent(sz)), text,
		HORIZONTAL_ALIGNMENT_CENTER, width, sz, text_color)
