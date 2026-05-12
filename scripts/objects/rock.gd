class_name Rock
extends Node2D

# ============================================================================
# Rock
# ============================================================================
#
# Boulder Node2D occupant. Procedurally placed by ObjectPainter (after a
# TerrainGenerator object pass), or manually via a future placement action.
# Blocks movement on its cell — TileGrid.is_walkable returns false for any
# cell with a Rock occupant.
#
# Rendering mirrors `scripts/tools/frailejon.gd`: Sprite2D + reparented
# Shadow Sprite2D using `shadow_oval.gdshader`. Per-instance shader params
# (visual_y_offset, roughness, cutoff_x) are sampled from the Pathfinder once
# at spawn — rocks don't move or grow, so a single sample is enough.
#
# No growth, no time-manager hookup — rocks are inert.
#
# ============================================================================


# Index into `data.variants`. The procgen pass picks deterministically by
# hashing (seed, x, y); manual placement defaults to 0.
@export var rock_variant: int = 0

## Source-of-truth metadata for this kind. The scene wires this to
## res://resources/objects/rock.tres so the inspector shows the data slot
## and the painter doesn't need to inject it.
@export var data: WorldObjectData

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _shadow: Sprite2D = $Shadow

# Cell on the TileGrid this rock occupies. Set by ObjectPainter (or future
# placement action) BEFORE add_child so _ready can register on the grid and
# read pathfinder altitude data.
var cell: Vector2i


func _ready() -> void:
	# Variant index is clamped against the actual array length so a stale
	# `rock_variant` (e.g. authored when there were 4 variants but now only
	# 3 exist) doesn't crash the spawn.
	if data != null and data.variants.size() > 0:
		var idx: int = clampi(rock_variant, 0, data.variants.size() - 1)
		var tex: Texture2D = data.variants[idx]
		_sprite.texture = tex
		if is_instance_valid(_shadow):
			_shadow.texture = tex
	_sprite.flip_h = (data != null and data.randomize_flip_h and randf() < 0.5)
	# Slight per-instance jitter so cluster placements don't render in a rigid
	# grid pattern. Same approach as frailejon — small enough to stay aligned.
	_sprite.position = Vector2(randi_range(-3, 3), randi_range(-2, 0))

	# Visual altitude lift (same pattern as Player / Frailejon). The Node2D's
	# y-sort key stays in the altitude-0 frame; the visible sprite lifts via
	# Sprite2D.offset, and the shadow lifts via the shader's visual_y_offset
	# uniform (touching the raw Sprite2D offset would push the quad outside
	# the shader's normalized space and the shadow would vanish).
	var pf := get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	if pf != null:
		var alt: float = pf.altitude_center(cell)
		var lift: float = -alt * Pathfinder.HALF_STEP_PX
		_sprite.offset.y += lift
		var shadow_mat: ShaderMaterial = _shadow.material as ShaderMaterial
		if shadow_mat != null:
			var base_voff: float = 0.0
			var v: Variant = shadow_mat.get_shader_parameter(&"visual_y_offset")
			if v != null:
				base_voff = float(v)
			shadow_mat.set_shader_parameter(&"visual_y_offset", base_voff + lift)

	# Reparent shadow for independent y-sorting (same pattern as Player /
	# Frailejon).
	if is_instance_valid(_shadow):
		remove_child(_shadow)
		get_parent().add_child.call_deferred(_shadow)
		_shadow.add_to_group(&"shadow")
		call_deferred(&"_position_shadow")
		_push_shadow_cell_state(pf)

	# Register as cell occupant. blocks_movement() returns true so TileGrid
	# treats this cell as unwalkable and Pathfinder routes around. Subscribe
	# to graph_changed so a future rebuild re-registers us.
	if pf != null:
		var grid := pf.grid()
		if grid != null:
			grid.set_occupant(cell, self)
		if not pf.graph_changed.is_connected(_on_graph_changed):
			pf.graph_changed.connect(_on_graph_changed)


func _exit_tree() -> void:
	if is_instance_valid(_shadow):
		_shadow.queue_free()
	# Clear occupant claim — guard get_tree() for late-frees during scene
	# teardown when we may already be detached.
	var tree := get_tree()
	if tree == null:
		return
	var pf := tree.get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	if pf != null:
		var grid := pf.grid()
		if grid != null:
			grid.clear_occupant(cell, self)


func _on_graph_changed() -> void:
	if not is_inside_tree():
		return
	# Skip re-registration when this rock is already queued for deletion.
	# remove_rock() calls Pathfinder.rebuild() which emits graph_changed
	# synchronously while the queue_free'd Rock is still in the tree; without
	# this guard the dying rock would re-claim its cell on the fresh grid and
	# leave it unwalkable until the deferred free runs.
	if is_queued_for_deletion():
		return
	var pf := get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	if pf == null:
		return
	var grid := pf.grid()
	if grid != null:
		grid.set_occupant(cell, self)


# Sample roughness + altitude deltas once at spawn — rocks don't move, so a
# single set is sufficient (no lerp). Mirrors Frailejon._push_shadow_cell_state.
func _push_shadow_cell_state(pf: Pathfinder) -> void:
	if not is_instance_valid(_shadow):
		return
	var mat: ShaderMaterial = _shadow.material as ShaderMaterial
	if mat == null:
		return
	var r: float = pf.roughness_at(cell) if pf != null else 0.0
	mat.set_shader_parameter(&"roughness", r)
	var slen: Variant = mat.get_shader_parameter(&"shadow_length")
	var dir_sign: int = 1
	if (typeof(slen) == TYPE_FLOAT or typeof(slen) == TYPE_INT) and float(slen) < 0.0:
		dir_sign = -1
	var deltas: Vector3 = (
		pf.shadow_altitude_deltas(cell, dir_sign) if pf != null else Vector3.ZERO
	)
	var cutoff: float = 1000000.0
	if absf(deltas.x) > 0.25:
		cutoff = 16.0
	elif absf(deltas.y) > 0.25:
		cutoff = 48.0
	elif absf(deltas.z) > 0.25:
		cutoff = 80.0
	mat.set_shader_parameter(&"cutoff_x", cutoff)


func _position_shadow() -> void:
	if is_instance_valid(_shadow):
		_shadow.global_position = Vector2(
			roundf(global_position.x + _sprite.position.x),
			roundf(global_position.y + _sprite.position.y - 1.0)
		)


# --- Occupant interface (TileGrid / Pathfinder duck-typed) -----------------

func occupant_kind() -> StringName:
	return &"rock"


# Rocks block movement: pathfinder routes around them.
func blocks_movement() -> bool:
	return true


# Unused while blocks_movement returns true — Pathfinder skips the cell
# entirely. Kept for symmetry with the rest of the occupant interface.
func walk_penalty() -> float:
	return 0.0
