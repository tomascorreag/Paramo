@tool
class_name JournalResources
extends Control

## The player's stock, printed at the top of the journal's RIGHT page: a titled
## row of glyph-over-count columns, one per resource.
##
## This replaces the `Inventory` node that used to sit at the foot of the LEFT
## page. Two reasons it moved and changed shape:
##   - The left page is the RUN (the season slot, the calendar). Stock is not a
##     record of the run, it is the state of the moment, and it belongs with the
##     other reference material on the right.
##   - It is the page's HEADLINE figure — what you have right now — so it is set
##     large: 16x16 glyphs and Tiny5 at 16. That is deliberately the opposite of
##     the calendar's day stats (8px glyphs, Tiny5 at 8), which are a dense record
##     you scan rather than a number you read. 16 is legal because it is a multiple
##     of Tiny5's 8px em; anything between the two would stagger the glyphs.
##
## DRAWN, not a container of Labels, for the same two reasons JournalKnownSet and
## RunCalendar are: the Eggmode title cannot be a Label on an 18-texel warp block
## (18 % 16 != 0 fails test_journal_pages.gd), and drawing calls tr() per frame so
## a locale switch repaints for free. See JournalTitle for the full argument.
##
## Layout, in the page's warp blocks:
##
##     resources          <- `title`, two blocks (heading + its rule)
##     ---------
##      O 12   @ 40       <- one block: a 16px glyph with its count beside it
##
## The glyphs go through assets/shaders/journal_ink.gdshader via a child
## JournalInkLayer rather than through this node's own material, because a
## CanvasItem's material covers everything it draws and the title and counts must
## stay flat ink. That is also what makes the water glyph (blues) and the visitor
## glyph (a flat black silhouette) read as things drawn on paper.

## Section heading — a TRANSLATION KEY, resolved at draw time. Lowercase in every
## locale, and ACCENT-FREE in Spanish: this is drawn in Eggmode, which ships no
## accented glyph at all and would render tofu. tests/test_journal_pages.gd asserts
## the coverage.
@export var title: String = "JOURNAL_RESOURCES":
	set(value):
		title = value
		queue_redraw()

@export_group("Contents")
## Ledger ids to print, left to right. `visitors` is not a ledger resource — it is
## a source tag on tokens (VisitorFlow) — so it is deliberately absent: this row
## shows what you HAVE, and visitors are a flow, not a stock. The calendar is where
## they are counted.
@export var resource_ids: PackedStringArray = ["water", "tokens"]:
	set(value):
		resource_ids = value
		queue_redraw()

## Glyphs, 1:1 with `resource_ids`. The FULL-SIZE 16x16 icons/*.tres, not the
## _small variants the calendar uses: the glyph and its count sit SIDE BY SIDE
## here, so the row's 18-texel block has to hold only the taller of the two (16px
## art, 18px Tiny5-16 line) rather than their sum. Stacking them would need 25 and
## a second block, which the right page cannot afford — two 72-texel known sets
## plus a 72-texel resources section is 216 against the page's 213.
@export var icons: Array[Texture2D] = []:
	set(value):
		icons = value
		queue_redraw()

@export_group("Layout")
## Width of one resource column: the glyph, then its count in what is left.
## Widening this spaces the row out rather than moving it.
@export var column_px: int = 70:
	set(value):
		column_px = value
		queue_redraw()

## Matches the page's `row_block_px`. The heading rounds up to a whole number of
## these and the glyph/count row occupies exactly one, so nothing here can straddle
## a warp seam. tests/test_journal_pages.gd guards the equality.
@export var block_px: int = 18:
	set(value):
		block_px = value
		queue_redraw()

## Lead-in from this node's left edge, on the 4-texel column grid the page's
## `col_block_px` snaps to. Same value JournalKnownSet insets its swatches by, so
## the two sections line up down the page.
@export var left_inset_px: int = 8:
	set(value):
		left_inset_px = value
		queue_redraw()

@export_group("Type")
## Title face. Leave null to fall back to the theme's Label font. The journal sets
## Eggmode — a heading is something you WROTE at the top of the list.
@export var header_font: Font = null:
	set(value):
		header_font = value
		queue_redraw()

## Must be a multiple of the face's native em (16 for Eggmode).
@export var header_font_size: int = 16:
	set(value):
		header_font_size = value
		queue_redraw()

## Count face. Null takes the theme's Label font (Tiny5).
@export var font: Font = null:
	set(value):
		font = value
		queue_redraw()

## 16, twice the calendar's — this is the figure the player opens the book to
## read. Must stay a multiple of Tiny5's 8px native em (see UI Font Pixel Grid):
## anything between duplicates roughly one pixel row per em at a different place
## in every glyph and the line visibly staggers.
@export var font_size: int = 16:
	set(value):
		font_size = value
		queue_redraw()

## Rows below the title's block that its underline sits at. Must stay clear of both
## seams of the block it lands in.
@export_range(0, 17) var header_underline_offset_px: int = 2:
	set(value):
		header_underline_offset_px = value
		queue_redraw()

@export var text_color: Color = Palette.P06:
	set(value):
		text_color = value
		queue_redraw()

