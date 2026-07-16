class_name BurningCellVFX
extends Node2D

# Per-tile fire VFX. One instance per burning cell, owned by FireManager.
# Spawns a flame visual plus a grass overlay Sprite2D textured with a snapshot
# of the underlying grass tile and driven by burn_dissolve.gdshader. As
# burn_amount climbs 0→1 the overlay dissolves pixel-by-pixel, revealing the
# dirt tile FireManager painted on the underlying TileMapLayer at ignition time.
#
# TWO FLAME VISUALS, selected by Debug.fire_blob_flames:
#   blob   (default) — one FireBlobColumn quad running fire_blobs.gdshader.
#                      Fully procedural; fire and smoke are one system.
#   sprite (legacy)  — 1–3 AnimatedSprite2D children jittered inside the
#                      diamond, running fire.gdshader.
# The grass overlay and the PointLight2D are SHARED by both paths and untouched
# by the toggle, so flipping it isolates exactly one variable. The toggle
# re-spawns live (see _on_flame_style_changed) rather than waiting for the next
# ignition — a fire only lasts ~10s, so "applies to new fires" would make the
# A/B unusable.
#
# Lifecycle:
#   1. FireManager.new() instance, sets `cell`, calls setup(layer, atlas_src,
#      vfx_parent), then adds to tree.
#   2. _ready spawns the overlay + flames and positions self on the layer.
#   3. FireManager calls set_burn_state(amount, burning_neighbours) each tick.
#   4. On burn complete FireManager calls begin_smoulder(); the node outlives
#      the burn by SMOULDER_SECONDS emitting only char blobs, then frees itself.
#      Rain-extinguish instead queue_free()s immediately — nothing smoulders
#      after being put out.

const BURN_SHADER: Shader = preload("res://assets/shaders/burn_dissolve.gdshader")
const FIRE_MATERIAL: ShaderMaterial = preload("res://resources/materials/fire.tres")
const FIRE_FRAMES: SpriteFrames = preload("res://assets/sprites/VFX/fire.tres")

# Every instance joins this so FireManager can wipe fires on a map reload by
# group rather than by its _burning dictionary. Load-bearing for the smoulder
# tail: a smouldering node has ALREADY been erased from _burning, so a
# dictionary-based wipe would leave it dangling over the new grid.
const FIRE_VFX_GROUP: StringName = &"fire_vfx"

const FLAME_MIN: int = 1
const FLAME_MAX: int = 3
const FLAME_JITTER_X: int = 7
const FLAME_JITTER_Y_LOW: int = -4
const FLAME_JITTER_Y_HIGH: int = 2

# --- Burn-down + smoulder tail -----------------------------------------------
# The fire loses its hot stages as the cell exhausts itself: heat_ceiling ramps
# from 1.0 down to BURNOUT_HEAT_CEILING between BURNOUT_STARTS_AT and burn
# completion, so it visibly runs down through the palette (white drops out
# first, then yellow) instead of burning white-hot until the instant it dies.
const BURNOUT_STARTS_AT: float = 0.7
const BURNOUT_HEAT_CEILING: float = 0.55

# After completion the cell smokes for this long, then frees itself. Only the
# blob path smoulders; the sprite path has no equivalent and just dies (see
# begin_smoulder).
const SMOULDER_SECONDS: float = 4.0
# Smoke-only: blobs are born char and live their full life as char. Multiplicative
# — see the RAMP section of fire_blobs.gdshader for why a subtractive bias is wrong.
const SMOULDER_HEAT_CEILING: float = 0.2
# The plume is thinner than the fire that made it, and decays to nothing over
# the tail.
const SMOULDER_INTENSITY_SCALE: float = 0.6

# --- Fire light --------------------------------------------------------------
# Each burning cell casts a warm flickering PointLight2D so fire reads as a real
# light source against the night CanvasModulate, like the player lantern. Kept
# smaller and flickering (vs the lantern's larger steady glow) so it reads as
# living flame. See scripts/systems/player_light_controller.gd for the lantern.

