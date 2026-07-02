class_name PixelUI
extends RefCounted

## Shared procedural UI primitives that snap to the fake-low-res pixel grid.
##
## The project fakes a low resolution by upscaling the whole 480x270 canvas by an
## integer factor (see DisplayManager), so anything authored on integer texels
## stays crisp. These helpers keep the "build UI in code" paths (HUD, radial menu,
## loading overlay) consistent instead of each re-deriving the same setup.
##
## No grid-snap helper is provided on purpose: every fractional position in the
## project today is a deliberate animation (menu burst, radial fan-out, icon
## follow) where snapping would cause visible stair-stepping. Add one only when a
## static procedural placement actually needs it.

## Global frame cache, shared across all UI (keyed by "border|fill"). Bounded by
## the number of distinct color pairs — tiny.
static var _frame_cache: Dictionary = {}


## LEGACY (dynamic path). Synthesized 1-texel chamfer frame. The shipping UI now
## uses authored StyleBox .tres from the atlas sprites (resources/ui/styleboxes/
## via the global theme); this remains only for code that needs a runtime frame
## from arbitrary colors. Builds (or returns cached) a StyleBoxTexture whose 3x3
## source has transparent corners, single-texel border edges, and a single-texel
## fill (texture_margin = 1 keeps corners 1:1 while edges/interior stretch).
##   T B T
##   B F B
##   T B T
static func frame_stylebox(border: Color, fill: Color) -> StyleBoxTexture:
	var key := "%s|%s" % [border.to_html(true), fill.to_html(true)]
	if _frame_cache.has(key):
		return _frame_cache[key]

	var img := Image.create(3, 3, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	img.set_pixel(1, 0, border)
	img.set_pixel(0, 1, border)
	img.set_pixel(2, 1, border)
	img.set_pixel(1, 2, border)
	img.set_pixel(1, 1, fill)

	var sb := StyleBoxTexture.new()
	sb.texture = ImageTexture.create_from_image(img)
	sb.texture_margin_left = 1
	sb.texture_margin_top = 1
	sb.texture_margin_right = 1
	sb.texture_margin_bottom = 1
	_frame_cache[key] = sb
	return sb


## Icon that fills its parent Control (equipped slot, item button, radial center).
## Nearest filter keeps pixels crisp; ignores mouse so it doesn't eat clicks.
static func make_icon_fill(tex: Texture2D) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex
	r.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return r


## Icon sized to its texture; the caller positions it (radial menu item).
static func make_icon_sized(tex: Texture2D) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex
	r.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	r.custom_minimum_size = tex.get_size()
	r.size = tex.get_size()
	return r


# --- PNG-sprite nine-patch frames -------------------------------------------
#
# The UX atlas (icons.png) carries hand-drawn rounded-rect corner sprites in its
# second row. Unlike frame_stylebox (which synthesizes a 1-texel chamfer from raw
# colors), these are authored art. Godot 9-slices them at runtime via a
# StyleBoxTexture's region_rect + texture_margin — no need to pre-cut the sheet
# (the equivalent of Unity's sprite border). The sprites are WHITE masks, so
# modulate_color tints them to any palette color.
#
# Tight bounding boxes + corner insets read from the sprite pixels:
#   frame  — hollow rounded outline, 10x10 at (3,19); 3px corner  -> outlined panels
#   solid  — filled rounded rect,     8x8 at (4,20); 2px corner   -> buttons / fills

const _ATLAS_PATH := "res://assets/sprites/UX/icons.png"
const FRAME_REGION := Rect2(3, 19, 10, 10)   # row 2, col 1 (hollow outline)
const FRAME_MARGIN := 3
const SOLID_REGION := Rect2(20, 20, 8, 8)    # row 2, col 2 (filled) — col 2 starts at x=16
const SOLID_MARGIN := 2

static var _atlas_tex: Texture2D
static var _atlas_sb_cache: Dictionary = {}   # keyed by "region|margin|tint"


static func _atlas() -> Texture2D:
	if _atlas_tex == null:
		_atlas_tex = load(_ATLAS_PATH)
	return _atlas_tex


## StyleBoxTexture 9-sliced from an atlas region, tinted. Cached like
## frame_stylebox. `margin` is the fixed corner inset (texels that don't stretch).
static func atlas_stylebox(region: Rect2, margin: int, tint: Color = Color.WHITE) -> StyleBoxTexture:
	var key := "%s|%d|%s" % [region, margin, tint.to_html(true)]
	if _atlas_sb_cache.has(key):
		return _atlas_sb_cache[key]

	var sb := StyleBoxTexture.new()
	sb.texture = _atlas()
	sb.region_rect = region
	sb.texture_margin_left = margin
	sb.texture_margin_top = margin
	sb.texture_margin_right = margin
	sb.texture_margin_bottom = margin
	sb.modulate_color = tint
	_atlas_sb_cache[key] = sb
	return sb


## Filled rounded rect — for buttons and solid fills.
static func solid_stylebox(tint: Color) -> StyleBoxTexture:
	return atlas_stylebox(SOLID_REGION, SOLID_MARGIN, tint)


## Standalone stretchable frame node (border overlaid on a filled panel).
## Nearest filter, ignores mouse, fills its parent.
static func make_frame_ninepatch(tint: Color) -> NinePatchRect:
	var np := _ninepatch(FRAME_REGION, FRAME_MARGIN, tint)
	np.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return np


## Standalone stretchable FILLED rounded rect (the solid sprite). Caller sizes
## and positions it — e.g. the pause-button bars, or a fill behind a frame where
## a stylebox isn't convenient. Nearest filter, ignores mouse.
static func make_solid_ninepatch(tint: Color) -> NinePatchRect:
	return _ninepatch(SOLID_REGION, SOLID_MARGIN, tint)


static func _ninepatch(region: Rect2, margin: int, tint: Color) -> NinePatchRect:
	var np := NinePatchRect.new()
	np.texture = _atlas()
	np.region_rect = region
	np.patch_margin_left = margin
	np.patch_margin_top = margin
	np.patch_margin_right = margin
	np.patch_margin_bottom = margin
	np.self_modulate = tint
	np.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	np.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return np
