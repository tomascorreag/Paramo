class_name FireBlobColumn
extends Sprite2D

# The renderable for the procedural blob fire: one quad per burning cell,
# running assets/shaders/fire_blobs.gdshader. Owned by BurningCellVFX, which
# places it at the cell centre.
#
# This node is nearly dumb. Its ONLY per-frame work is advancing blob_phase, the
# blob-age clock (see _advance). It does NOT push a camera_offset like
# scripts/vfx/rain.gd — the quad is world-parented, so panning is free — and every
# OTHER uniform changes only when the cell's intensity actually changes.
#
# Why the age clock is a CPU accumulator and not the shader's TIME: age used to be
# fract(TIME / lifetime), but lifetime scales with intensity, which changes every
# burn tick and whenever a neighbour ignites. That made each change teleport all
# blobs by an amount proportional to absolute TIME (see the blob_phase uniform in
# fire_blobs.gdshader) — fine at the test scene's fixed intensity, a glitch in
# game. blob_phase integrates dt/lifetime instead, so it stays continuous across
# lifetime changes. In game _process advances it; in the editor preview (where
# this non-@tool _process does not run) FireBlobPreview calls advance_phase.
#
# One behaviour change falls out of this: the fire now freezes when the SceneTree
# pauses (its _process stops), instead of animating on regardless as a TIME-driven
# shader would. That matches the rest of the paused sim; set the node's
# process_mode to ALWAYS if a live fire behind the pause menu is ever wanted.
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
# instead of by moving the node. _apply sets both per intensity:
#
#   texture   1x1 white, shared
#   centered  false            -> rect = Rect2(offset, Vector2.ONE)
#   scale     (w, h+b)         -> total quad: width w, height h ABOVE the base
#                                 (quad_size) plus b BELOW it (quad_bottom)
#   offset    (-0.5,           -> top edge lands at -h, bottom edge at +b in
#              -1 + b/(h+b))      parent space
#
# i.e. a column rising h above the cell centre, plus a b-px skirt below it so
# base-born blobs (centred on the base) aren't sliced flat by the quad edge.
# `offset` and `scale` do not touch the node's transform origin, so
# MODEL_MATRIX[3] stays put on the cell centre.

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

## Which tuning resource drives this column's intensity->uniforms mapping.
## Defaults to the one shared resource the whole game uses; the editor preview
## points it at the same instance so inspector edits are live. Leave it alone in
## game code — BurningCellVFX never sets it.
var tuning: FireBlobTuningData = FireBlobTuning.DATA

var _mat: ShaderMaterial
var _intensity: float = -1.0
var _heat_ceiling: float = 1.0
# The blob-age clock, in cycles. Advances at 1/lifetime per second (see _advance)
# and is pushed to blob_phase every frame. Continuous across intensity/lifetime
# changes — that is the entire reason it is a CPU accumulator and not TIME.
var _phase: float = 0.0
# Current lifetime, captured from the intensity->uniforms mapping so _advance
# knows the phase rate without re-deriving it. Seeded by the _init _apply.
var _lifetime: float = 1.0


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
	# Desync the phase clock per cell so cells ignited on the same frame don't march
	# their blobs in lockstep. Keep it in [0, 1); the golden-ratio multiplier spreads
	# adjacent seed values far apart. (cell_seed already decorrelates the per-blob
	# hashes; this decorrelates the shared age progression on top.)
	var seeded: float = v * 0.6180339887
	_phase = seeded - floor(seeded)
	# Push it now so the seed reaches the shader before the first _advance — and so
	# blob_phase is never an unset (null) uniform on a freshly built column.
	if _mat != null:
		_mat.set_shader_parameter(&"blob_phase", _phase)


## Convenience: a well-spread seed for a grid coord. Adjacent cells must land far
## apart or a spreading front reads as a repeating pattern, so this hashes rather
## than using the coord directly.
static func seed_for_cell(cell: Vector2i) -> float:
	return float(hash(cell) % 8192) * 0.125


## A distinct seed per (cell, slot). The shader's fire is a pure function of
## cell_seed, so two scattered flames on one cell sharing a seed render pixel-
## identical. Mixing the slot into the hash decorrelates them (and, via
## set_cell_seed's phase desync, breaks their lockstep too). Slot 0 must NOT equal
## seed_for_cell(cell) — it doesn't, because the hashed key differs.
static func seed_for_cell_slot(cell: Vector2i, slot: int) -> float:
	return float(hash(Vector3i(cell.x, cell.y, slot)) % 8192) * 0.125