# Palette index 12 #FDD179 (col_hi from fire.gdshader, col_yellow from
# fire_blobs.gdshader). Hotter than col_mid so it survives multiplication into
# the dark-blue night ambient.
const LIGHT_COLOR: Color = Palette.P12
# Peak energy when fully ablaze — below the lantern's 1.5; fire is a small source.
const LIGHT_MAX_ENERGY: float = 0.9
# 64px base radius * 2 = 128px (halved vertically by the iso squash). Deliberately
# smaller than the lantern's 256px — the single highest-leverage overdraw knob.
const LIGHT_TEXTURE_SCALE: float = 2.0
# Soft cap on simultaneously-lit cells. Fires beyond this still burn, just unlit —
# bounds worst-case additive overdraw on the WebGL2 build regardless of clustering.
const LIGHT_BUDGET: int = 40

# Day/night dimming: fire glow is pointless when the scene is already bright. The
# light's energy is scaled by a factor derived (inversely) from the day/night
# CanvasModulate ambient brightness — full strength at night, dimmed to
# LIGHT_DAY_FACTOR in daylight, with a smooth ramp through dawn/dusk.
const DAY_NIGHT_GROUP: StringName = &"day_night_controller"
# Energy fraction in full daylight (vs 1.0 at night).
const LIGHT_DAY_FACTOR: float = 0.08
# Ambient HSV-value thresholds for the dim ramp. At/below NIGHT_VALUE_HI the fire
# is full strength; at/above DAY_VALUE_LO it's dimmed to LIGHT_DAY_FACTOR. Tuned to
# default_profile's ambient gradient (night v≈0.2–0.39, dusk≈0.48, day v≈0.77–0.92).
const NIGHT_VALUE_HI: float = 0.45
const DAY_VALUE_LO: float = 0.8

# Shared radial falloff texture — baked once, reused by every fire light. Never
# mutated (texture_scale is per-node), so sharing is safe.
static var _falloff_tex: GradientTexture2D = null
# Count of currently-lit cells. Incremented on light spawn. Released either at
# begin_smoulder (burn completion — early, so a smouldering tail doesn't sit on
# a slot the live fire needs) or at PREDELETE (extinguish / graph-change wipe).
# The two can't double-count: begin_smoulder nulls _light, which is what
# _notification gates on.
static var _active_lights: int = 0
# Shared per-frame cache of the day/night dim factor: the up-to-40 lit cells all
# want the same value, so compute it once per frame, not once per cell.
static var _dn_controller: Node = null
static var _night_factor: float = 1.0
static var _night_factor_frame: int = -1

var cell: Vector2i

var _layer: TileMapLayer
var _atlas_src: TileSetAtlasSource
var _atlas_coords: Vector2i
var _overlay_mat: ShaderMaterial
var _burn_amount: float = 0.0
var _light: PointLight2D = null
var _flicker_phase: float = 0.0
var _neighbours: int = 0
var _intensity: float = 0.0
# The blob path's single quad (null on the sprite path); the sprite path's
# flames (empty on the blob path). Exactly one is populated at a time.
var _column: FireBlobColumn = null
var _flames: Array[AnimatedSprite2D] = []
var _smouldering: bool = false
var _smoulder_left: float = 0.0
var _smoulder_intensity: float = 0.0


# Called by FireManager before add_child. `layer` is the TileMapLayer the
# grass tile sat on (= the layer the dirt was just painted onto). `atlas_src`
# is the grass source (SOURCE_GRASS) from base_tileset. `atlas_coords` is the
# atlas coord that was painted at this cell — used to copy the exact grass
# variant into the overlay.
func setup(
	target_cell: Vector2i,
	target_layer: TileMapLayer,
	grass_src: TileSetAtlasSource,
	grass_atlas_coords: Vector2i,
) -> void:
	cell = target_cell
	_layer = target_layer
	_atlas_src = grass_src
	_atlas_coords = grass_atlas_coords


func _ready() -> void:
	if _layer == null or _atlas_src == null:
		push_warning("BurningCellVFX: setup() must be called before add_child")
		queue_free()
		return

	# We're parented directly under the TileMapLayer the burning tile sits on,
	# so the layer's own altitude lift (layer.position.y = -alt * HALF_STEP_PX)
	# and matching y_sort_origin place us in the same frame as the tile — flames
	# y-sort correctly against tiles and entities on every layer.
	position = _layer.map_to_local(cell)
	add_to_group(FIRE_VFX_GROUP)

	_spawn_overlay()
	_spawn_flames()
	_spawn_light()

	Debug.fire_blob_flames_changed.connect(_on_flame_style_changed)


