class_name SmoothPixelViewport
extends SubViewportContainer

## Hosts the low-res game world and gives it a subpixel-smooth camera.
##
## The world (TileMapLayers, entities, world-space overlays, rain, post-process)
## lives inside `world_viewport`, which rasterizes at the low-res logical size
## (window/N) — that is the N² fewer fragments on the fullscreen passes. Every
## frame this node snaps the viewport's canvas_transform to the integer texel
## grid (so the world stays pixel-crisp) and passes the leftover sub-texel
## remainder to `subpixel_offset.gdshader` on itself, which slides the upscaled
## quad by that fraction — smooth panning at monitor-pixel resolution.
##
## Why this and not the old DisplayManager VIEWPORT stretch mode: VIEWPORT drags
## the UI onto the low-res grid too (chunky text). This gives low-res world AND
## full-res UI at once — UI stays as CanvasLayers on the ROOT, outside this node.
##
## Boundary convention (keep this true as content grows): anything that should
## rasterize low-res + ride the smooth camera goes UNDER world_viewport (world,
## world-space overlays, day/night modulate, rain, grade passes). Anything
## screen-space and crisp (HUD, menus, debug chrome) stays on the root, outside.
##
## Camera-agnostic: it reads whatever Camera2D is `current` inside the viewport
## (Player cam, FreeCamera, future cameras) via the viewport's canvas_transform —
## it never touches a camera node, so Camera2D.position_smoothing stays on and is
## exactly what produces the fractional scroll (snapping the camera node instead
## would fight its own smoothing — godotengine/godot#41195).

const _SHADER: Shader = preload("res://assets/shaders/subpixel_offset.gdshader")

## 1px render border on every side, so the ±sub-texel shift never blanks an edge.
## The container sits at -BORDER/2 to push that border offscreen.
const BORDER: Vector2i = Vector2i(2, 2)

## The low-res world lives here. Assign in the scene.
@export var world_viewport: SubViewport

## Calibration for the display offset (set once, in motion — see class doc).
## The offset is the raw texel remainder; content_scale applies the ×N, so the
## magnitude should be 1.0. Only the SIGN is uncertain until tested: if panning
## looks like it lags/leads the world by a texel, flip a component to -1.
@export var offset_scale: Vector2 = Vector2(1.0, 1.0)

## When false, the display offset is dropped: the world still snaps to whole
## texels but the sub-texel scroll is not re-added — i.e. the OLD choppy,
## per-texel-jump camera. Toggle in motion (debug overlay "Subpixel" row) to A/B
## smooth vs choppy and confirm the fix / calibrate the sign.
@export var smoothing_enabled: bool = true

## Turn the anti-shimmer sharp-bilinear sample off to compare against plain
## nearest. Mirrored into the shader.
@export var sharp_bilinear: bool = true:
	set(value):
		sharp_bilinear = value
		if _mat != null:
			_mat.set_shader_parameter("sharp_bilinear", value)

var _mat: ShaderMaterial


func _ready() -> void:
	# content_scale (window/N) does the ×N upscale; this container is 1:1 in the
	# logical low-res space, so DON'T let the container rescale the viewport.
	stretch = false
	# Take full control of size/position (for the border overhang) — zero the
	# anchors so the scene's full-rect layout doesn't stretch the container back
	# to the parent rect and clobber the explicit size set in _resize().
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 0.0

	_mat = ShaderMaterial.new()
	_mat.shader = _SHADER
	_mat.set_shader_parameter("sharp_bilinear", sharp_bilinear)
	material = _mat

	if world_viewport == null:
		push_error("SmoothPixelViewport: world_viewport is unset — assign the child SubViewport.")
		return
	world_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

	_resize()
	if DisplayManager.has_signal("scale_changed"):
		DisplayManager.scale_changed.connect(func(_n: int) -> void: _resize())
	get_window().size_changed.connect(_resize)
	RenderingServer.frame_pre_draw.connect(_snap)


func _exit_tree() -> void:
	if RenderingServer.frame_pre_draw.is_connected(_snap):
		RenderingServer.frame_pre_draw.disconnect(_snap)


## Size the low-res buffer to the logical viewport + border, and overhang the
## container so the border sits offscreen. Driven off DisplayManager's resize
## path so any N / window size tracks automatically — no hardcoded resolution.
func _resize() -> void:
	if world_viewport == null:
		return
	var logical: Vector2i = DisplayManager.effective_viewport_size
	if logical.x <= 0 or logical.y <= 0:
		logical = Vector2i(get_window().content_scale_size)
	world_viewport.size = logical + BORDER
	# The container renders the (logical+2) buffer 1:1; pull it up-left by 1px so
	# the extra border row/column is offscreen and the shift has room to slide.
	position = -Vector2(BORDER) * 0.5
	size = Vector2(logical + BORDER)


## Runs just before draw, after the inner camera has written the frame's
## canvas_transform. Snap its origin to whole texels (crisp raster) and pass the
## discarded fraction to the display shader (smooth scroll).
func _snap() -> void:
	if world_viewport == null:
		return
	var xform: Transform2D = world_viewport.canvas_transform
	var origin: Vector2 = xform.origin
	var snapped: Vector2 = origin.round()
	xform.origin = snapped
	world_viewport.canvas_transform = xform
	var offset: Vector2 = (origin - snapped) * offset_scale if smoothing_enabled else Vector2.ZERO
	_mat.set_shader_parameter("vertex_offset", offset)
