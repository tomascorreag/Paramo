class_name BurningCellVFX
extends Node2D

# Per-tile fire VFX. One instance per burning cell, owned by FireManager.
# Spawns a flame visual plus a grass overlay Sprite2D textured with a snapshot
# of the underlying grass tile and driven by burn_dissolve.gdshader. As
# burn_amount climbs 0→1 the overlay dissolves pixel-by-pixel, revealing the
# dirt tile FireManager painted on the underlying TileMapLayer at ignition time.
#
# TWO FLAME VISUALS, selected by Debug.fire_blob_flames:
#   blob   (default) — 1–MAX_FLAMES_PER_CELL FireBlobColumn quads running
#                      fire_blobs.gdshader, scattered off-centre inside the
#                      diamond. The count scales with intensity (see set_state /
#                      FireDynamics.flame_count). Fully procedural.
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
#      atlas_coords), then adds to tree.
#   2. _ready spawns the overlay + flames and positions self on the layer.
#   3. FireManager calls set_state(intensity, fuel_frac) each tick: intensity
#      drives the flames + light, fuel_frac drives the grass dissolve. This node
#      is a pure renderer — the sim (age, fuel, spread) lives in FireManager /
#      FireDynamics.
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

# --- Scattered blob flames ---------------------------------------------------
# The blob path draws 1–MAX_FLAMES_PER_CELL columns, each at a deterministic
# INTEGER sub-tile offset so they read as scattered flames rather than one
# grid-locked column. Integer keeps the shader's world-snapped faux-pixels
# aligned to the terrain lattice (see fire_blob_column's geometry note). Box is
# tighter than the 32×16 diamond's ±16/±8 half-extents so flames stay on-tile.
const SCATTER_X: int = 9
const SCATTER_Y_LOW: int = -5
const SCATTER_Y_HIGH: int = 3
# Soft cap on flame quads BEYOND the first, summed across every burning cell. The
# primary flame always spawns (so a fire is never invisible); the 2nd/3rd are
# budgeted, bounding worst-case additive blob overdraw on WebGL2 the same way
# LIGHT_BUDGET bounds the lights. Charged per-instance via _extras_charged.
const EXTRA_FLAME_BUDGET: int = 40

# --- Burn-down + smoulder tail -----------------------------------------------
# The fire loses its hot stages as the cell exhausts its FUEL: heat_ceiling ramps
# from 1.0 down to BURNOUT_HEAT_CEILING as fuel_frac enters the ember band
# (FireDynamics.EMBER_FUEL_FRAC), so it visibly runs down through the palette
# (white drops out first, then yellow) instead of burning white-hot until the
# instant it dies. See _burnout_t.
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

# --- Douse fade --------------------------------------------------------------
# When a fire is EXTINGUISHED early (rain or a player douse) rather than burning
# out, it fades its intensity to 0 over this long instead of vanishing on a
# frame boundary — a doused flame shrinks out. Shorter than SMOULDER_SECONDS: a
# burnout lingers as smoke, a douse just dies. See begin_douse.
const DOUSE_SECONDS: float = 0.7

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
# Energy fraction in full daylight (vs LIGHT_NIGHT_FACTOR at night).
const LIGHT_DAY_FACTOR: float = 0.08
# Energy fraction at night — the fire's peak strength against the dark. Below 1.0
# on purpose: a wildfire cell is a small source, so a slightly muted glow reads
# more like living flame than a full-blast lantern. This is the night ceiling the
# dim ramp lerps DOWN from toward LIGHT_DAY_FACTOR as day breaks.
const LIGHT_NIGHT_FACTOR: float = 0.75
# Ambient HSV-value thresholds for the dim ramp. At/below NIGHT_VALUE_HI the fire
# is full strength; at/above DAY_VALUE_LO it's dimmed to LIGHT_DAY_FACTOR. Tuned to
# tileset_test_profile's ambient gradient — the profile gameplay_base.tscn actually
# ships, so this is what the game uses. Its night value is a flat 0.6 (a bright
# saturated blue, NOT a dark night), rising through dawn to ~1.0 at midday and ~1.08
# at dusk. NIGHT_VALUE_HI sits just above the 0.6 night floor so fire stays
# full-strength all night; DAY_VALUE_LO near the daytime plateau lets it fade
# gradually across the dawn/dusk band.
# NOTE: an earlier version tuned these to default_profile (night v≈0.2), which is
# NOT the shipped profile — at the real 0.6 night value that put the fire at ~64%
# strength all night ("fire doesn't light up at night"). If you switch the profile
# (e.g. to default_profile), retune these to that gradient's night value.
const NIGHT_VALUE_HI: float = 0.62
const DAY_VALUE_LO: float = 0.95

