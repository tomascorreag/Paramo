class_name Frailejon
extends Node2D

# Frailejones are Node2D-rendered occupants of TileGrid. They expose the
# WorldOccupant duck-typed interface (occupant_kind/blocks_movement/walk_penalty)
# but don't extend WorldOccupant directly — keeping the existing inheritance
# chain (Node2D) avoids touching the scene file's root type. The three methods
# live at the bottom of this script.

# Player sprite dimensions (baseline for shadow proportions).
# Player: cap_width=6, max_height=4, ~16px wide, ~25px tall.
const REF_WIDTH: float = 16.0
const REF_HEIGHT: float = 25.0
const REF_CAP_WIDTH: float = 6.0
const REF_MAX_HEIGHT: float = 4.0

## Source-of-truth metadata. The scene wires this to
## res://resources/objects/frailejon.tres. `data.variants` defines the growth
## sequence (0 = newly planted, last = mature); `data.growth_chance` tunes
## the per-hour advance probability.
@export var data: PlantObjectData

## Extra pathfinding cost charged to agents stepping onto this cell. Values
## below 1.0 nudge (paths prefer a clear tie-equivalent); higher values force
## detours. Frailejones are meant to be stepped-over, not walls.
@export var pathfinding_penalty: float = 0.4

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _shadow: Sprite2D = $Shadow

var cell: Vector2i
var growth_stage: int = 0
var _shadow_scale: float = 1.0

var _time_manager: Node
var _last_hour: int = -1


func _ready() -> void:
	# Apply stage-0 texture before measuring shadow params (the shadow shader
	# needs the actual sprite texture to extrude its silhouette).
	_apply_variant_texture(growth_stage)

	_sprite.flip_h = (data != null and data.randomize_flip_h and randf() < 0.5)
	_sprite.position = Vector2(randi_range(-4, 4), randi_range(-4, 0))

	_update_shadow_params()
	_push_shadow_cell_state()

	# Lift the visible sprite by altitude so the plant looks like it sits on
	# the cube top, while keeping the Node2D's position (the y-sort key) in
	# the altitude-0 frame — same technique as Player._apply_visual_lift.
	# For the shadow, the lift goes into the shader's `visual_y_offset`
	# uniform (not Sprite2D.offset) because the teardrop shader rebuilds
	# VERTEX from `sprite_offset` — touching the raw Sprite2D offset would
	# push the quad outside the shader's normalized space and the shadow
	# would be discarded (vanish).
	# Planted by TileInteractionController with cell set before add_child, so
	# the Pathfinder lookup here is safe.
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

	# Reparent shadow for independent y-sorting (same pattern as Player).
	remove_child(_shadow)
	get_parent().add_child.call_deferred(_shadow)
	_shadow.add_to_group(&"shadow")
	call_deferred(&"_position_shadow")

	_time_manager = get_node_or_null("/root/TimeManager")
	if _time_manager:
		_last_hour = int(_time_manager.time_of_day * 24.0) % 24

	# Register as occupant on TileGrid. Pathfinder pulls walk_penalty() from
	# this node during step-cost calc, so the controller doesn't need to
	# write into _cell_penalties separately. Subscribe to graph_changed so
	# any future Pathfinder.rebuild() (e.g., a bridge built after planting)
	# re-registers us on the fresh grid.
	if pf != null:
		var grid := pf.grid()
		if grid != null:
			grid.set_occupant(cell, self)
		if not pf.graph_changed.is_connected(_on_graph_changed):
			pf.graph_changed.connect(_on_graph_changed)


func _exit_tree() -> void:
	if is_instance_valid(_shadow):
		_shadow.queue_free()
	# Clear occupant claim. The Pathfinder.graph_changed signal auto-disconnects
	# when we free, so no manual disconnect is needed.
	var pf := get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	if pf != null:
		var grid := pf.grid()
		if grid != null:
			grid.clear_occupant(cell, self)


func _on_graph_changed() -> void:
	if not is_inside_tree():
		return
	var pf := get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	if pf == null:
		return
	var grid := pf.grid()
	if grid != null:
		grid.set_occupant(cell, self)


# --- Occupant interface (TileGrid / Pathfinder duck-typed) -----------------

func occupant_kind() -> StringName:
	return &"frailejon"


# Frailejones can be stepped over by player and threats; they're stepped-on
# obstacles (penalty), not walls.
func blocks_movement() -> bool:
	return false


func walk_penalty() -> float:
	return pathfinding_penalty


func _process(_delta: float) -> void:
	if data == null or _time_manager == null:
		return
	var max_stage: int = data.variants.size() - 1
	if growth_stage >= max_stage:
		return
	var hour: int = int(_time_manager.time_of_day * 24.0) % 24
	if hour != _last_hour:
		_last_hour = hour
		if randf() <= data.growth_chance:
			set_growth_stage(growth_stage + 1)


