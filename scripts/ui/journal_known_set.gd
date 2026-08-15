@tool
class_name JournalKnownSet
extends Control

## One titled reference section on the journal's right page — "known buildings" or
## "known flora" — showing the REAL in-world art for each thing the player can put
## on the mountain, reprinted as brown ink (assets/shaders/journal_ink.gdshader).
##
## Two sources, because the two kinds of thing are built two different ways in this
## project and neither is going to change to suit a UI panel:
##   `tile_kinds` — bridges and ladders exist ONLY as tiles painted into
##                  resources/tiles/base_tileset.tres. There is no Bridge sprite;
##                  scenes/traversals/bridge.tscn is an empty Node2D. So a swatch
##                  is cut out of the tileset at runtime.
##   `textures`   — frailejones are Node2D world objects whose growth stages are
##                  already AtlasTexture .tres (resources/objects/variants/), so
##                  those go in directly.
##
## Layout, in the page's warp blocks (see below):
##
##     known flora            <- `title`, one block
##     [][]                   <- one `cell_size` row of swatches
##
## THE TITLE IS DRAWN, NOT A LABEL, and that is not a style preference. This sits
## inside a page's SubViewport, so page_warp.gdshader translates each `block_px`
## band of it rigidly. The journal's title face is Eggmode at 16, whose line height
## is 16 — and 18 % 16 != 0, so a Label carrying it fails
## tests/test_journal_pages.gd's "row_block_px must be a whole number of text
## lines". RunCalendar hit the same wall and solved it the same way. If you ever
## "tidy" this into a Label, that test is the thing that will tell you why not.
##
## ALSO THE SHOP SURFACE. Each swatch can carry an id (`entry_ids`, 1:1 with
## swatch order) and a state set via `set_entry_state`: a LOCKED entry renders
## its swatch faded (through the ink shader's `dim` uniform — self_modulate is
## silently ignored by that shader, see its header) with the unlock cost
## printed beside it; an owned entry renders full ink, exactly as before. This
## node stays input-IGNORE — clicks arrive via JournalShopInput on BookHit,
## which asks `entry_at` where they landed. With no states set (preview tools,
## layout tests) everything renders as it always did.
##
## Contents are still authored in the scene: nothing tracks DISCOVERY — the
## shop tracks PURCHASE (UnlockState). `set_known` remains the discovery hook.
##
## @tool so both sections render in the editor. Unlike RunCalendar's preview mode
## there is nothing to fake here: the tileset scan is pure resource work and needs
## no autoloads, so the editor shows the real swatches.

## Section heading — a TRANSLATION KEY, resolved in _draw. Lowercase in every
## locale, per the project's UI copy convention.
##
## The Spanish here must be ACCENT-FREE. This heading is drawn in Eggmode, which
## ships 107 glyphs and has no á é í ó ú ü ñ ¿ … — a heading with one would render
## tofu. tests/test_journal_pages.gd asserts the coverage; see the CSV for the
## accent-free wording actually used.
@export var title: String = "JOURNAL_KNOWN_BUILDINGS":
	set(value):
		title = value
		queue_redraw()

@export_group("Contents")
## TileSlots names to cut out of `tileset` — the tile-painted structures. Resolved
## through TileKindIndex, so these are the SAME strings the placement code paints
## with and a renamed slot fails loudly instead of rendering an empty swatch.
@export var tile_kinds: PackedStringArray = []:
	set(value):
		tile_kinds = value
		_rebuild()

## Ready-made textures — the Node2D world objects, whose art is already a
## Texture2D (a frailejon's mature growth stage, say).
@export var textures: Array[Texture2D] = []:
	set(value):
		textures = value
		_rebuild()

## Shop id per swatch, 1:1 with draw order (tile_kinds first, then textures).
## These are UnlockState types / TileAction.unlock_id values ("bridge",
## "ladder", "frailejon"). Leave empty for a pure reference section.
@export var entry_ids: PackedStringArray = []:
	set(value):
		entry_ids = value
		queue_redraw()

