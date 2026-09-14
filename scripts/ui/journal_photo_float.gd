class_name JournalPhotoFloat
extends TextureRect

## One rect of a journal page — a photograph, or the polaroid frame around it —
## drawn OVER the book at window resolution and bent to the page with
## assets/shaders/photo_warp.gdshader.
##
## The page's content is rendered into a 157x231 SubViewport at one texel per
## logical pixel, so anything inside it is pixel art by construction — the first
## bitacora printed its herbarium sheets in there and they came out as 64x72
## blocks. A photograph needs more pixels than its logical rect: this node
## floats over BookArt (like JournalTooltip and the fore-edge tabs), so the
## window rasterises it at its own resolution, with a 256x288 texture and
## LINEAR filtering — 1:1 physical pixels at the 4x upscale.
##
## But a flat picture over a warped page floats off it near the spine, so the
## shader bends this rect with page_warp's own arithmetic, on the page's own
## curves. Every uniform is pushed from the PageWarp the photo sits on, and the
## rect is padded by the warp amplitude so the displaced picture never leaves
## it.
##
## Two of these per plate: the photograph (LINEAR filter — a 216x216 texture
## through a 54x54 rect) and, on top of it, the polaroid frame (NEAREST — it is
## 68x79 pixel art drawn at 1:1). The plate places both from its own geometry
## and shows them while it is itself visible. Nothing is drawn by this node's
## own `_draw`: a CanvasItem's material covers everything the item draws, and
## the warp shader sampling a `draw_rect`'s 1x1 white TEXTURE printed a strip
## white (measured, when tape strips lived here: 10 off-palette pixels a page).

const _SHADER: Shader = preload("res://assets/shaders/photo_warp.gdshader")

## Rows the rect is padded above and below the picture: the warp's reach.
const PAD_Y_PX: int = 6
const PAD_X_PX: int = 0

var _page: PageWarp = null
var _content: Control = null
## The photograph's rect in the page's CONTENT space (what the plate reports).
var _photo: Rect2i = Rect2i()


func _init(filter: CanvasItem.TextureFilter = CanvasItem.TEXTURE_FILTER_LINEAR) -> void:
	name = "PhotoFloat"
	texture_filter = filter
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_SCALE
	material = ShaderMaterial.new()
	(material as ShaderMaterial).shader = _SHADER
	visible = false


## Place the picture. `photo` is its LOGICAL rect in `content`'s space (the
## plate's own space, which sits at the content's origin).
func place(page: PageWarp, content: Control, photo: Rect2i) -> void:
	_page = page
	_content = content
	_photo = photo
	_refresh()


## The photograph's rect in this node's parent's (BookArt's) space, unpadded.
func photo_rect_in_book() -> Rect2i:
	if _page == null or _content == null:
		return Rect2i()
	return Rect2i(Vector2i(_page.position) + Vector2i(_content.position) + _photo.position,
			_photo.size)


func _refresh() -> void:
	var mat := material as ShaderMaterial
	if _page == null or _content == null or mat == null or _photo.size == Vector2i.ZERO:
		return
	var page_mat := _page.material as ShaderMaterial
	var sub := _page.get_node_or_null(^"SubViewport") as SubViewport
	if page_mat == null or sub == null:
		return
	# Where this rect sits in BOOK space: the page's origin plus the content's
	# inset plus the photo, grown by the padding.
	var book := photo_rect_in_book()
	position = Vector2(book.position - Vector2i(PAD_X_PX, PAD_Y_PX))
	size = Vector2(book.size + 2 * Vector2i(PAD_X_PX, PAD_Y_PX))
	# ...and in the page TEXTURE's texel space, which is what the warp
	# arithmetic runs in: the content is inset by content.position inside the
	# viewport.
	var tex_photo := Rect2i(Vector2i(_content.position) + _photo.position, _photo.size)
	var tex_rect := Rect2i(tex_photo.position - Vector2i(PAD_X_PX, PAD_Y_PX),
			tex_photo.size + 2 * Vector2i(PAD_X_PX, PAD_Y_PX))
	# The page's own curve textures and geometry, so the two cannot drift.
	mat.set_shader_parameter(&"curve_top_tex", page_mat.get_shader_parameter(&"curve_top_tex"))
	mat.set_shader_parameter(&"curve_bottom_tex", page_mat.get_shader_parameter(&"curve_bottom_tex"))
	mat.set_shader_parameter(&"amp_top_px", _page.amplitude_top_px)
	mat.set_shader_parameter(&"amp_bottom_px", _page.amplitude_bottom_px)
	mat.set_shader_parameter(&"tex_h_px", float(sub.size.y))
	mat.set_shader_parameter(&"tex_w_px", float(sub.size.x))
	mat.set_shader_parameter(&"content_top_px", _content.position.y)
	mat.set_shader_parameter(&"content_h_px", _content.size.y)
	mat.set_shader_parameter(&"row_block_px", _page.row_block_px)
	mat.set_shader_parameter(&"col_block_px", _page.col_block_px)
	mat.set_shader_parameter(&"flip_x", _page.flip_x)
	mat.set_shader_parameter(&"rect_x_px", float(tex_rect.position.x))
	mat.set_shader_parameter(&"rect_y_px", float(tex_rect.position.y))
	mat.set_shader_parameter(&"rect_w_px", float(tex_rect.size.x))
	mat.set_shader_parameter(&"rect_h_px", float(tex_rect.size.y))
	mat.set_shader_parameter(&"photo_x_px", float(tex_photo.position.x))
	mat.set_shader_parameter(&"photo_y_px", float(tex_photo.position.y))
	mat.set_shader_parameter(&"photo_w_px", float(tex_photo.size.x))
	mat.set_shader_parameter(&"photo_h_px", float(tex_photo.size.y))
	queue_redraw()
