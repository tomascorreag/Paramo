class_name FireShaderWarmup
extends Node

# Draws the fire shaders BEFORE the player can see a fire, so their first-draw
# cost does not land on the frame a burning cell first enters the view.
#
# --- WHY THIS EXISTS ---------------------------------------------------------
#
# Under gl_compatibility a canvas shader is compiled and linked the first time it
# is actually DRAWN, synchronously, on the main thread — and a CanvasItem outside
# the camera rect is culled, so it is never drawn. That is why the hitch tracked
# to "fire comes on screen" rather than to ignition: FireManager can light a
# front two screens away for nothing, and the whole bill arrives on the frame the
# camera reaches it.
#
# MEASURED with scripts/tools/profile_fire_reveal.gd (level1, RTX 3080, 960x540,
# vsync off, median frame ~1.8 ms), one 40-cell front revealed at once:
# **6.10 ms -> 2.83 ms on the reveal frame, the warm-up ahead in 10 of 11 paired
# cold runs.** Re-revealing the same fire costs ~1.1x median in both arms, which
# is what identifies the cost as first-draw rather than as culling or node work.
#
# THIS DOES NOT MOVE THE COST TO IGNITION, which is the obvious objection and was
# measured rather than argued: over those same 11 pairs the ignition frame cost
# 9.63 ms without the warm-up and 9.01 ms with it, the warm-up ahead in 6 of 11 —
# a coin flip. Igniting 40 cells inside one frame IS the largest spike in the
# recording, but it is CPU work (40 BurningCellVFX, each duplicating a material,
# baking a texture and adding a PointLight2D) and it is identical in both arms.
# It cannot be shader work: those nodes are off screen and culled on the frame
# they are created, so nothing draws. Staggered ignition is the lever there, not
# this node. See dev-notes/vfx.md.
#
# Two things that measurement will mislead you about:
#
#   - **A six-cell fire cannot see this effect.** At --fires 6 the reveal frame
#     sits inside run-to-run noise (12 paired runs, the warm-up ahead in only 8).
#     The effect scales with how much is revealed at once. Size the cluster.
#   - **Deleting .godot/shader_cache does NOT get you back to cold.** The GL
#     driver keeps its own program cache keyed by shader source, so the second run
#     of an experiment re-links from that and the spike disappears. Use
#     profile_fire_reveal's --cold, which makes the source unique per run and so
#     misses both caches.
#
# --- HOW ---------------------------------------------------------------------
#
# One SubViewport off the tree's render path (no SubViewportContainer, so nothing
# composites it anywhere), fed ONE item per frame and then freed. Same trick the
# world already uses — ProceduralWorld holds the loading overlay up for
# SHADER_WARM_FRAMES so water/post-process compile behind it — except fire has
# nothing on screen at load time to warm itself with.
#
# --- WHY ONE ITEM PER FRAME --------------------------------------------------
#
# The first version added every item at once and rendered for three frames, which
# only relocated the pile-up: all of it landed on the first of those three. That
# is the same mistake as the reveal frame, one level down. Each item now takes its
# own frame, so the warm-up's cost is spread over as many frames as there are
# items rather than concentrated in one. On an RTX 3080 the whole thing measured
# 0.84 ms, which is nothing — but the reason this node exists at all is that the
# shipping target is WebGL2, where the same work is orders of magnitude dearer
# and a pile-up would show even behind the loading overlay.
#
# --- WHY THE VIEWPORT HAS A LIT AND AN UNLIT HALF ----------------------------
#
# Canvas lighting is a separate shader permutation, and the game draws fire BOTH
# ways: a burning cell normally sits under its own PointLight2D, but cells past
# BurningCellVFX.LIGHT_BUDGET get none. Warming one permutation would leave the
# other to be paid on the reveal frame.
#
# So the light covers only the RIGHT half of the viewport and every shader is
# warmed twice — once at UNLIT_X, once at LIT_X. Two items, two frames, both
# permutations, and neither shares a frame with anything else.
#
# The items are the REAL node types with the REAL shader resources, deliberately.
# A program is keyed by shader source plus the draw path that binds it, so a
# stand-in ColorRect for something the game draws as a Sprite2D can warm the
# wrong permutation and still look like it worked.

## Fire shaders the game can draw, and where each is drawn from. `fire.gdshader`
## is deliberately ABSENT: it is the legacy sprite-flame path behind
## Debug.fire_blob_flames, which ships off, so warming it would charge every
## player a compile for something they never see. Flip that toggle and the first
## fire hitches — that is the intended trade, not an oversight.
const WARM_SHADERS: Array[String] = [
	"res://assets/shaders/fire_blobs.gdshader",   # FireBlobColumn
	"res://assets/shaders/burn_dissolve.gdshader",# BurningCellVFX grass overlay
	"res://assets/shaders/burn_char.gdshader",    # Frailejon, charring
	"res://assets/shaders/fire_aura.gdshader",    # FireAuraOverlay
]

const _BURN_DISSOLVE: Shader = preload("res://assets/shaders/burn_dissolve.gdshader")
const _BURN_CHAR: Shader = preload("res://assets/shaders/burn_char.gdshader")
const _AURA_MATERIAL: ShaderMaterial = preload("res://resources/materials/fire_aura.tres")

