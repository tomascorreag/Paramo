class_name Frailejon
extends Node2D

# THE plant scene. Every species in ObjectPainter's registry — the three
# Espeletia, the grasses, the shrubs — is this scene with a different
# PlantObjectData swapped into `data` (the rock pattern: rock / rock_snow /
# rock_moss share rock.tscn). Kind identity, growth rate, shadow, walk penalty
# and displaceability all come off `data`; the class keeps its historical name
# because tests, the FTUE, the sim bot and TileInteractionController key on it.
#
# Plants are Node2D-rendered occupants of TileGrid. They expose the
# WorldOccupant duck-typed interface (occupant_kind/blocks_movement/walk_penalty
# /is_displaceable) but don't extend WorldOccupant directly — keeping the
# existing inheritance chain (Node2D) avoids touching the scene file's root
# type. The methods live at the bottom of this script.

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

# Walk penalty charged when `data` is missing (tests build the node bare).
# Real values live on each species' .tres — a plant is stepped over, not a
# wall, so they sit well below 1.0.
const _DEFAULT_WALK_PENALTY: float = 0.4

# Visible-pixel bbox per stage texture, shared by every instance. Measuring
# scans the whole 32×32 region with get_pixel; at a few hundred procgen plants
# that is a few hundred thousand reads on load for at most 32 distinct
# answers (8 species × 4 stages), so the answer is cached by texture.
static var _dims_cache: Dictionary = {}

@onready var _sprite: Sprite2D = $Sprite2D
@onready var _shadow: Sprite2D = $Shadow

# Fired when burn_amount reaches 1.0 via set_burn_amount(). FireManager listens
# (or polls) to decide when to queue_free this frailejon.
signal burned_out

const _BURN_SHADER: Shader = preload("res://assets/shaders/burn_char.gdshader")

var cell: Vector2i
var growth_stage: int = 0
var _shadow_scale: float = 1.0
var _burn_mat: ShaderMaterial
# Accumulated footfall damage in RegrowthManager wear units; see trample().
var _trample_damage: float = 0.0

# Half-extents of the diamond the individuals of a multi-plant cell are
# scattered in, in pixels. The cell is a 32x16 iso diamond, so the spread has
# to be a diamond too — a square box at the same width puts tufts on the
# neighbouring cube's face at the corners. Kept well inside the cell: the
# sprites are 32px wide and read as belonging to the cell they stand on.
const _SPREAD_X: float = 9.0
const _SPREAD_Y: float = 4.5

# Extra individuals sharing this cell, back to front, in the same local frame
# as _sprite.position. Empty for every kind with individuals_per_cell (1, 1),
# which is the whole plantable list — see WorldObjectData.individuals_per_cell
# for why this is a draw count and not an occupancy count.
var _extra_offsets: PackedVector2Array = PackedVector2Array()
var _extra_flips: PackedByteArray = PackedByteArray()

var _time_manager: Node
var _last_hour: int = -1


func _ready() -> void:
	# Apply stage-0 texture before measuring shadow params (the shadow shader
	# needs the actual sprite texture to extrude its silhouette).
	_apply_variant_texture(growth_stage)

	_sprite.flip_h = (data != null and data.randomize_flip_h and randf() < 0.5)
	_roll_clump()
	_apply_wind_material()

	# Ground cover opts out of the shadow: it is a second CanvasItem with its
	# own shader per plant, and canvas-item count is what the web frame pays
	# for. Freed here, before any of the shadow wiring below, and every later
	# touch is guarded by is_instance_valid.
	if data != null and not data.casts_shadow:
		_shadow.queue_free()
		_shadow = null

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
		var shadow_mat: ShaderMaterial = (
			_shadow.material as ShaderMaterial if is_instance_valid(_shadow) else null
		)
		if shadow_mat != null:
			var base_voff: float = 0.0
			var v: Variant = shadow_mat.get_shader_parameter(&"visual_y_offset")
			if v != null:
				base_voff = float(v)
			shadow_mat.set_shader_parameter(&"visual_y_offset", base_voff + lift)

	# Reparent shadow for independent y-sorting (same pattern as Player).
	if is_instance_valid(_shadow):
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
	# Skip re-registration when already dying (same guard as Rock): a
	# remove/burnout queue_frees us, and a rebuild in that same frame emits
	# graph_changed synchronously — without this the dying plant re-claims
	# its cell on the fresh grid until the deferred free lands.
	if is_queued_for_deletion():
		return
	var pf := get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	if pf == null:
		return
	var grid := pf.grid()
	if grid != null:
		grid.set_occupant(cell, self)