## Glyph printed beside a LOCKED entry's price. The token coin
## (icons/money_small.tres) — the same 8px glyph RunCalendar stamps token yields
## with, deliberately, so "10" here and "4" in the calendar read as the same
## currency rather than as two unrelated numbers on one spread.
##
## A CHILD TextureRect like the swatches, not a draw_texture_rect in `_draw`, for
## the same reason they are: the coin has to go through `ink_material` and the
## price's digits must not (see the comment above `_rebuild`). It also gets the
## per-entry `dim` that way, which is what lets the glyph fade with its own
## number when that entry alone is unaffordable.
##
## Null prints the bare number — what preview tools and layout tests that never
## set a shop state already see.
@export var cost_icon: Texture2D = null:
	set(value):
		cost_icon = value
		_rebuild()

## The TileSet `tile_kinds` are cut out of. The journal's is base_tileset.tres,
## the same one StructureLayerManager paints structures into.
@export var tileset: TileSet = null:
	set(value):
		tileset = value
		_rebuild()

## Atlas source inside `tileset` holding the structure art. 1 is the wood/structures
## source on base_tileset.tres (StructureLayerManager.structures_source_id).
@export var source_id: int = 1:
	set(value):
		source_id = value
		_rebuild()

@export_group("Layout")
## Footprint of one swatch. The Y must be a multiple of `block_px` or a swatch
## straddles two warp blocks and gets a scanline duplicated through it; 36 is two
## blocks, which holds the 32px tile art with a texel of air top and bottom so no
## ink sits on a seam. The X is free — it only has to fit the page.
@export var cell_size: Vector2i = Vector2i(40, 36):
	set(value):
		cell_size = value
		_rebuild()

## Per-entry override of `cell_size`, index-aligned with draw order (tile_kinds
## first, then textures). Shorter than the entry list is fine — anything past the
## end, and any entry set to a non-positive size, falls back to `cell_size`.
##
## Exists because the swatches are NOT all the same size: a ladder inks about
## 20x20 of its 32x32 atlas cell while a fence inks 24x30 of its own, so one
## width either crowds the fence or leaves a hole beside the ladder. The cells
## abut, so a wider cell pushes everything after it along rather than overlapping
## it — `entry_rect` sums the widths before it instead of multiplying.
##
## The same warp-block rule applies to every Y here as to `cell_size`'s: a height
## that is not a multiple of `block_px` straddles two blocks and gets a scanline
## duplicated through the art. Varying the height also moves that entry's art
## within the row, since each swatch is centred in its OWN cell.
@export var cell_sizes: Array[Vector2i] = []:
	set(value):
		cell_sizes = value
		_rebuild()

## The page's warp quantisation. The title row rounds up to a multiple of this, so
## changing the title face or size cannot knock the swatch row off phase. Keep it
## equal to the page's `row_block_px`; tests/test_journal_pages.gd guards that.
@export var block_px: int = 18:
	set(value):
		block_px = value
		_rebuild()

## Air between the title's rule and the swatch row, in texels, on top of the two
## whole blocks the heading costs. Negative pulls the row UP into the heading's
## second block — which is where the visible hole is: the rule sits
## `header_underline_offset_px` rows into that block and the remaining ~14 rows of
## it are blank paper the swatches used to start after.
##
## KEEP IT A MULTIPLE OF `block_px` IF YOU CAN. The swatch row's top is
## `header_row_px()`, and a row whose top is not on a block boundary straddles two
## warp bands, so the seam duplicates or drops a scanline through the ART, not just
## through blank paper. Off-multiple values are allowed because a small nudge is
## sometimes worth the seam risk on a swatch with slack at that row — but check it
## with preview_run_calendar.gd rather than by eye, and clear the ink of the seam.
@export_range(-36, 36) var header_gap_px: int = 0:
	set(value):
		header_gap_px = value
		_rebuild()

## Extra texels around a swatch that still count as pointing at it. On top of
## `entry_rect`'s own rule that the whole DRAWN swatch is hittable, which is the
## part that matters when the art is bigger than its cell.
##
## Only the outer ends get it horizontally — see entry_rect for why. Raising it
## past half a cell's height starts letting the section's own heading answer for
## the entry underneath it.
@export_range(0, 8) var hit_padding_px: int = 2:
	set(value):
		hit_padding_px = value
		queue_redraw()