## Two columns of warm-up items side by side: the left sits outside the light,
## the right inside it. Tall enough for a full-intensity blob column, which rises
## ~40 px above its base and is the largest quad the shader ever draws. Nothing
## samples this viewport, so the size matters only because a quad clipped to
## nothing may never reach the rasteriser — and then nothing compiles.
const VIEWPORT_SIZE: Vector2i = Vector2i(128, 64)
const UNLIT_X: float = 32.0
const LIT_X: float = 96.0
const ITEM_Y: float = 32.0

## Frames to keep rendering after the last item lands, before freeing. One draw
## is all a compile needs; the spare frames cover a driver that defers the link.
const SETTLE_FRAMES: int = 2

# Item builders, drained one per frame. Each entry is [builder, lit], and every
# shader appears twice — see the header on the two permutations.
var _queue: Array = []
var _settle_left: int = SETTLE_FRAMES
var _viewport: SubViewport = null


func _ready() -> void:
	# The warm-up must survive a paused tree: the loading overlay and the title
	# cinematic are exactly when this wants to run, and the run is paused through
	# some of that.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_viewport = _build_viewport()
	add_child(_viewport)
	# The light goes in FIRST and stays. It has to already be there when a lit
	# item takes its turn, and it costs nothing on the frames it lights nothing.
	_viewport.add_child(_build_light())
	for lit: bool in [false, true]:
		_queue.append([_build_column, lit])
		_queue.append([_build_dissolve_quad, lit])
		_queue.append([_build_char_quad, lit])
		_queue.append([_build_aura, lit])


func _process(_delta: float) -> void:
	if not _queue.is_empty():
		var entry: Array = _queue.pop_front()
		var builder: Callable = entry[0]
		_viewport.add_child(builder.call(entry[1] as bool))
		return
	_settle_left -= 1
	if _settle_left <= 0:
		queue_free()


## How many frames this node will live for. The tests assert against it rather
## than re-deriving the arithmetic, and it is the number to look at when asking
## whether the warm-up is still finished before the player can see a fire.
func frames_needed() -> int:
	return _queue.size() + SETTLE_FRAMES


func _build_viewport() -> SubViewport:
	var vp := SubViewport.new()
	vp.name = "FireShaderWarmupViewport"
	vp.size = VIEWPORT_SIZE
	vp.transparent_bg = true
	vp.disable_3d = true
	# UPDATE_ALWAYS, not UPDATE_ONCE: ONCE clears itself back to DISABLED after a
	# single frame, and this viewport has to keep drawing while the queue drains.
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	return vp


## Sized and placed to cover the LIT half only, so an item at UNLIT_X is genuinely
## outside it. PointLight2D draws nothing without a texture, and a light that
## draws nothing warms no lit permutation.
func _build_light() -> PointLight2D:
	var light := PointLight2D.new()
	light.texture = _white_texture(VIEWPORT_SIZE.y)
	light.position = Vector2(LIT_X, ITEM_Y)
	return light


func _item_x(lit: bool) -> float:
	return LIT_X if lit else UNLIT_X


# --- The items ---------------------------------------------------------------
# Each returns ONE node, built on the frame it is added. Constructing lazily
# rather than up front is what keeps the per-frame cost even: FireBlobColumn's
# _init duplicates a material and bakes a texture, and that work would otherwise
# land in _ready alongside everything else.

## The real renderable, configured exactly as BurningCellVFX configures it: a
## full-intensity column, the largest quad the shader ever draws.
func _build_column(lit: bool) -> Node:
	var column := FireBlobColumn.new()
	column.position = Vector2(_item_x(lit), ITEM_Y)
	column.set_cell_seed(FireBlobColumn.seed_for_cell(Vector2i.ZERO))
	column.set_intensity(1.0)
	return column


func _build_dissolve_quad(lit: bool) -> Node:
	return _quad(_material_for(_BURN_DISSOLVE, &"burn_amount", 0.5), lit)


func _build_char_quad(lit: bool) -> Node:
	return _quad(_material_for(_BURN_CHAR, &"burn_amount", 0.5), lit)


## The aura is a ColorRect in gameplay_base, and a rect is not a sprite quad —
## warm it the way it draws. Half-width so it stays on its own side of the light.
func _build_aura(lit: bool) -> Node:
	var aura := ColorRect.new()
	aura.material = _AURA_MATERIAL
	aura.size = Vector2(VIEWPORT_SIZE.x * 0.5, VIEWPORT_SIZE.y)
	aura.position = Vector2(_item_x(lit) - VIEWPORT_SIZE.x * 0.25, 0.0)
	return aura


# ----------------------------------------------------------------------------

## A Sprite2D carrying `mat`, sized to a tile rather than to its 1x1 texture so
## the draw actually covers fragments.
func _quad(mat: ShaderMaterial, lit: bool) -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = _white_texture(1)
	s.scale = Vector2(32, 32)
	s.position = Vector2(_item_x(lit), ITEM_Y)
	s.material = mat
	return s


func _material_for(shader: Shader, param: StringName, value: float) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter(param, value)
	return mat


func _white_texture(px: int) -> ImageTexture:
	var img := Image.create(px, px, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	return ImageTexture.create_from_image(img)