# Shared radial falloff texture — baked once, reused by every fire light. Never
# mutated (texture_scale is per-node), so sharing is safe.
static var _falloff_tex: GradientTexture2D = null
# Count of currently-lit cells. Incremented on light spawn. Released either at
# begin_smoulder (burn completion — early, so a smouldering tail doesn't sit on
# a slot the live fire needs) or at PREDELETE (extinguish / graph-change wipe).
# The two can't double-count: begin_smoulder nulls _light, which is what
# _notification gates on.
static var _active_lights: int = 0
# Count of EXTRA flame quads (slots beyond the first) live across all cells, vs
# EXTRA_FLAME_BUDGET. Each instance tracks its own charge in _extras_charged and
# releases exactly that on shrink / smoulder / free — never derived from
# _columns.size(), so the live A/B toggle's despawn→respawn can't leak it. Same
# sentinel discipline as _active_lights.
static var _active_flames: int = 0
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
# Fraction of the tile's fuel REMAINING, in [0, 1] (1 = untouched grass, 0 =
# consumed). Drives the grass dissolve (burn_amount = 1 - _fuel_frac) and the
# heat-ceiling burn-down (_burnout_t). Replaces the old raw burn `amount`:
# FireManager now integrates fuel, not a timer. Starts full so a just-spawned
# cell shows intact grass before the first set_state.
var _fuel_frac: float = 1.0
var _light: PointLight2D = null
var _flicker_phase: float = 0.0
var _intensity: float = 0.0
# The blob path's scattered quads (empty on the sprite path); the sprite path's
# flames (empty on the blob path). Exactly one is populated at a time.
var _columns: Array[FireBlobColumn] = []
var _flames: Array[AnimatedSprite2D] = []
# How many of this instance's columns are charged against _active_flames (i.e.
# how many extras beyond the first it currently holds). Released in exactly one
# place per lifetime — see _release_extra_flames.
var _extras_charged: int = 0
var _smouldering: bool = false
var _smoulder_left: float = 0.0
var _smoulder_intensity: float = 0.0
# Douse fade (extinguish path). Mutually exclusive with _smouldering — a fire
# either burns out (smoulder) or is put out (douse), never both.
var _dousing: bool = false
var _douse_left: float = 0.0
var _douse_from: float = 0.0


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
	for col: FireBlobColumn in _columns:
		if is_instance_valid(col):
			col.queue_free()
	_columns.clear()
	# Release whatever this instance held; _spawn_flames re-charges from scratch.
	# Without this the live A/B toggle would leak the global counter every flip.
	_release_extra_flames()
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
	# Seed the primary flame; set_state grows/shrinks the scattered extras as
	# intensity moves. flame_count(0) == 1, so this spawns exactly the primary.
	_reconcile_columns(FireDynamics.flame_count(_intensity))


# Grow or shrink the scattered blob columns toward `target`, respecting the
# global EXTRA_FLAME_BUDGET for every column beyond the first. The primary (slot
# 0) always exists; extras appear only while there is budget and drop out again
# as intensity falls. Each column sits at a deterministic integer sub-tile offset
# with its own per-slot seed, so the shader draws distinct, world-locked flames.
func _reconcile_columns(target: int) -> void:
	target = clampi(target, 1, FireDynamics.MAX_FLAMES_PER_CELL)

	# Shrink: free trailing columns (always extras, since target >= 1) and hand
	# their budget back.
	while _columns.size() > target:
		var col: FireBlobColumn = _columns.pop_back()
		if is_instance_valid(col):
			col.queue_free()
		if _extras_charged > 0:
			_extras_charged -= 1
			_active_flames -= 1

	# Grow: slot 0 is free; each extra needs a budget slot or we stop early.
	while _columns.size() < target:
		var slot: int = _columns.size()
		if slot >= 1:
			if _active_flames >= EXTRA_FLAME_BUDGET:
				break
			_active_flames += 1
			_extras_charged += 1
		_columns.append(_make_column(slot))