@export_group("Type")
## Title face. Leave null to fall back to the theme's Label font. The journal sets
## Eggmode — a section heading is something you WROTE at the top of the list.
@export var header_font: Font = null:
	set(value):
		header_font = value
		_rebuild()

## Must be a multiple of the face's native em (16 for Eggmode) or the rasteriser
## duplicates roughly one pixel row per em at a different place in every glyph and
## the line visibly staggers. See tests/test_journal_pages.gd.
@export var header_font_size: int = 16:
	set(value):
		header_font_size = value
		_rebuild()

## Rows below the title's block that its underline sits at. Must stay clear of both
## seams of the block it lands in.
@export_range(0, 17) var header_underline_offset_px: int = 2:
	set(value):
		header_underline_offset_px = value
		# _rebuild, not queue_redraw: this feeds header_row_px()'s floor, so it can
		# move the swatch row as well as the rule.
		_rebuild()

@export var text_color: Color = Palette.P06:
	set(value):
		text_color = value
		queue_redraw()

@export_group("Ink")
## Applied to every swatch. Carrying it here rather than on each generated child
## means all the swatches on the page share ONE material, so retuning the ramp is
## a single resource edit. Null draws the art in its own colours.
@export var ink_material: ShaderMaterial = null:
	set(value):
		ink_material = value
		_rebuild()


## Swatches are laid out from this node's left edge with this much lead-in, on the
## 4-texel column grid the page's `col_block_px` snaps to.
const _LEFT_INSET_PX: int = 8

## How far a hovered swatch lifts off the paper, in texels.
##
## A LIFT, not the 1.12 scale-up radial_menu_item uses for the same job, and the
## difference is the viewport. That menu renders at window resolution, where a
## fractional scale is resampled by the GPU and looks fine. These swatches sit in a
## 1:1 nearest-filtered SubViewport where a 1.12 scale on 32px pixel art visibly
## breaks the grid — the same reason _rebuild floors every swatch position. One
## whole texel is the smallest honest "it moved" this page can express.
const HOVER_LIFT_PX: int = 1

## A hovered LOCKED swatch inks up toward owned instead of only moving. Reads as
## the thing surfacing when you point at it, and costs nothing extra: the `dim`
## uniform is already the mechanism the lock state uses.
##
## Only an entry the player could actually buy does this — see `reacts_to_hover`.
const HOVER_ALPHA: float = 0.7

## How far an unaffordable entry recoils when clicked, in texels.
const DENY_SHAKE_PX: int = 1

## Length of that recoil.
const DENY_DURATION: float = 0.18

## Half-cycles of shake over DENY_DURATION. Odd multiples of PI end the sine back
## at zero, so the swatch cannot be left parked off its own column.
const DENY_SHAKES: float = 6.0

# Shared across every section on the page. Building a TileKindIndex scans the whole
# atlas AND validates every TileSlots constant against it, pushing a warning per
# unpainted slot — source 1 is the structures atlas, so it legitimately has none of
# the terrain slots and the scan is noisy. Doing that once per section per setter
# poke would bury the console. Static, so the two sections share one scan.
static var _indices: Dictionary[String, TileKindIndex] = {}

## Fade applied to a locked entry's swatch, via the ink shader's `dim` uniform.
const LOCKED_ALPHA: float = 0.4

## The price, in the data face at the data size — Tiny5 at 8, straight off the
## theme. Same figures as the calendar's day stats; a price set any larger stops
## being an annotation on the picture and starts competing with it.
const COST_FONT_SIZE: int = 8

## The coin's footprint, and the air between it and its digits. Both match
## RunCalendar's stat glyphs exactly (8px art, 1px gap): the two are the same
## currency at the same size on the same spread, and a different pitch here
## would read as a different kind of number.
const COST_ICON_PX: int = 8
const COST_GAP_PX: int = 1

## Air between the price and the right and bottom edges of the entry's rect. The
## bottom one is load-bearing: it puts the baseline 2 rows above the cell's foot,
## which keeps every inked row of the price — glyph included — inside the cell's
## LOWER warp block and clear of both its seams.
const COST_MARGIN_PX: int = 2

