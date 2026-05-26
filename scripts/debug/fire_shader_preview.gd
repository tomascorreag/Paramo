@tool
class_name FireShaderPreview
extends Node2D

# Debug-only node: spawns a few flame AnimatedSprite2D children with the fire
# shader applied so fire.gdshader is visible in both the editor view and at
# runtime, without needing FireManager / Pathfinder / a real ignition.
#
# Children are not assigned to the scene's `owner`, so they never get saved
# back into the .tscn — they're regenerated each time the script runs.
#
# Inspector knobs trigger a rebuild on every change. Move the node itself
# (drag in the editor) to place the flame cluster anywhere on the map.

const FIRE_MATERIAL: ShaderMaterial = preload("res://resources/materials/fire.tres")
const FIRE_FRAMES: SpriteFrames = preload("res://assets/sprites/VFX/fire.tres")

@export_range(1, 32) var count: int = 3 : set = _set_count
@export var spread: Vector2 = Vector2(40.0, 20.0) : set = _set_spread
@export var flame_z_index: int = 1 : set = _set_zindex
# Forces a reseed without changing other params (toggle in inspector to nudge
# the layout). Editor builds default to a fixed seed so the layout is stable.
@export var rebuild_seed: int = 0 : set = _set_seed


func _set_count(v: int) -> void:
	count = v
	_rebuild()


func _set_spread(v: Vector2) -> void:
	spread = v
	_rebuild()


func _set_zindex(v: int) -> void:
	flame_z_index = v
	_rebuild()


func _set_seed(v: int) -> void:
	rebuild_seed = v
	_rebuild()


func _ready() -> void:
	if not Engine.is_editor_hint():
		queue_free()
		return
	_rebuild()


func _rebuild() -> void:
	if not is_inside_tree():
		return
	# Clear previous preview children — match by metadata so we never touch
	# user-added siblings of the same type.
	for c in get_children():
		if c.has_meta(&"_fire_preview"):
			c.queue_free()

	var rng := RandomNumberGenerator.new()
	rng.seed = hash([rebuild_seed, count, spread, flame_z_index])

	for i in count:
		var flame := AnimatedSprite2D.new()
		flame.set_meta(&"_fire_preview", true)
		flame.sprite_frames = FIRE_FRAMES
		flame.animation = &"default"
		flame.frame = rng.randi() % 7
		flame.flip_h = rng.randf() < 0.5
		flame.z_index = flame_z_index
		flame.position = Vector2(
			rng.randf_range(-spread.x, spread.x),
			rng.randf_range(-spread.y, spread.y))

		# Preview flames share the original FIRE_MATERIAL reference (not a
		# duplicate) so editing resources/materials/fire.tres in the inspector
		# updates every preview flame live. Trade-off: all preview flames share
		# the same seed_offset, so they animate in lockstep — fine for shader
		# iteration. Runtime flames in BurningCellVFX still duplicate the
		# material for per-instance seed variation.
		flame.material = FIRE_MATERIAL

		add_child(flame)
		# Leave owner null so children stay runtime-only and don't get saved
		# back into the scene file.
		flame.play(&"default")