## Intensity in [0, 1] (from FireDynamics, via BurningCellVFX). Drives both the
## shader uniforms and the quad size — the quad IS the shader's spatial bound, so
## the two must always move together (see FireBlobTuning contract 1).
func set_intensity(i: float) -> void:
	_apply(clampf(i, 0.0, 1.0), false)


# --- Blob-age phase clock ----------------------------------------------------
# blob_phase advances at 1/lifetime cycles per second and is pushed every frame.
# Continuous across lifetime changes — the whole point (see the header). In game
# this runs via _process; in the editor the preview drives it through
# advance_phase, because a non-@tool _process does not run in the editor.

func _process(delta: float) -> void:
	_advance(delta)


## Editor entry point for the phase clock. FireBlobPreview calls this each frame
## because this node's _process is inert in the editor (not @tool). Do NOT call it
## in game — _process already does, and driving both would double the rise speed.
func advance_phase(delta: float) -> void:
	_advance(delta)


func _advance(delta: float) -> void:
	if _mat == null:
		return
	_phase += delta / maxf(_lifetime, 0.0001)
	_mat.set_shader_parameter(&"blob_phase", _phase)


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
	var data: FireBlobTuningData = tuning if tuning != null else FireBlobTuning.DATA
	var uniforms: Dictionary = FireBlobTuning.uniforms_for(i, data)
	for name: StringName in uniforms:
		_mat.set_shader_parameter(name, uniforms[name])
	# Cache the phase rate. lifetime is one of the pushed uniforms, so read it from
	# the same dict rather than recomputing — keeps _advance in sync with the value
	# the shader actually got.
	_lifetime = float(uniforms[&"lifetime"])
	# Quad geometry. quad_size is the extent ABOVE the base; quad_bottom drops the
	# bottom edge below the base by a base-born blob's downward reach, so those
	# blobs (centred on the base) aren't sliced flat (see GEOMETRY). offset.y is
	# derived from the total scale so the TOP edge stays at -above.y (unchanged)
	# while the bottom reaches +bottom past the base.
	var above: Vector2 = FireBlobTuning.quad_size(i, data)
	var bottom: float = FireBlobTuning.quad_bottom(i, data)
	scale = Vector2(above.x, above.y + bottom)
	offset = Vector2(-0.5, -1.0 + bottom / scale.y)
	_intensity = i


# --- Editor preview support -------------------------------------------------
# Runtime never calls anything below. It exists because FireBlobPreview holds a
# .duplicate() of fire_blobs.tres per column (each needs its own intensity
# uniforms) and .duplicate() SNAPSHOTS params — so an inspector edit to the
# .tres never reaches the live columns. FireBlobPreview._process calls this every
# frame in the editor to re-sync, which is what makes the .tres a live tuning
# surface. See scripts/debug/fire_blob_preview.gd.

## Re-push everything from the current live sources: the code-driven uniforms +
## quad (forced, so edits to FireBlobTuning constants show), heat_ceiling, and
## the .tres-owned "look" params copied off the shared BLOB_MATERIAL (which
## tracks inspector edits — load() returns the same instance the inspector
## mutates). `cell_seed` is left alone; the preview sets it once per column.
func editor_refresh(ceiling: float) -> void:
	if _mat == null:
		return
	_apply(_intensity, true)
	_mat.set_shader_parameter(&"heat_ceiling", clampf(ceiling, HEAT_CEILING_MIN, 1.0))

	# Look params = every shader uniform that FireBlobTuning does NOT drive and
	# that the preview/BurningCellVFX does not own per-instance. Derived from the
	# uniform list + uniforms_for keys so there is no third hardcoded list to
	# drift (the same DRY split the .tres-liveness test relies on).
	var driven: Dictionary = FireBlobTuning.uniforms_for(0.0)
	for u: Dictionary in BLOB_MATERIAL.shader.get_shader_uniform_list():
		var n: StringName = StringName(u["name"])
		if driven.has(n) or n == &"cell_seed" or n == &"heat_ceiling" or n == &"blob_phase":
			continue
		var v: Variant = BLOB_MATERIAL.get_shader_parameter(n)
		if v != null:  # unset in the .tres -> keep the shader default, don't clear
			_mat.set_shader_parameter(n, v)


static func _shared_quad_texture() -> ImageTexture:
	if _quad_tex != null:
		return _quad_tex
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	_quad_tex = ImageTexture.create_from_image(img)
	return _quad_tex