var _swatches: Array[TextureRect] = []
# One per swatch, 1:1, hidden while that entry is owned. Empty when `cost_icon`
# is null, which is the pre-shop behaviour: a bare number.
var _cost_icons: Array[TextureRect] = []
# Where each swatch RESTS, before the hover lift and the denial shake are added.
# Kept separately so those two offsets can be applied and removed without
# accumulating rounding into the authored layout.
var _rest_positions: Array[Vector2] = []
# id -> {"locked": bool, "cost": int, "affordable": bool}. Empty (the default
# everywhere outside a live run) renders every swatch owned/full-ink.
var _states: Dictionary = {}
# Which swatch the pointer is over, -1 for none. Driven by JournalShopInput.
var _hovered: int = -1
# The swatch currently recoiling from an unaffordable click, and how far through
# that recoil it is (1 -> 0).
var _denied: int = -1
var _deny_phase: float = 0.0
var _deny_tween: Tween


func _ready() -> void:
	# Ink on paper takes no input, and the page's SubViewport sets
	# gui_disable_input anyway — IGNORE keeps this out of the picking pass.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_rebuild()


## Where the swatch row starts: the title row rounded UP to a whole block, PLUS the
## block holding its rule, PLUS `header_gap_px`. At the default gap of 0 everything
## below is in phase with the page whatever face the title ends up using; see
## JournalTitle for why the rule needs a block of its own, and `header_gap_px` for
## what a gap off the block grid costs.
func header_row_px() -> int:
	var rows := JournalTitle.row_px(active_header_font(), header_font_size, block_px) \
			+ header_gap_px
	# Floor at the row just under the rule: a gap negative enough to reach it would
	# print the swatches THROUGH the heading's own underline, which is never what
	# tightening the spacing meant.
	return maxi(rows, maxi(1, block_px) + header_underline_offset_px
			+ JournalTitle.UNDERLINE_THICK_PX)


## The title face actually used: the export if set, else the theme's Label font.
func active_header_font() -> Font:
	return header_font if header_font != null else get_theme_font(&"font", &"Label")


## Every swatch texture this section shows, tiles first then plain textures, in the
## order they are drawn. Public so tests can assert a slot actually resolved rather
## than silently rendering nothing.
func swatch_textures() -> Array[Texture2D]:
	var out: Array[Texture2D] = []
	for kind: String in tile_kinds:
		var tex := _tile_texture(StringName(kind))
		if tex != null:
			out.append(tex)
	for tex: Texture2D in textures:
		if tex != null:
			out.append(tex)
	return out


## Replaces the authored contents at runtime. The hook a discovery system would
## call; until one exists nothing invokes it.
func set_known(kinds: PackedStringArray, texs: Array[Texture2D]) -> void:
	tile_kinds = kinds
	textures = texs


# --- Shop state (JournalShopInput drives these) ------------------------------

## Sets one entry's shop presentation. Locked: faded swatch + cost printed
## beside it (cost itself faded when unaffordable). Unknown ids are stored
## harmlessly — the draw pass only consults states for ids it actually shows.
func set_entry_state(id: StringName, locked: bool, cost: int,
		affordable: bool) -> void:
	_states[id] = {"locked": locked, "cost": cost, "affordable": affordable}
	_apply_states()


## What a pointer has to be over to hit one entry, in this node's local space.
##
## Covers what is DRAWN, not the slot it was allotted. `_rebuild` centres each
## swatch in its cell at the ART's own size and does not scale it, so the moment
## the art is bigger than `cell_size` — 32px tile swatches in a 24x16 cell, say —
## most of what the player can see sits outside the cell. Hit-testing the cell then
## means only the middle of the picture responds, which reads as the page being
## broken rather than as a tight target.
##
## Vertical padding is free: a section is a single ROW of entries, so there is
## nothing above or below to steal from. Horizontal padding only goes on the outer
## ends, because cells abut — widening an inner edge would put two entries over the
## same texels, and `entry_at` would silently award them to whichever comes first.
func entry_rect(index: int) -> Rect2:
	var r := Rect2(
			Vector2(_cell_left(index), header_row_px()),
			Vector2(cell_size_for(index)))
	if index >= 0 and index < _swatches.size() and index < _rest_positions.size() \
			and is_instance_valid(_swatches[index]):
		var art := Rect2(_rest_positions[index], _swatches[index].size)
		var top: float = minf(r.position.y, art.position.y)
		r = Rect2(Vector2(r.position.x, top),
				Vector2(r.size.x, maxf(r.end.y, art.end.y) - top))
	var pad := float(maxi(0, hit_padding_px))
	return r.grow_individual(
			pad if index == 0 else 0.0, pad,
			pad if index == _swatches.size() - 1 else 0.0, pad)