# Live A/B: tear down whichever flame visual is up and spawn the other. The
# overlay and light are deliberately left alone — they are shared, and rebuilding
# the light would churn the LIGHT_BUDGET counter.
func _on_flame_style_changed(_use_blobs: bool) -> void:
	_despawn_flames()
	_spawn_flames()
	_push_flame_state()


func _despawn_flames() -> void:
	if _column != null and is_instance_valid(_column):
		_column.queue_free()
	_column = null
	for f: AnimatedSprite2D in _flames:
		if is_instance_valid(f):
			f.queue_free()
	_flames.clear()


func _spawn_overlay() -> void:
	var region: Rect2 = _atlas_src.get_tile_texture_region(_atlas_coords)

	var atlas_tex := AtlasTexture.new()
	atlas_tex.atlas = _atlas_src.texture
	atlas_tex.region = region

	var sprite := Sprite2D.new()
	sprite.name = "GrassOverlay"
	sprite.texture = atlas_tex
	sprite.centered = false

	# TileMapLayer draws the texture with its top-left at `cell_origin -
	# texture_origin` (texture_origin is the artist's anchor that pushes the
	# pixels around the cell). Replicate that placement.
	var tex_origin: Vector2i = Vector2i.ZERO
	var tile_data := _atlas_src.get_tile_data(_atlas_coords, 0)
	if tile_data != null:
		tex_origin = tile_data.texture_origin
	sprite.position = -Vector2(tex_origin) - region.size * 0.5 + Vector2(_layer.tile_set.tile_size) * 0.5
	# Above: TileMap centers the cell on the diamond. For an iso tileset the
	# tile_size is the cell footprint (e.g. 32x16); the texture is usually
	# taller than the cell and extends upward. Aligning the texture so its
	# bottom-center sits at the cell origin and then shifting by -texture_origin
	# matches Godot's TileMapLayer drawing rule.

	_overlay_mat = ShaderMaterial.new()
	_overlay_mat.shader = BURN_SHADER
	_overlay_mat.set_shader_parameter(&"burn_amount", 0.0)
	sprite.material = _overlay_mat

	add_child(sprite)


func _spawn_flames() -> void:
	if Debug.fire_blob_flames:
		_spawn_flames_blob()
	else:
		_spawn_flames_sprite()


func _spawn_flames_blob() -> void:
	var column := FireBlobColumn.new()
	column.name = "FireBlobColumn"
	# The shader's blob math is relative to MODEL_MATRIX[3], which must land on
	# the cell centre — this node is already there, so the column sits at zero
	# and grows via offset/scale. See fire_blob_column.gd.
	column.position = Vector2.ZERO
	# Without this every burning cell renders the identical fire — the shader's
	# blob hashes are a function of (slot, birth) and nothing else.
	column.set_cell_seed(FireBlobColumn.seed_for_cell(cell))
	add_child(column)
	_column = column


func _spawn_flames_sprite() -> void:
	var count: int = randi_range(FLAME_MIN, FLAME_MAX)
	for i in count:
		var flame := AnimatedSprite2D.new()
		flame.sprite_frames = FIRE_FRAMES
		flame.animation = &"default"
		flame.autoplay = "default"
		flame.frame = randi() % 7
		flame.position = Vector2(
			randi_range(-FLAME_JITTER_X, FLAME_JITTER_X),
			randi_range(FLAME_JITTER_Y_LOW, FLAME_JITTER_Y_HIGH),
		)
		# Flame sprites are 32x64 (tall) — keep them flipped randomly for variety.
		flame.flip_h = randf() < 0.5
		# Bias y_sort so flames draw above the grass overlay and frailejon on the
		# same cell; the burning tile should clearly be on fire.
		flame.z_index = 1
		# Per-flame fire material — duplicated so per-instance seed_offset
		# overrides don't bleed across flames sharing the resource. Tune
		# defaults via the .tres in the inspector.
		var fire_mat := FIRE_MATERIAL.duplicate() as ShaderMaterial
		fire_mat.set_shader_parameter(
			&"seed_offset",
			Vector2(randf_range(-1000.0, 1000.0), randf_range(-1000.0, 1000.0)))
		flame.material = fire_mat
		add_child(flame)
		_flames.append(flame)