func _make_column(slot: int) -> FireBlobColumn:
	var column := FireBlobColumn.new()
	column.name = "FireBlobColumn%d" % slot
	# Scatter off cell-centre. The shader's blob field is relative to
	# MODEL_MATRIX[3] (the node origin), so an offset just moves the whole flame
	# and it still world-snaps — this is the intended scatter mechanism.
	column.position = _slot_offset(slot)
	# Distinct per-slot seed, or two flames on one cell render pixel-identical.
	column.set_cell_seed(FireBlobColumn.seed_for_cell_slot(cell, slot))
	add_child(column)
	return column


# Deterministic integer offset for a flame slot within the diamond. Hashed off
# (cell, slot) so it is stable across frames and across an A/B re-spawn — a
# swimming anchor would break the world-snap.
func _slot_offset(slot: int) -> Vector2:
	var h: int = hash(Vector3i(cell.x, cell.y, slot * 7 + 1))
	var ox: int = (h & 0xff) % (2 * SCATTER_X + 1) - SCATTER_X
	var oy: int = ((h >> 8) & 0xff) % (SCATTER_Y_HIGH - SCATTER_Y_LOW + 1) + SCATTER_Y_LOW
	return Vector2(float(ox), float(oy))


# Hand this instance's entire flame-budget charge back to the global counter and
# zero it. Idempotent — calling it twice releases nothing the second time, which
# is what makes the smoulder/PREDELETE double-path safe.
func _release_extra_flames() -> void:
	if _extras_charged > 0:
		_active_flames -= _extras_charged
		_extras_charged = 0


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
		var t: float = 1.0 - clampf(_smoulder_left / SMOULDER_SECONDS, 0.0, 1.0)
		for col: FireBlobColumn in _columns:
			if is_instance_valid(col):
				col.set_intensity(lerpf(_smoulder_intensity, 0.0, t))
	elif _dousing:
		_douse_left -= delta
		if _douse_left <= 0.0:
			queue_free()
			return
		# Fade intensity from where the fire was toward 0 — the flame shrinks out
		# rather than popping. The light block below reads _intensity, so the glow
		# fades in lockstep with no extra work. heat_ceiling is left as it was, so
		# the shrinking flame keeps its colour instead of turning to smoke.
		var dt: float = 1.0 - clampf(_douse_left / DOUSE_SECONDS, 0.0, 1.0)
		_intensity = lerpf(_douse_from, 0.0, dt)
		for col: FireBlobColumn in _columns:
			if is_instance_valid(col):
				col.set_intensity(_intensity)

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


# Dim factor in [LIGHT_DAY_FACTOR, LIGHT_NIGHT_FACTOR] derived inversely from the
# day/night ambient brightness: LIGHT_NIGHT_FACTOR at night, LIGHT_DAY_FACTOR in
# daylight. Cached per frame and shared across all lit cells (identical for every fire).
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
	_night_factor = lerpf(LIGHT_NIGHT_FACTOR, LIGHT_DAY_FACTOR, day_t)
	return _night_factor


func _notification(what: int) -> void:
	# Release the budget slots when this cell dies (rain-extinguish or the
	# en-masse wipe on graph_changed). Burn-completion instead releases early via
	# begin_smoulder(), which nulls _light and zeroes _extras_charged — so neither
	# counter can double-decrement.
	if what == NOTIFICATION_PREDELETE:
		if _light != null:
			_active_lights -= 1
		_release_extra_flames()


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