## What is actually INKED for one entry, in this node's local space.
##
## Not `entry_rect()`, which is the HIT rect: that one covers the whole cell and
## is grown by `hit_padding_px` on top, and a 20-texel ladder centred in a
## 36-texel cell leaves rows of blank paper inside it. Anything placed relative
## to the PICTURE — the buy glyph tucked into its corner — needs the picture.
## Follows the hover lift, since the swatch's live position is what it reads.
func entry_ink_rect(index: int) -> Rect2:
	if index < 0 or index >= _swatches.size() \
			or not is_instance_valid(_swatches[index]):
		return entry_rect(index)
	var r: TextureRect = _swatches[index]
	var ink := _ink_rect(r.texture)
	return Rect2(r.position + ink.position, ink.size)


## Which entry a local-space point lands on, -1 for a miss. Hit-tested in
## UNWARPED page space: the page warp displaces this content by at most a few
## texels near the spine, and a cell absorbs that error (the accepted
## simplification — see preview_page_warp.gd's findings).
func entry_at(point: Vector2) -> int:
	for i in _swatches.size():
		if entry_rect(i).has_point(point):
			return i
	return -1


## The cell allotted to one entry: its `cell_sizes` override if it has a usable
## one, else the shared `cell_size`.
func cell_size_for(index: int) -> Vector2i:
	if index < 0 or index >= cell_sizes.size():
		return cell_size
	var c: Vector2i = cell_sizes[index]
	return c if c.x > 0 and c.y > 0 else cell_size


# Left edge of one entry's cell. Cells abut, so this is the sum of every cell
# before it — NOT index * pitch, which only holds while they are all one width.
func _cell_left(index: int) -> int:
	var x: int = _LEFT_INSET_PX
	for i in index:
		x += maxi(1, cell_size_for(i).x)
	return x


func entry_id_at(index: int) -> StringName:
	if index < 0 or index >= entry_ids.size():
		return &""
	return StringName(entry_ids[index])


func _state_for(index: int) -> Dictionary:
	return _states.get(entry_id_at(index), {})


# --- Pointer feedback (JournalShopInput drives these too) --------------------

## Which swatch the pointer is over, or -1. Idempotent, so the input node can call
## it every mouse-motion event without churning.
func set_hovered(index: int) -> void:
	if index == _hovered:
		return
	_hovered = index
	_apply_states()


## Recoil + redden one entry, for a click the player cannot afford. Purely
## presentational: nothing about the purchase is decided here.
##
## The SWATCH ITSELF cannot be tinted, and that is not an oversight —
## journal_ink.gdshader writes COLOR outright and never multiplies the vertex
## modulate back in, so self_modulate on one of these is silently ignored (its own
## header says so). What moves is the swatch's POSITION, and what reddens is the
## cost text, which this node draws itself and is therefore not under that material.
func flash_denied(index: int) -> void:
	if index < 0 or index >= _swatches.size():
		return
	if _deny_tween and _deny_tween.is_valid():
		_deny_tween.kill()
	_denied = index
	# Decaying rather than constant amplitude: a recoil that fades reads as the
	# page absorbing the poke, where an even shake reads as a broken animation.
	_deny_tween = create_tween()
	_deny_tween.tween_method(_set_deny_phase, 1.0, 0.0, DENY_DURATION)
	_deny_tween.tween_callback(func() -> void:
		_denied = -1
		_set_deny_phase(0.0))


func _set_deny_phase(value: float) -> void:
	_deny_phase = value
	_apply_states()