func _spawn_light() -> void:
	# Respect the lit-cell budget — clustered wildfire could otherwise pile up
	# ~80 overlapping additive lights and tank fill rate on WebGL2.
	if _active_lights >= LIGHT_BUDGET:
		return

	var light := PointLight2D.new()
	light.name = "FireLight"
	# Cell center — the VFX node already sits at map_to_local(cell); only the
	# flames are jittered, the light stays put.
	light.position = Vector2.ZERO
	light.scale = Vector2(1.0, 0.5) # iso squash, same as the lantern
	light.texture = _shared_falloff()
	light.texture_scale = LIGHT_TEXTURE_SCALE
	light.color = LIGHT_COLOR
	light.shadow_enabled = false # never on web — per-light shadows × N tank WebGL2
	light.enabled = true
	# Seed energy for frame 0 (before _process runs) so ignition doesn't pop bright.
	light.energy = _intensity * LIGHT_MAX_ENERGY
	light.blend_mode = Light2D.BLEND_MODE_ADD
	add_child(light)

	_light = light
	# Per-instance phase so lit cells flicker out of sync rather than as one mass.
	_flicker_phase = randf() * TAU
	_active_lights += 1


func _process(delta: float) -> void:
	if _smouldering:
		_smoulder_left -= delta
		if _smoulder_left <= 0.0:
			queue_free()
			return
		# Thin the plume out over the tail so the cell stops smoking gradually
		# instead of the column vanishing on a frame boundary.
		if _column != null and is_instance_valid(_column):
			var t: float = 1.0 - clampf(_smoulder_left / SMOULDER_SECONDS, 0.0, 1.0)
			_column.set_intensity(lerpf(_smoulder_intensity, 0.0, t))

	if _light == null:
		return
	_flicker_phase += delta
	# Two summed sines read as living flame; cheap (2 sin/instance/frame). f stays
	# in ~0.7–1.0 so flicker only modulates down from the envelope peak.
	var f: float = 0.85 \
			+ 0.10 * sin(_flicker_phase * 8.0) \
			+ 0.05 * sin(_flicker_phase * 23.0 + 1.3)
	var e: float = _intensity * LIGHT_MAX_ENERGY * f * _day_night_factor()
	# Cull near-dark lights from the additive pile (attack ramp / decay tail, and
	# the daytime-dimmed state).
	_light.enabled = e > 0.01
	_light.energy = e


# Dim factor in [LIGHT_DAY_FACTOR, 1.0] derived inversely from the day/night
# ambient brightness: 1.0 at night, LIGHT_DAY_FACTOR in daylight. Cached per frame
# and shared across all lit cells (the value is identical for every fire).
func _day_night_factor() -> float:
	var frame: int = Engine.get_process_frames()
	if frame == _night_factor_frame:
		return _night_factor
	_night_factor_frame = frame

	if _dn_controller == null or not is_instance_valid(_dn_controller):
		_dn_controller = get_tree().get_first_node_in_group(DAY_NIGHT_GROUP)
	var v: float = 1.0
	if _dn_controller != null and _dn_controller.has_method(&"get_ambient_value"):
		v = _dn_controller.call(&"get_ambient_value")
	# smoothstep → 0 below NIGHT_VALUE_HI (full strength), 1 above DAY_VALUE_LO.
	var day_t: float = smoothstep(NIGHT_VALUE_HI, DAY_VALUE_LO, v)
	_night_factor = lerpf(1.0, LIGHT_DAY_FACTOR, day_t)
	return _night_factor


func _notification(what: int) -> void:
	# Release the budget slot when this cell dies (rain-extinguish or the
	# en-masse wipe on graph_changed). Burn-completion instead releases early via
	# begin_smoulder(), which nulls _light — so this cannot double-decrement.
	if what == NOTIFICATION_PREDELETE and _light != null:
		_active_lights -= 1