# --- Occupant interface (TileGrid / Pathfinder duck-typed) -----------------

## The species id, from `data`. This is what TileGrid.occupants_of_kind and
## the burn/unlock/sim code match on, so it must equal `data.id` exactly —
## the bare fallback keeps a data-less instance (tests) behaving as the
## historical frailejón.
func occupant_kind() -> StringName:
	return data.id if data != null else &"frailejon"


# Plants can be stepped over by player and threats; they're stepped-on
# obstacles (penalty), not walls.
func blocks_movement() -> bool:
	return false


func walk_penalty() -> float:
	return data.walk_penalty if data != null else _DEFAULT_WALK_PENALTY


## Whether placing something on this cell may free this plant instead of
## being refused. Natural ground cover says yes; anything the player paid
## for says no. Read by the plant/build actions through duck typing.
func is_displaceable() -> bool:
	return data != null and data.displaceable


func _process(_delta: float) -> void:
	if data == null or _time_manager == null:
		return
	var max_stage: int = data.variants.size() - 1
	if growth_stage >= max_stage and _trample_damage <= 0.0:
		# Fully grown and undamaged: no further work ever. Drop out of the
		# per-frame process list (idle dispatch otherwise scales with planted
		# count). trample() calls set_process(true) to re-arm, which is what
		# lets a mature plant heal and a knocked-back one grow again.
		set_process(false)
		return
	var hour: int = int(_time_manager.time_of_day * 24.0) % 24
	if hour != _last_hour:
		_last_hour = hour
		# Heal first: a plant crossed once yesterday should not also lose the
		# hour's growth roll to damage it has already shed.
		if _trample_damage > 0.0:
			var per_hour: float = _TRAMPLE_HEAL_PER_DAY / 24.0
			_trample_damage = maxf(_trample_damage - per_hour, 0.0)
		if growth_stage < max_stage and randf() <= data.growth_chance:
			set_growth_stage(growth_stage + 1)


# --- Wind ------------------------------------------------------------------

## Attach the species' sway material to both of this plant's CanvasItems.
##
## BOTH items, because a clumped cell draws its frontmost individual through
## the child Sprite2D and the rest through this node's own _draw() — one
## material on the sprite alone would leave three tufts of four standing still.
## The material itself is SHARED (no duplicate per plant): the per-plant phase
## comes from the item's own origin inside the shader, which is the whole
## reason the shader needs nothing pushed to it per instance. Instance uniforms
## were the first design and they do not survive this many objects — see the
## wind_plant.gdshader header.
func _apply_wind_material() -> void:
	if data == null or data.wind_material == null:
		return
	if _sprite != null:
		_sprite.material = data.wind_material
	if not _extra_offsets.is_empty():
		material = data.wind_material


# --- Trampling (duck-typed by RegrowthManager) ------------------------------

## Trample damage a plant sheds per game day, in the same wear units the grass
## ledger uses — and set to the same number as RegrowthManager's
## `base_recovery_per_day`, deliberately. That parity is what makes the
## mechanic explainable: a cell needs the same ~0.83 crossings a day to hold
## EITHER the grass or the plant on it below its ceiling, and what differs
## between species is only how long the killing takes once traffic is above
## that line (`trample_resistance`). An absolute rate rather than a fraction of
## a stage, because the alternative makes a tough plant heal fast, which is
## backwards.
const _TRAMPLE_HEAL_PER_DAY: float = 0.15

## Feet on this plant. `amount` is in RegrowthManager's wear units, the same
## number the grass on this cell loses, so one call is one footfall.
##
## Damage accumulates; every `data.trample_resistance` of it costs a growth
## stage, and a plant trampled at stage 0 is freed — its _exit_tree clears the
## occupant claim, so the cell is walkable and plantable again on the next
## frame. Nothing regrows it: the ground is the mountain's to reclaim
## (RegrowthManager) and the plant is the player's to replace.
##
## Called from RegrowthManager.trample, per visitor step, so it stays a couple
## of float ops in the common case.
func trample(amount: float) -> void:
	if data == null or amount <= 0.0 or data.trample_resistance <= 0.0:
		return
	_trample_damage += amount
	while _trample_damage >= data.trample_resistance:
		_trample_damage -= data.trample_resistance
		if growth_stage <= 0:
			# Flattened. queue_free defers to end of frame; is_queued_for_deletion
			# keeps _on_graph_changed from re-claiming the cell in the meantime.
			queue_free()
			return
		set_growth_stage(growth_stage - 1)
	# Damage present, or a stage regained: the hourly tick has work again.
	set_process(true)