# Whole texels, and zero at both ends of the tween: a swatch left parked on a
# fractional offset would resample the pixel art it spent _rebuild floors avoiding.
func _deny_offset(index: int) -> int:
	if index != _denied or _deny_phase <= 0.0:
		return 0
	return int(roundf(sin(_deny_phase * PI * DENY_SHAKES) * _deny_phase)) * DENY_SHAKE_PX


## Whether pointing at this entry does anything. An entry the player cannot
## afford does NOT: the lift and the ink-up both say "this is available", and
## saying it over a price the player cannot meet turns the refusal into a
## surprise at click time instead of information before it. The price beside the
## swatch is already the reason, printed; the swatch just stops answering.
##
## Owned entries still react. They are not BLOCKED, they are done — the section
## is a reference list as well as a shop, and a lift is the honest response to
## pointing at something that is on the page because you have it.
func reacts_to_hover(index: int) -> bool:
	var state := _state_for(index)
	return not bool(state.get("locked", false)) \
			or bool(state.get("affordable", false))


func _apply_states() -> void:
	for i in _swatches.size():
		var r: TextureRect = _swatches[i]
		if not is_instance_valid(r):
			continue
		var locked: bool = _state_for(i).get("locked", false)
		# `_hovered` stays the truth about where the POINTER is — the input node
		# resolves that, and a refusal must not make the two disagree about it.
		# What changes is whether this entry answers.
		var hovered: bool = i == _hovered and reacts_to_hover(i)
		var m := r.material as ShaderMaterial
		if m != null:
			m.set_shader_parameter(&"dim",
				(HOVER_ALPHA if hovered else LOCKED_ALPHA) if locked else 1.0)
		if i < _rest_positions.size():
			r.position = _rest_positions[i] + Vector2(
				_deny_offset(i), -HOVER_LIFT_PX if hovered else 0)
	_apply_cost_icons()
	queue_redraw()


# The coin beside each locked price. Positioned here rather than in _rebuild
# because it moves with the state: the digits it hangs off can change width when
# a price is retuned, and it has to shake with the denial recoil.
func _apply_cost_icons() -> void:
	var face := get_theme_font(&"font", &"Label")
	for i in _cost_icons.size():
		var g: TextureRect = _cost_icons[i]
		if not is_instance_valid(g):
			continue
		var state := _state_for(i)
		g.visible = face != null and bool(state.get("locked", false))
		if not g.visible:
			continue
		g.position = _cost_icon_pos(i, _cost_text_width(face, i))
		var m := g.material as ShaderMaterial
		if m != null:
			# The glyph fades with ITS OWN number, not with the section: at 20 tokens
			# the ladder is affordable and the fence is not, and a coin that stays
			# bright over a faded price says the opposite of what the price says.
			m.set_shader_parameter(&"dim",
				1.0 if state.get("affordable", false) else LOCKED_ALPHA)


func _cost_text(index: int) -> String:
	return str(int(_state_for(index).get("cost", 0)))


func _cost_text_width(face: Font, index: int) -> float:
	return face.get_string_size(_cost_text(index),
			HORIZONTAL_ALIGNMENT_LEFT, -1, COST_FONT_SIZE).x


# Where a price's digits start. The whole group — coin, gap, digits — hangs off
# the entry's right edge, so a three-digit price grows LEFTWARD into its own cell
# instead of pushing the coin over the neighbour.
func _cost_number_x(index: int, text_w: float) -> float:
	return entry_rect(index).end.x - COST_MARGIN_PX - text_w + _deny_offset(index)


func _cost_icon_pos(index: int, text_w: float) -> Vector2:
	return Vector2(
		_cost_number_x(index, text_w) - COST_GAP_PX - COST_ICON_PX,
		entry_rect(index).end.y - COST_MARGIN_PX - COST_ICON_PX)


## Width of one entry's whole price, coin included — what has to fit inside the
## cell. Public because that is the claim worth testing: the ladder's cell is 20
## texels and the group is 17 of them, so this is the number that goes negative
## first if either a price or a cell is retuned.
func cost_group_width(index: int) -> float:
	var face := get_theme_font(&"font", &"Label")
	if face == null:
		return 0.0
	var w := _cost_text_width(face, index)
	return w if _cost_icons.is_empty() else w + COST_GAP_PX + COST_ICON_PX


