class_name BurningCellVFX
extends Node2D

# Per-tile fire VFX. One instance per burning cell, owned by FireManager.
# Spawns 1–3 flame AnimatedSprite2D children jittered inside the diamond, plus
# a grass overlay Sprite2D textured with a snapshot of the underlying grass
# tile and driven by burn_dissolve.gdshader. As burn_amount climbs 0→1 the
# overlay dissolves pixel-by-pixel, revealing the dirt tile FireManager painted
# on the underlying TileMapLayer at ignition time.
#
# Lifecycle:
#   1. FireManager.new() instance, sets `cell`, calls setup(layer, atlas_src,
#      vfx_parent), then adds to tree.
#   2. _ready spawns the overlay + flames and positions self on the layer.
#   3. FireManager calls set_burn_amount(t) each tick.
#   4. FireManager calls queue_free() on burn complete; overlay + flames die
#      with the node.

const BURN_SHADER: Shader = preload("res://assets/shaders/burn_dissolve.gdshader")
const FIRE_MATERIAL: ShaderMaterial = preload("res://resources/materials/fire.tres")
const FIRE_FRAMES: SpriteFrames = preload("res://assets/sprites/VFX/fire.tres")

const FLAME_MIN: int = 1
const FLAME_MAX: int = 3
const FLAME_JITTER_X: int = 7
const FLAME_JITTER_Y_LOW: int = -4
const FLAME_JITTER_Y_HIGH: int = 2

# --- Fire light --------------------------------------------------------------
# Each burning cell casts a warm flickering PointLight2D so fire reads as a real
# light source against the night CanvasModulate, like the player lantern. Kept
# smaller and flickering (vs the lantern's larger steady glow) so it reads as
# living flame. See scripts/systems/player_light_controller.gd for the lantern.

# Palette index 12 #FDD179 (col_hi from fire.gdshader). Hotter than col_mid so
# it survives multiplication into the dark-blue night ambient.
const LIGHT_COLOR: Color = Color(0.992, 0.820, 0.475)
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
# Count of currently-lit cells. Incremented on light spawn, decremented on
# PREDELETE so completion / extinguish / graph-change wipes all release the slot.
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

	_spawn_overlay()
	_spawn_flames()
	_spawn_light()


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
	light.energy = _burn_envelope(0.0) * LIGHT_MAX_ENERGY
	light.blend_mode = Light2D.BLEND_MODE_ADD
	add_child(light)

	_light = light
	# Per-instance phase so lit cells flicker out of sync rather than as one mass.
	_flicker_phase = randf() * TAU
	_active_lights += 1


func _process(delta: float) -> void:
	if _light == null:
		return
	_flicker_phase += delta
	# Two summed sines read as living flame; cheap (2 sin/instance/frame). f stays
	# in ~0.7–1.0 so flicker only modulates down from the envelope peak.
	var f: float = 0.85 \
			+ 0.10 * sin(_flicker_phase * 8.0) \
			+ 0.05 * sin(_flicker_phase * 23.0 + 1.3)
	var e: float = _burn_envelope(_burn_amount) * LIGHT_MAX_ENERGY * f * _day_night_factor()
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


# Maps burn_amount [0..1] to a base energy multiplier [0..1]: fast attack at
# ignition, a sustained plateau, then a fade toward embers (the node frees at
# burn_amount >= 1, so the tail never fully reaches 0 on screen).
func _burn_envelope(t: float) -> float:
	if t < 0.15:
		return t / 0.15
	if t < 0.75:
		return 1.0
	return lerpf(1.0, 0.25, (t - 0.75) / 0.25)


func _notification(what: int) -> void:
	# Release the budget slot when this cell dies (completion, rain-extinguish, or
	# the en-masse wipe on graph_changed — all route through queue_free).
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


func set_burn_amount(t: float) -> void:
	_burn_amount = clampf(t, 0.0, 1.0)
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter(&"burn_amount", _burn_amount)


func get_burn_amount() -> float:
	return _burn_amount