# Builds the radial falloff once and caches it on the class — every fire light
# shares this single texture. Steeper than the lantern's (player_light_controller
# ._bake_falloff) since this is a small point fire.
static func _shared_falloff() -> GradientTexture2D:
	if _falloff_tex != null:
		return _falloff_tex

	# Plateaued top (not 1.0 at d=0) so the radial center isn't a bright hot dot.
	# Outer tail unchanged → same extent; mid brightness preserved.
	var falloff := Curve.new()
	falloff.min_value = 0.0
	falloff.max_value = 1.0
	falloff.add_point(Vector2(0.0, 0.6))
	falloff.add_point(Vector2(0.3, 0.5))
	falloff.add_point(Vector2(0.7, 0.1))
	falloff.add_point(Vector2(1.0, 0.0))

	var steps: int = 32
	var grad := Gradient.new()
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for i: int in range(steps + 1):
		var d: float = float(i) / float(steps)
		offsets.append(d)
		colors.append(Color(1.0, 1.0, 1.0, falloff.sample(d)))
	grad.offsets = offsets
	grad.colors = colors

	var tex := GradientTexture2D.new()
	tex.width = 128
	tex.height = 128
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.gradient = grad

	_falloff_tex = tex
	return _falloff_tex


## Called by FireManager every tick. `burning_neighbours` is how many of the
## cell's 4-neighbours are also on fire (0-4) — it raises the intensity ceiling,
## which is what keeps an isolated ignition at kindling scale forever while a
## cell inside a spreading front grows to full wildfire. See FireBlobTuning.
func set_burn_state(t: float, burning_neighbours: int) -> void:
	_burn_amount = clampf(t, 0.0, 1.0)
	_neighbours = clampi(burning_neighbours, 0, 4)
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter(&"burn_amount", _burn_amount)
	if _smouldering:
		# The tail owns intensity from here; don't let a late tick resurrect it.
		return
	_intensity = FireBlobTuning.intensity(_burn_amount, _neighbours)
	_push_flame_state()


## Back-compat shim: treats the cell as isolated. Prefer set_burn_state.
func set_burn_amount(t: float) -> void:
	set_burn_state(t, 0)


func get_burn_amount() -> float:
	return _burn_amount


## Current blob intensity in [0, 1]. Drives the flame size AND the light energy,
## so both paths' glow tracks the kindling->wildfire ramp.
func get_intensity() -> float:
	return _intensity


# Pushes the current intensity to whichever flame visual is up. The sprite path
# has no intensity concept — its flames are fixed at spawn — so it only affects
# the light, which reads _intensity directly in _process.
func _push_flame_state() -> void:
	if _column == null or not is_instance_valid(_column):
		return
	_column.set_intensity(_intensity)
	# Burn-down: as the cell exhausts itself the fire loses its hot stages, so it
	# runs white->yellow->orange early and orange->red->char late, before the
	# smoulder tail takes over entirely.
	_column.set_heat_ceiling(lerpf(1.0, BURNOUT_HEAT_CEILING, _burnout_t()))


# 0 until BURNOUT_STARTS_AT, ramping to 1 at burn completion.
func _burnout_t() -> float:
	return clampf(
		(_burn_amount - BURNOUT_STARTS_AT) / maxf(1.0 - BURNOUT_STARTS_AT, 0.0001),
		0.0, 1.0)


## The cell finished burning. Instead of dying instantly, keep the column alive
## for SMOULDER_SECONDS emitting only char blobs over the charred tile.
##
## Called by FireManager._complete_burn INSTEAD OF queue_free(). Two things have
## to happen here rather than at free time:
##  - The light budget slot is released NOW. _active_lights only decrements on
##    PREDELETE, so a smouldering node would otherwise hold its slot for the
##    whole tail and starve LIGHT_BUDGET exactly when a big fire needs it.
##  - The node has already been erased from FireManager._burning, so nothing
##    else will ever call into it again; the tail has to be self-driving.
func begin_smoulder() -> void:
	if _smouldering:
		return
	_smouldering = true
	_smoulder_left = SMOULDER_SECONDS

	if _light != null:
		_active_lights -= 1
		_light.queue_free()
		_light = null

	# The sprite path has no smoulder equivalent — its flames can't be reduced to
	# smoke — so it keeps the old behaviour and just dies.
	if _column == null or not is_instance_valid(_column):
		queue_free()
		return

	_smoulder_intensity = _intensity * SMOULDER_INTENSITY_SCALE
	_column.set_intensity(_smoulder_intensity)
	_column.set_heat_ceiling(SMOULDER_HEAT_CEILING)
