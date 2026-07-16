class_name FireBlobColumn
extends Sprite2D

# The renderable for the procedural blob fire: one quad per burning cell,
# running assets/shaders/fire_blobs.gdshader. Owned by BurningCellVFX, which
# places it at the cell centre.
#
# This node is deliberately dumb. It has no _process: the quad is world-parented
# so there is no camera_offset to push (unlike scripts/vfx/rain.gd, which must
# push one every frame because it lives on a CanvasLayer). Uniforms change only
# when the cell's intensity actually changes.
#
# Deliberately NOT @tool, despite being spawned by the @tool FireBlobPreview.
# Verified: a non-tool script instantiated via .new() from a tool script DOES run
# its _init in the editor and configures normally — Godot's placeholder-instance
# rule applies to scripts ATTACHED to saved nodes, not to explicit .new() calls.
# So the preview draws without it, and adding @tool would only widen when this
# script executes for no gain.
#
# GEOMETRY. The shader needs MODEL_MATRIX[3] to land exactly on the cell centre,
# because that is the origin all its blob math is relative to. So the node sits
# at Vector2.ZERO relative to BurningCellVFX (which is already at
# map_to_local(cell)) and the quad is grown around it via `offset` + `scale`
# instead of by moving the node:
#
#   texture   1x1 white, shared
#   centered  false          -> rect = Rect2(offset, Vector2.ONE)
#   offset    (-0.5, -1.0)   -> rect spans (-0.5,-1)..(0.5,0) in unscaled local
#   scale     (w, h)         -> rect spans (-w/2,-h)..(w/2,0) in parent space
#
# i.e. a column of size w x h rising from the cell centre. `offset` and `scale`
# do not touch the node's transform origin, so MODEL_MATRIX[3] stays put.

const BLOB_MATERIAL: ShaderMaterial = preload("res://resources/materials/fire_blobs.tres")

# Draw above the grass overlay and the frailejon on the same cell, matching the
# sprite flames' z_index — a burning tile should clearly read as on fire.
const Z_INDEX: int = 1

# Intensity deltas below this don't re-push uniforms. Intensity moves at
# BURN_RATE_PER_SECOND (0.10/s), so without this every cell would rewrite ~11
# uniforms every frame to no visible effect.
const INTENSITY_EPSILON: float = 0.01

# Smoke-only ceiling. Matches the shader uniform's hint_range floor: below this
# a blob is born past the last stage and nothing draws at all.
const HEAT_CEILING_MIN: float = 0.05

# Shared 1x1 white texture — the quad is pure geometry, the shader never samples
# TEXTURE. Baked once and reused by every column, mirroring
# BurningCellVFX._shared_falloff(). Never mutated, so sharing is safe.
static var _quad_tex: ImageTexture = null

var _mat: ShaderMaterial
var _intensity: float = -1.0
var _heat_ceiling: float = 1.0


# Built in _init, NOT _ready, deliberately. add_child() only runs _ready
# immediately if the parent is already inside the tree — otherwise it defers to
# the next frame. That made set_intensity() a silent no-op when it was called
# right after add_child (the material didn't exist yet, so it early-returned
# before sizing the quad, and _ready then reset everything to intensity 0).
# Configuring in the constructor means the node is valid the moment it is new()'d
# and callers can drive it in any order.
func _init() -> void:
	texture = _shared_quad_texture()
	centered = false
	offset = Vector2(-0.5, -1.0)
	z_index = Z_INDEX
	_mat = BLOB_MATERIAL.duplicate() as ShaderMaterial
	material = _mat
	# Seed so the column doesn't pop at its authored default size before the
	# first set_intensity lands.
	_apply(0.0, true)


## Decorrelates this column from every other one. MUST be set, and set to
## something different per cell — the shader defaults it to 0, and at 0 every
## burning cell on the map renders the pixel-identical fire.
func set_cell_seed(v: float) -> void:
	if _mat != null:
		_mat.set_shader_parameter(&"cell_seed", v)


## Convenience: a well-spread seed for a grid coord. Adjacent cells must land far
## apart or a spreading front reads as a repeating pattern, so this hashes rather
## than using the coord directly.
static func seed_for_cell(cell: Vector2i) -> float:
	return float(hash(cell) % 8192) * 0.125


## Intensity in [0, 1] from FireBlobTuning.intensity(). Drives both the shader
## uniforms and the quad size — the quad IS the shader's spatial bound, so the
## two must always move together (see FireBlobTuning contract 1).
func set_intensity(i: float) -> void:
	_apply(clampf(i, 0.0, 1.0), false)


## Caps how hot blobs can get: 1.0 = the full white->char ramp, ~0.2 = smoke
## only. This is the whole burn-down + smoulder tail — there is no second code
## path. See the RAMP section of fire_blobs.gdshader for why it's a
## multiplicative ceiling rather than a subtractive bias.
func set_heat_ceiling(h: float) -> void:
	var v: float = clampf(h, HEAT_CEILING_MIN, 1.0)
	if is_equal_approx(v, _heat_ceiling):
		return
	_heat_ceiling = v
	if _mat != null:
		_mat.set_shader_parameter(&"heat_ceiling", v)


# _intensity is recorded only AFTER the push actually happens. Recording it first
# and then bailing would mark the value as applied when it wasn't, and every later
# call would be throttled against a state the shader never received — which is the
# shape of the bug that made every column render at intensity 0.
func _apply(i: float, force: bool) -> void:
	if not force and absf(i - _intensity) < INTENSITY_EPSILON:
		return
	var uniforms: Dictionary = FireBlobTuning.uniforms_for(i)
	for name: StringName in uniforms:
		_mat.set_shader_parameter(name, uniforms[name])
	scale = FireBlobTuning.quad_size(i)
	_intensity = i


static func _shared_quad_texture() -> ImageTexture:
	if _quad_tex != null:
		return _quad_tex
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	_quad_tex = ImageTexture.create_from_image(img)
	return _quad_tex