@export_group("Ink")
## Runs the glyphs through journal_ink.gdshader. Carried by a child
## JournalInkLayer, never by this node — see the class comment.
@export var ink_material: ShaderMaterial = null:
	set(value):
		ink_material = value
		_sync_ink_layer()

@export_group("Editor preview")
## Stands in for the ledger in the editor, where autoloads do not run. Applied by
## index across `resource_ids`.
@export var preview_amounts: PackedInt32Array = [12, 40]:
	set(value):
		preview_amounts = value
		queue_redraw()


## Glyph footprint. 16 fits the row's 18-texel block with a row of slack at each
## end, which is exactly what the block-seam rule needs — the glyph is drawn one
## row down so neither its top nor its bottom touches a seam.
const _ICON_PX: int = 16

## Rows the glyph is pushed down inside the block, spending that slack at the top.
const _ICON_INSET_PX: int = 1

## Air between a glyph and its count.
const _GAP_PX: int = 4

var _ink: JournalInkLayer = null


func _ready() -> void:
	# Ink on paper takes no input; the page SubViewport sets gui_disable_input
	# anyway, but IGNORE keeps this out of the picking pass entirely.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sync_ink_layer()
	if Engine.is_editor_hint():
		return
	# The ledger is an autoload that outlives scene loads, so a journal instanced
	# mid-run must READ the current balance, not wait for the next change.
	ResourceLedger.resource_changed.connect(_on_resource_changed)


## Height of the heading, including the block its rule sits in. Everything below
## this section starts at a multiple of `block_px` because of it.
func header_row_px() -> int:
	return JournalTitle.row_px(active_header_font(), header_font_size, block_px)


func active_header_font() -> Font:
	return header_font if header_font != null else get_theme_font(&"font", &"Label")


func active_font() -> Font:
	return font if font != null else get_theme_font(&"font", &"Label")


## The whole section's height: heading plus the one glyph/count row.
func section_height_px() -> int:
	return header_row_px() + maxi(1, block_px)


## Current amount for column `i`, floored. Floor, not round: the ledger is float
## and dousing costs 1 water per cell, so flooring keeps "the number on the page"
## equal to "cells I can still douse". Rounding would promise a douse the player
## cannot afford.
func amount(i: int) -> int:
	if Engine.is_editor_hint():
		return preview_amounts[i] if i < preview_amounts.size() else 0
	if i >= resource_ids.size():
		return 0
	return int(floorf(ResourceLedger.get_amount(StringName(resource_ids[i]))))


func _on_resource_changed(_id: StringName, _value: float, _delta: float) -> void:
	queue_redraw()
	if _ink != null and is_instance_valid(_ink):
		_ink.queue_redraw()


# Left edge of column `i`. Shared by the counts here and the glyphs on the ink
# layer, so the two cannot drift apart.
func _column_x(i: int) -> int:
	return left_inset_px + i * maxi(1, column_px)


func _draw() -> void:
	# The rule gets a block of its own here: what sits under this heading is a 16px
	# glyph row filling its block, with nothing to spare to share.
	JournalTitle.draw(self, active_header_font(), header_font_size, title,
		int(size.x), text_color,
		maxi(1, block_px) + header_underline_offset_px)
	var face := active_font()
	if face == null:
		return
	var top: int = header_row_px()
	# Line box at the block's own top: Tiny5-16 is an 18-row line inside an 18-row
	# block, and its ink sits inboard of both, so no row of it touches a seam.
	var base: float = top + face.get_ascent(font_size)
	var lead: int = _ICON_PX + _GAP_PX
	for i: int in range(resource_ids.size()):
		draw_string(face, Vector2(_column_x(i) + lead, base), str(amount(i)),
			HORIZONTAL_ALIGNMENT_LEFT, maxi(1, column_px - lead), font_size, text_color)
	if _ink != null and is_instance_valid(_ink):
		_ink.queue_redraw()


# Painted by the child ink layer so `ink_material` recolours the glyphs alone.
func _paint_icons(ci: CanvasItem) -> void:
	var top: int = header_row_px() + _ICON_INSET_PX
	# Drawn into a fixed _ICON_PX square rather than at the texture's own size: a
	# wrong-sized glyph should be visibly wrong here, not silently pushed off the
	# block and into the seam above it.
	var glyph := Vector2(_ICON_PX, _ICON_PX)
	for i: int in range(mini(icons.size(), resource_ids.size())):
		var tex: Texture2D = icons[i]
		if tex == null:
			continue
		ci.draw_texture_rect(tex,
			Rect2(Vector2(_column_x(i), top), glyph), false)


# Created in code because it is pure plumbing with no layout of its own — it
# exists only to hold `ink_material` away from this node's text. Deliberately not
# set_owner'd: under @tool an owned child would be written into field_journal.tscn.
func _sync_ink_layer() -> void:
	if not is_inside_tree():
		return
	if _ink == null or not is_instance_valid(_ink):
		_ink = JournalInkLayer.new()
		_ink.name = "Glyphs"
		_ink.painter = _paint_icons
		add_child(_ink)
		_ink.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ink.material = ink_material
	_ink.queue_redraw()