# Cuts one tile's art out of the atlas. get_tile_texture_region accounts for
# size_in_atlas, so a ladder (1x2 cells of a 32x16 atlas) yields the full 32x32
# art rather than its bottom half — the trap this would otherwise fall into.
# Recipe lifted from scripts/vfx/burning_cell_vfx.gd, which does the same cut for
# the burning-grass overlay.
func _tile_texture(kind: StringName) -> AtlasTexture:
	var index := _index_for(tileset, source_id)
	if index == null or not index.has(kind):
		return null
	var src := tileset.get_source(source_id) as TileSetAtlasSource
	if src == null:
		return null
	var tex := AtlasTexture.new()
	tex.atlas = src.texture
	tex.region = src.get_tile_texture_region(index.coord(kind))
	return tex


# Opaque bounds of a swatch texture, in its own texture space. Falls back to the
# whole texture when nothing can be read (a texture whose image isn't available)
# so layout degrades to the old texture-centred behaviour rather than collapsing.
#
# Cached: this pulls the image off the GPU-side resource, and _rebuild runs on
# every export setter poke — including in the editor, where they come in bursts.
static var _ink_rects: Dictionary[String, Rect2] = {}


static func _ink_rect(tex: Texture2D) -> Rect2:
	var full := Rect2(Vector2.ZERO, tex.get_size())
	# Keyed by the REGION, not by get_rid(): an AtlasTexture reports the RID of
	# the atlas it cuts from, so every swatch sharing a spritesheet returns the
	# same one. Cached under that, all three building swatches collapsed onto the
	# first one's ink bounds and the layout silently fell back to the old
	# texture-centred behaviour it was supposed to replace.
	var key := "%s|%s" % [tex.get_rid(), full.size]
	if tex is AtlasTexture:
		var at := tex as AtlasTexture
		key = "%s|%s" % [at.atlas.get_rid() if at.atlas != null else "?", at.region]
	if _ink_rects.has(key):
		return _ink_rects[key]
	var img := tex.get_image()
	if img == null:
		return full
	var used := img.get_used_rect()
	var out: Rect2 = full if used.size.x <= 0 or used.size.y <= 0 else Rect2(used)
	_ink_rects[key] = out
	return out


static func _index_for(ts: TileSet, src_id: int) -> TileKindIndex:
	if ts == null:
		return null
	var key := "%s#%d" % [ts.resource_path, src_id]
	if not _indices.has(key):
		_indices[key] = TileKindIndex.new(ts, src_id)
	return _indices[key]


