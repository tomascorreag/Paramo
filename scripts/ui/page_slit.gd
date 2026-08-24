@tool
class_name PageSlit
extends SubViewportContainer

## A slot cut through a journal page: renders its contents into a SubViewport,
## then draws that through assets/shaders/page_slit.gdshader, which masks
## everything outside a horizontal band whose lips follow the page's curl.
##
## Holds the season wheel. The wheel is a disc mounted BEHIND the book, so it must
## not bend with the paper — but the hole it shows through is cut into the paper,
## so the hole does. That is the whole reason this exists as the complement of
## PageWarp rather than as another warped page element.
##
## Expected children:
##   SubViewport            same size as this container
##     <whatever shows through the slot>
##
## All the curl parameters are READ OFF the page (`page`) rather than re-authored
## here, so the slot cannot drift from the text printed around it: one edit to
## resources/ui/page_curl_*.tres re-bends both.
##
## @tool so the cut composites live in the editor — drag this node and the band
## re-derives its position on the page immediately.

## The page this slot is cut into. Supplies the curves, the amplitudes, the row
## quantisation and the content rect the band is positioned against.
@export var page: PageWarp:
	set(value):
		if page == value:
			return
		_disconnect_page()
		page = value
		_connect_page()
		_refresh()

## Vertical padding above and below the visible band, in texels. Must be at least
## the page's warp amplitude: the band travels that far and the shader has no
## clamp, so anything less crops the slot near the spine. Mirrors PageWarp's
## "Content is inset by exactly the amplitude" convention.
@export var slit_inset_px: float = 9.0:
	set(value):
		slit_inset_px = value
		_refresh()

@export_group("Cut shadow")
## Shade sitting BEHIND the slot's contents, ramping up from the BOTTOM lip over
## this many texels. Replaces the old 32px gradient backdrop; 0 disables it.
@export var shadow_height_px: float = 4.0:
	set(value):
		shadow_height_px = value
		_refresh()

## Peak alpha at the lip itself.
@export_range(0.0, 1.0) var shadow_strength: float = 0.5:
	set(value):
		shadow_strength = value
		_refresh()

## Tapers the shade's height to nothing across this many texels at each end of the
## slot, rounding off its top corners so it reads as shade inside a cut rather
## than a rectangle laid on the page.
@export var shadow_feather_px: float = 5.0:
	set(value):
		shadow_feather_px = value
		_refresh()

@export var shadow_color: Color = Palette.P30:
	set(value):
		shadow_color = value
		_refresh()

var _curve_tex: CurveTexture


func _ready() -> void:
	resized.connect(_refresh)
	_connect_page()
	_refresh()


func _sub_viewport() -> SubViewport:
	for child in get_children():
		if child is SubViewport:
			return child as SubViewport
	return null


# The page's Content rect is the flat (outer-edge) page, in the page container's
# local space; both nodes are siblings under Pages, so adding the container's own
# position puts it in the space this node's position is already expressed in.
func _page_content() -> Control:
	if page == null:
		return null
	var sub := page.get_node_or_null(^"SubViewport") as SubViewport
	if sub == null:
		return null
	return sub.get_node_or_null(^"Content") as Control


func _connect_page() -> void:
	for curve: Curve in _page_curves():
		if not curve.changed.is_connected(_refresh):
			curve.changed.connect(_refresh)


func _disconnect_page() -> void:
	for curve: Curve in _page_curves():
		if curve.changed.is_connected(_refresh):
			curve.changed.disconnect(_refresh)


func _page_curves() -> Array[Curve]:
	var out: Array[Curve] = []
	if page == null:
		return out
	for curve: Curve in [page.curve_top, page.curve_bottom]:
		if curve != null:
			out.append(curve)
	return out


# Null-tolerant everywhere: the setters fire during scene load, before `page` or
# the SubViewport child exist, and a @tool script that throws there takes the
# editor and every journal test down with it.
func _refresh() -> void:
	var mat := material as ShaderMaterial
	var sub := _sub_viewport()
	var content := _page_content()
	if mat == null or sub == null or content == null:
		return

	var page_x: float = page.position.x + content.position.x
	var page_y: float = page.position.y + content.position.y
	var page_w: float = maxf(1.0, content.size.x)
	var half_h: float = maxf(1.0, 0.5 * content.size.y)

	# Horizontal span, in the page's own curve domain. Mirroring here rather than
	# in the shader means a flipped page just hands over a reversed interval.
	var u0: float = (position.x - page_x) / page_w
	var u1: float = (position.x + float(sub.size.x) - page_x) / page_w
	if page.flip_x:
		u0 = 1.0 - u0
		u1 = 1.0 - u1

	# One value for the whole band: evaluate PageWarp's weighting at the band's
	# centre row, through the SAME row quantisation the page uses, so the slot sits
	# in the same 9px block as the text beside it instead of a texel off.
	var mid: float = position.y + 0.5 * float(sub.size.y) - page_y
	var block: float = page.row_block_px
	if block > 0.0:
		mid = (floor(mid / block) + 0.5) * block
	var w: float = clampf((half_h - mid) / half_h, -1.0, 1.0)
	var curve: Curve = page.curve_top if w > 0.0 else page.curve_bottom
	var amp: float = page.amplitude_top_px if w > 0.0 else page.amplitude_bottom_px

	_curve_tex = _bake(_curve_tex, curve, int(page_w))
	mat.set_shader_parameter(&"curve_tex", _curve_tex)
	mat.set_shader_parameter(&"amp_px", amp * absf(w))
	mat.set_shader_parameter(&"u_min", u0)
	mat.set_shader_parameter(&"u_max", u1)
	mat.set_shader_parameter(&"rect_w_px", float(sub.size.x))
	mat.set_shader_parameter(&"rect_h_px", float(sub.size.y))
	mat.set_shader_parameter(&"slit_top_px", slit_inset_px)
	mat.set_shader_parameter(&"slit_bottom_px", float(sub.size.y) - slit_inset_px)
	mat.set_shader_parameter(&"shadow_color", shadow_color)
	mat.set_shader_parameter(&"shadow_h_px", shadow_height_px)
	mat.set_shader_parameter(&"shadow_strength", shadow_strength)
	mat.set_shader_parameter(&"shadow_feather_px", shadow_feather_px)
	queue_redraw()


func _bake(existing: CurveTexture, curve: Curve, width: int) -> CurveTexture:
	if curve == null:
		return null
	var tex := existing if existing != null else CurveTexture.new()
	tex.texture_mode = CurveTexture.TEXTURE_MODE_RED
	tex.width = maxi(1, width)
	tex.curve = curve
	return tex


## Texel height of the band actually shown, i.e. the rect minus both insets.
func visible_height_px() -> float:
	var sub := _sub_viewport()
	if sub == null:
		return 0.0
	return float(sub.size.y) - 2.0 * slit_inset_px