## Called by FireManager every tick. `fire_intensity` (0-1, from FireDynamics)
## drives the flames and the light; `fuel_frac` (0-1, fuel REMAINING on the tile)
## drives the grass dissolve and the heat-ceiling burn-down. This node is a pure
## renderer — it holds no sim state of its own.
func set_state(fire_intensity: float, fuel_frac: float) -> void:
	_fuel_frac = clampf(fuel_frac, 0.0, 1.0)
	if _overlay_mat != null:
		# Grass chars as fuel is consumed: full grass at fuel_frac 1, dirt at 0.
		_overlay_mat.set_shader_parameter(&"burn_amount", 1.0 - _fuel_frac)
	if _smouldering or _dousing:
		# The tail/fade owns intensity from here; don't let a late tick resurrect it.
		return
	_intensity = clampf(fire_intensity, 0.0, 1.0)
	# Blob path only. The sprite path has no intensity concept (fixed flames); it
	# still gets _intensity above for the shared light. Debug.fire_blob_flames is
	# the live selector — a toggle re-spawns via _on_flame_style_changed.
	if Debug.fire_blob_flames:
		_reconcile_columns(FireDynamics.flame_count(_intensity))
		_push_flame_state()


## Current blob intensity in [0, 1]. Drives the flame size AND the light energy,
## so both paths' glow tracks the kindling->wildfire ramp.
func get_intensity() -> float:
	return _intensity


# Pushes the current intensity + heat-ceiling to every scattered blob column.
# The sprite path has no _columns (and no intensity concept — its flames are
# fixed at spawn), so this is a no-op there; the light reads _intensity in
# _process regardless.
func _push_flame_state() -> void:
	var ceiling: float = lerpf(1.0, BURNOUT_HEAT_CEILING, _burnout_t())
	for col: FireBlobColumn in _columns:
		if is_instance_valid(col):
			col.set_intensity(_intensity)
			# Burn-down: as the tile's fuel exhausts the fire loses its hot stages,
			# running white->yellow->orange->char before the smoulder tail.
			col.set_heat_ceiling(ceiling)


# 0 while fuel is plentiful, ramping to 1 as the last EMBER_FUEL_FRAC of fuel
# burns — so the fire cools as it runs out of grass, not on a fixed timer.
func _burnout_t() -> float:
	return 1.0 - smoothstep(0.0, FireDynamics.EMBER_FUEL_FRAC, _fuel_frac)


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

	# The sprite path has no _columns and no smoulder equivalent — its flames
	# can't be reduced to smoke — so it keeps the old behaviour and just dies.
	if _columns.is_empty():
		queue_free()
		return

	# Drop to a single smoke column, freeing the scattered extras and releasing
	# their budget now (a thinning smoulder tail shouldn't sit on flame slots the
	# live fires need).
	_reconcile_columns(1)

	_smoulder_intensity = _intensity * SMOULDER_INTENSITY_SCALE
	for col: FireBlobColumn in _columns:
		if is_instance_valid(col):
			col.set_intensity(_smoulder_intensity)
			col.set_heat_ceiling(SMOULDER_HEAT_CEILING)


## The fire was EXTINGUISHED early (rain or a player douse) rather than burning
## out. Fade the flame's intensity to 0 over DOUSE_SECONDS instead of freeing on
## the spot, so it visibly shrinks out. Called by FireManager._extinguish INSTEAD
## OF queue_free(). Like begin_smoulder, the node has already left
## FireManager._burning, so nothing drives it again — the fade is self-driving in
## _process. The light + scattered flames are KEPT (unlike smoulder, which drops
## to one smoke column): a douse is short, so they simply fade with the intensity,
## and their budget slots release together at PREDELETE when the node frees.
func begin_douse() -> void:
	if _dousing or _smouldering:
		return
	# The sprite path's flames are fixed-size and can't shrink, so keep its old
	# instant behaviour — mirrors begin_smoulder.
	if _columns.is_empty():
		queue_free()
		return
	_dousing = true
	_douse_left = DOUSE_SECONDS
	_douse_from = maxf(_intensity, 0.0)