# Swatches are child TextureRects rather than draw_texture calls in _draw() so the
# ink material applies to THEM alone: a CanvasItem's material covers everything
# that item draws, so hanging it on this node would push the title text through the
# ramp too.
func _rebuild() -> void:
	# Null-tolerant: every setter above fires during scene load, before the node is
	# in the tree and before `tileset` is assigned.
	if not is_inside_tree():
		return
	for r: TextureRect in _swatches + _cost_icons:
		if is_instance_valid(r):
			# remove_child BEFORE queue_free: the free is deferred to the end of the
			# frame, so a second _rebuild in the same frame — two export setters poked
			# in a row in the editor — would otherwise see the old swatches still
			# parented and count them alongside the new ones.
			remove_child(r)
			r.queue_free()
	_swatches.clear()
	_cost_icons.clear()
	_rest_positions.clear()

	var top: int = header_row_px()
	var index: int = -1
	for tex: Texture2D in swatch_textures():
		index += 1
		var cell := cell_size_for(index)
		var x: int = _cell_left(index)
		var r := PixelUI.make_icon_sized(tex)
		# ONE MATERIAL PER SWATCH, where a single shared one would once have done.
		# Hover and lock now drive `dim` per entry, so a shared material would fade
		# and brighten every swatch in the section together. duplicate() is shallow
		# — the shader and all four ramp textures stay the same objects — so
		# retuning the ink is still a single resource edit, which was the point of
		# sharing in the first place.
		if ink_material != null:
			r.material = ink_material.duplicate() as ShaderMaterial
		# Centred in its cell by its INK, not by its texture, then floored to
		# whole texels (a swatch on a half texel resamples the 32px pixel art the
		# whole style depends on staying hard).
		#
		# By ink because these are atlas cut-outs and the art does not fill them:
		# a ladder inks cols 16..29 of its 32-wide cell — the right half only —
		# while a fence inks 4..27. Centring the TEXTURES lines up their
		# transparent margins and leaves the visible pictures lopsided, close
		# enough to touch. Measured: at 18 and 26 texel cells the ladder and fence
		# ink overlapped by 4 texels while both cells stayed clear of each other.
		var art := tex.get_size()
		var ink := _ink_rect(tex)
		r.position = Vector2(
			floorf(x + (float(cell.x) - ink.size.x) * 0.5 - ink.position.x),
			floorf(top + (float(cell.y) - ink.size.y) * 0.5 - ink.position.y))
		_rest_positions.append(r.position)
		add_child(r)
		# Deliberately NOT set_owner: under @tool an owned child would be written
		# into field_journal.tscn, and the authored arrays would then have a stale
		# duplicate of themselves baked in beside them.
		_swatches.append(r)

	# A SECOND pass, after every swatch, because child order is draw order and a
	# price is an annotation ON the picture: a 32px swatch's transparent margin
	# reaches into its neighbour's cell, and adding each coin next to its own
	# swatch would bury it under the following one the moment the art grows.
	if cost_icon != null:
		for i in _swatches.size():
			var g := PixelUI.make_icon_sized(cost_icon)
			# Drawn into a fixed square rather than at the texture's own size, the
			# same stance RunCalendar takes with the same glyph: a wrong-sized coin
			# should be visibly stretched here, not silently shove its digits out of
			# the cell and leave the layout looking merely cramped.
			g.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			g.stretch_mode = TextureRect.STRETCH_SCALE
			g.custom_minimum_size = Vector2(COST_ICON_PX, COST_ICON_PX)
			g.size = Vector2(COST_ICON_PX, COST_ICON_PX)
			if ink_material != null:
				g.material = ink_material.duplicate() as ShaderMaterial
			# Owned until told otherwise, and an owned entry has no price.
			g.visible = false
			add_child(g)
			_cost_icons.append(g)

	_apply_states()


func _draw() -> void:
	# The rule gets a block of its own here, unlike the calendar's — what sits under
	# this heading is a 36-texel swatch row, not 8px body copy, so there is nothing
	# to share a block with.
	JournalTitle.draw(self, active_header_font(), header_font_size, title,
		int(size.x), text_color,
		maxi(1, block_px) + header_underline_offset_px)
	_draw_costs()


# The unlock price beside each LOCKED swatch, in the data face (Tiny5-8, from
# the theme). Anchored to the cell's bottom-right: baseline 2px above the cell
# bottom keeps every ink row inside the cell's LOWER warp block, clear of both
# seams (the block-seam rule — ink flush against a block edge gets duplicated
# or dropped by the page warp).
#
# The DIGITS only. Their coin is a child TextureRect (see `cost_icon`) because it
# needs the ink ramp and these must not — this node's material would cover both.
func _draw_costs() -> void:
	var face := get_theme_font(&"font", &"Label")
	if face == null:
		return
	for i in _swatches.size():
		var state := _state_for(i)
		if not state.get("locked", false):
			continue
		var text := _cost_text(i)
		var rect := entry_rect(i)
		var w: float = _cost_text_width(face, i)
		var color := text_color if state.get("affordable", false) \
				else Palette.with_alpha(text_color, LOCKED_ALPHA)
		if i == _denied and _deny_phase > 0.0:
			# The one place this page prints something that is NOT a journal ink
			# ramp stop. A refusal has to read at a glance, and the ramps are low
			# contrast by authoring (see the tests' minimum-luminance guard) — every
			# red in them sits within a shade of the brown it would replace. It is
			# transient and code-side, so it never reaches the authored-colour rule
			# the ramps exist to enforce.
			color = Palette.with_alpha(Palette.DANGER, _deny_phase)
		draw_string(face,
				Vector2(_cost_number_x(i, w), rect.end.y - COST_MARGIN_PX),
				text, HORIZONTAL_ALIGNMENT_LEFT, -1, COST_FONT_SIZE, color)