func set_growth_stage(stage: int) -> void:
	var max_stage: int = (data.variants.size() - 1) if data != null else 0
	growth_stage = clampi(stage, 0, max_stage)
	_apply_variant_texture(growth_stage)
	if is_instance_valid(_shadow):
		_update_shadow_params()


func _apply_variant_texture(stage: int) -> void:
	if data == null or data.variants.is_empty():
		return
	var idx: int = clampi(stage, 0, data.variants.size() - 1)
	var tex: Texture2D = data.variants[idx]
	if _sprite:
		_sprite.texture = tex
	if is_instance_valid(_shadow):
		_shadow.texture = tex


func _update_shadow_params() -> void:
	if not is_instance_valid(_shadow) or _sprite == null or _sprite.texture == null:
		return
	var dims: Vector2 = _measure_frame_dimensions()
	var w_ratio: float = dims.x / REF_WIDTH if REF_WIDTH > 0.0 else 1.0
	var h_ratio: float = dims.y / REF_HEIGHT if REF_HEIGHT > 0.0 else 1.0

	var mat: ShaderMaterial = _shadow.material as ShaderMaterial
	if mat:
		mat.set_shader_parameter(&"cap_width", REF_CAP_WIDTH * w_ratio)
		mat.set_shader_parameter(&"max_height", REF_MAX_HEIGHT * w_ratio)

	_shadow_scale = h_ratio
	_shadow.set_meta(&"shadow_scale", _shadow_scale)


func _push_shadow_cell_state() -> void:
	# Stationary entity: sample once at spawn. Frailejones don't move, and
	# growth-stage changes don't relocate them, so a single set is enough.
	# No lerp needed — snap the cutoff_x to its computed value.
	if not is_instance_valid(_shadow):
		return
	var mat: ShaderMaterial = _shadow.material as ShaderMaterial
	if mat == null:
		return
	var pathfinder := get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	var r: float = pathfinder.roughness_at(cell) if pathfinder != null else 0.0
	mat.set_shader_parameter(&"roughness", r)
	var slen: Variant = mat.get_shader_parameter(&"shadow_length")
	var dir_sign: int = 1
	if (typeof(slen) == TYPE_FLOAT or typeof(slen) == TYPE_INT) and float(slen) < 0.0:
		dir_sign = -1
	var deltas: Vector3 = (
		pathfinder.shadow_altitude_deltas(cell, dir_sign) if pathfinder != null
		else Vector3.ZERO
	)
	var cutoff: float = 1000000.0
	if absf(deltas.x) > 0.25:
		cutoff = 16.0
	elif absf(deltas.y) > 0.25:
		cutoff = 48.0
	elif absf(deltas.z) > 0.25:
		cutoff = 80.0
	mat.set_shader_parameter(&"cutoff_x", cutoff)


func _measure_frame_dimensions() -> Vector2:
	# Returns the visible (non-transparent) bbox of the current variant in
	# pixels. Used to scale the shadow shader's cap_width / max_height.
	# Works for AtlasTexture (sample inside its region) and plain Texture2D
	# (sample the whole image).
	var tex: Texture2D = _sprite.texture if _sprite != null else null
	if tex == null:
		return Vector2(REF_WIDTH, REF_HEIGHT)

	var img: Image
	var ox: int = 0
	var oy: int = 0
	var fw: int = 0
	var fh: int = 0
	if tex is AtlasTexture:
		var atlas: AtlasTexture = tex
		if atlas.atlas == null:
			return Vector2(REF_WIDTH, REF_HEIGHT)
		img = atlas.atlas.get_image()
		ox = int(atlas.region.position.x)
		oy = int(atlas.region.position.y)
		fw = int(atlas.region.size.x)
		fh = int(atlas.region.size.y)
	else:
		img = tex.get_image()
		fw = int(tex.get_size().x)
		fh = int(tex.get_size().y)
	if img == null or fw <= 0 or fh <= 0:
		return Vector2(REF_WIDTH, REF_HEIGHT)

	var top: int = fh
	var bottom: int = 0
	var left: int = fw
	var right: int = 0
	for y in range(fh):
		for x in range(fw):
			if img.get_pixel(ox + x, oy + y).a > 0.01:
				top = mini(top, y)
				bottom = maxi(bottom, y)
				left = mini(left, x)
				right = maxi(right, x)
	if top > bottom:
		return Vector2(1.0, 1.0)
	return Vector2(float(right - left + 1), float(bottom - top + 1))


func _position_shadow() -> void:
	if is_instance_valid(_shadow):
		_shadow.global_position = Vector2(
			roundf(global_position.x + _sprite.position.x),
			roundf(global_position.y + _sprite.position.y - 1.0))
