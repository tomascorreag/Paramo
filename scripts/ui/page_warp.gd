@tool
class_name PageWarp
extends SubViewportContainer

## One journal page: renders its content into a SubViewport, then draws that
## through assets/shaders/page_warp.gdshader so the content bends onto the page
## drawn in Book.png (each page edge sweeps 9px outward toward the spine).
##
## Expected children, both required:
##   SubViewport            sized (page width) x (content height + 2 * amplitude)
##     Content : Control    the page's flat content rect, inset by the amplitude
##
## The geometry uniforms are DERIVED from those two nodes rather than duplicated
## here, so moving the page in the editor cannot desync the shader from the scene.
## Both curves are shared .tres resources driving both pages; the right page
## mirrors them with `flip_x` instead of owning its own pair.
##
## @tool so the warp composites live in the editor: edit a curve in the FileSystem
## dock and the page re-bends in the 2D view immediately. (Note that SubViewport
## contents are not drawn on the editor canvas, so the content INSIDE the page is
## positioned via the Inspector, not by dragging.)

## Top-edge profile. X = 0 at the page's outer edge -> 1 at the spine, Y = fraction
## of amplitude_top_px. See resources/ui/page_curl_top.tres.
@export var curve_top: Curve:
	set(value):
		if curve_top == value:
			return
		_disconnect_curve(curve_top)
		curve_top = value
		_connect_curve(curve_top)
		_refresh()

## Bottom-edge profile, same domain. See resources/ui/page_curl_bottom.tres.
@export var curve_bottom: Curve:
	set(value):
		if curve_bottom == value:
			return
		_disconnect_curve(curve_bottom)
		curve_bottom = value
		_connect_curve(curve_bottom)
		_refresh()

## Signed pixel travel of each edge at the spine. Negative is upward, so the
## measured art is (-9, +9): both edges move 9px, mirrored. These must match the
## SubViewport's vertical padding — the shader spends exactly this much slack.
@export var amplitude_top_px: float = -9.0:
	set(value):
		amplitude_top_px = value
		_refresh()

@export var amplitude_bottom_px: float = 9.0:
	set(value):
		amplitude_bottom_px = value
		_refresh()

## Mirror the curves horizontally. The right page's spine is on its LEFT, so it
## sets this and the left page does not.
@export var flip_x: bool = false:
	set(value):
		flip_x = value
		_refresh()

## Quantise the warp to blocks this many pixels tall; 0 = per-pixel. Defaults to 9,
## the line height of the journal's 8px font: each line of text then translates as a
## rigid block, where per-pixel visibly duplicates scanlines *inside* glyphs (see
## the shader header, and scripts/tools/preview_page_warp.gd --rows to A/B it).
##
## Blocks are measured from the Content rect's top, so page TEXT must start at a
## multiple of this from that top or every line straddles two blocks and the
## artefact comes back at glyph bottoms. Drop this to 0 for a page holding pictures
## rather than text — an image has no lines to keep whole.
@export var row_block_px: float = 9.0:
	set(value):
		row_block_px = value
		_refresh()

## Quantise the sampled COLUMN to blocks this many pixels wide; 0 = per-column.
##
## The other axis's version of row_block_px, against a different artefact. The
## rounded offset is a stair with one step per texel of amplitude, at fixed columns;
## a step landing mid-glyph shears the letter. Setting this to the body face's
## advance width (4 for Tiny5 at 8) moves the steps onto the glyph grid so they fall
## between letters instead. A mitigation, not a cure: it relocates the steps, it
## cannot remove them, and text drifts off the grid at any narrower or wider glyph.
@export var col_block_px: float = 0.0:
	set(value):
		col_block_px = value
		_refresh()

var _curve_tex_top: CurveTexture
var _curve_tex_bottom: CurveTexture


func _ready() -> void:
	var sub := _sub_viewport()
	if sub != null and not sub.size_changed.is_connected(_refresh):
		sub.size_changed.connect(_refresh)
	var content := _content()
	if content != null and not content.resized.is_connected(_refresh):
		content.resized.connect(_refresh)
	_connect_curve(curve_top)
	_connect_curve(curve_bottom)
	_refresh()


# Every lookup is null-tolerant: the setters above fire during scene load, BEFORE
# the SubViewport/Content children exist, and @tool code that throws there breaks
# both the editor and every test that instantiates the journal scene.
func _sub_viewport() -> SubViewport:
	for child in get_children():
		if child is SubViewport:
			return child as SubViewport
	return null


func _content() -> Control:
	var sub := _sub_viewport()
	if sub == null:
		return null
	return sub.get_node_or_null(^"Content") as Control


func _connect_curve(curve: Curve) -> void:
	if curve != null and not curve.changed.is_connected(_on_curve_changed):
		curve.changed.connect(_on_curve_changed)


func _disconnect_curve(curve: Curve) -> void:
	if curve != null and curve.changed.is_connected(_on_curve_changed):
		curve.changed.disconnect(_on_curve_changed)


# CurveTexture re-bakes itself in place on the same RID when its Curve emits
# `changed`, so the sampler needs no reassignment — but the editor's 2D view only
# recomposites the container if we ask it to.
func _on_curve_changed() -> void:
	queue_redraw()


func _refresh() -> void:
	var mat := material as ShaderMaterial
	if mat == null:
		return
	var sub := _sub_viewport()
	var content := _content()
	if sub == null or content == null:
		return
	var page_w: int = maxi(1, sub.size.x)

	# One texel per page column: the sample is then exact and filter_nearest costs
	# nothing in precision (and dodges WebGL2's float-linear extension — see the
	# shader header).
	_curve_tex_top = _bake(_curve_tex_top, curve_top, page_w)
	_curve_tex_bottom = _bake(_curve_tex_bottom, curve_bottom, page_w)

	mat.set_shader_parameter(&"curve_top_tex", _curve_tex_top)
	mat.set_shader_parameter(&"curve_bottom_tex", _curve_tex_bottom)
	mat.set_shader_parameter(&"amp_top_px", amplitude_top_px)
	mat.set_shader_parameter(&"amp_bottom_px", amplitude_bottom_px)
	mat.set_shader_parameter(&"tex_h_px", float(sub.size.y))
	mat.set_shader_parameter(&"content_top_px", content.position.y)
	mat.set_shader_parameter(&"content_h_px", content.size.y)
	mat.set_shader_parameter(&"row_block_px", row_block_px)
	mat.set_shader_parameter(&"tex_w_px", float(sub.size.x))
	mat.set_shader_parameter(&"col_block_px", col_block_px)
	mat.set_shader_parameter(&"flip_x", flip_x)
	queue_redraw()


func _bake(existing: CurveTexture, curve: Curve, width: int) -> CurveTexture:
	if curve == null:
		return null
	var tex := existing if existing != null else CurveTexture.new()
	tex.texture_mode = CurveTexture.TEXTURE_MODE_RED
	tex.width = width
	tex.curve = curve
	return tex