## Accumulated damage, in wear units. Test/debug read; the plant is the only
## thing that writes it.
func trample_damage() -> float:
	return _trample_damage


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
	# The extras draw whatever the sprite is showing, so a stage change has
	# to repaint them too. No-op when the cell holds a single individual.
	if not _extra_offsets.is_empty():
		queue_redraw()


# Decide how many individuals stand on this cell and where. The FRONTMOST
# (largest y) becomes the Sprite2D, so it occludes the rest correctly: a
# CanvasItem draws its own commands before its children, which makes _draw()
# output land strictly behind the sprite. Everything else is one draw call on
# a CanvasItem that already exists.
#
# Single-individual kinds keep the historical jitter box exactly — the three
# Espeletia must not move as a side effect of ground cover gaining clumps.
func _roll_clump() -> void:
	var n: int = 1
	if data != null:
		var lo: int = maxi(data.individuals_per_cell.x, 1)
		var hi: int = maxi(data.individuals_per_cell.y, lo)
		n = randi_range(lo, hi)
	if n <= 1:
		_sprite.position = Vector2(randi_range(-4, 4), randi_range(-4, 0))
		return

	var offsets: Array[Vector2] = []
	for i in n:
		# Diamond sampling without rejection: pick u across the full width,
		# then v across what is left of the height at that u. Uniform enough
		# for scatter and branch-free.
		var u: float = randf_range(-1.0, 1.0)
		var v: float = randf_range(-1.0, 1.0) * (1.0 - absf(u))
		offsets.append(Vector2(roundf(u * _SPREAD_X), roundf(v * _SPREAD_Y)))
	offsets.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.y < b.y)

	_sprite.position = offsets[n - 1]
	_extra_offsets = PackedVector2Array()
	_extra_flips = PackedByteArray()
	var flip_ok: bool = data == null or data.randomize_flip_h
	for i in n - 1:
		_extra_offsets.append(offsets[i])
		_extra_flips.append(1 if (flip_ok and randf() < 0.5) else 0)


# The extra individuals of a clumped cell. Runs on the node's own CanvasItem,
# so N tufts cost N draw commands and zero extra items — which is the point,
# since canvas-item count is what the web frame is priced on. Already sorted
# back to front by _roll_clump, and _sprite.offset carries the cell's altitude
# lift, so the extras ride it without recomputing anything.
func _draw() -> void:
	if _extra_offsets.is_empty() or _sprite == null or _sprite.texture == null:
		return
	var tex: Texture2D = _sprite.texture
	var size: Vector2 = tex.get_size()
	var base: Vector2 = _sprite.offset - size * 0.5
	for i in _extra_offsets.size():
		var at: Vector2 = _extra_offsets[i] + base
		if _extra_flips[i] == 0:
			draw_texture(tex, at)
		else:
			# Mirror about the individual's own centre. draw_texture has no
			# flip argument; the transform is the documented way and is reset
			# straight after so it cannot leak into the next iteration.
			draw_set_transform(at + Vector2(size.x, 0.0), 0.0, Vector2(-1.0, 1.0))
			draw_texture(tex, Vector2.ZERO)
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


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
	if _dims_cache.has(tex):
		return _dims_cache[tex]
	var dims: Vector2 = _scan_frame_dimensions(tex)
	_dims_cache[tex] = dims
	return dims


# The uncached scan behind _measure_frame_dimensions.
static func _scan_frame_dimensions(tex: Texture2D) -> Vector2:
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


# --- Burn API (driven by FireManager) --------------------------------------

func apply_burn_material() -> void:
	_burn_mat = ShaderMaterial.new()
	_burn_mat.shader = _BURN_SHADER
	_burn_mat.set_shader_parameter(&"burn_amount", 0.0)
	if _sprite != null:
		_sprite.material = _burn_mat
	# The extras are drawn on THIS CanvasItem, not the sprite's, so they need
	# the same material or a burning clump chars one tuft and leaves three.
	if not _extra_offsets.is_empty():
		material = _burn_mat


func set_burn_amount(t: float) -> void:
	var clamped: float = clampf(t, 0.0, 1.0)
	if _burn_mat != null:
		_burn_mat.set_shader_parameter(&"burn_amount", clamped)
	if clamped >= 1.0:
		burned_out.emit()


# Restore the sprite to its un-charred state. Called by FireManager when rain
# extinguishes a fire mid-burn.
func clear_burn_material() -> void:
	if _sprite != null:
		_sprite.material = null
	material = null
	_burn_mat = null
	# Burning replaced the sway material on both items; rain putting the fire
	# out has to give it back, or an extinguished plant is the only one on the
	# mountain standing still.
	_apply_wind_material()
