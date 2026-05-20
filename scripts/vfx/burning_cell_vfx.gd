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

var cell: Vector2i

var _layer: TileMapLayer
var _atlas_src: TileSetAtlasSource
var _atlas_coords: Vector2i
var _overlay_mat: ShaderMaterial
var _burn_amount: float = 0.0


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


func set_burn_amount(t: float) -> void:
	_burn_amount = clampf(t, 0.0, 1.0)
	if _overlay_mat != null:
		_overlay_mat.set_shader_parameter(&"burn_amount", _burn_amount)


func get_burn_amount() -> float:
	return _burn_amount
