class_name ObjectPainter
extends RefCounted

# ============================================================================
# ObjectPainter
# ============================================================================
#
# Owns procgen world-object placement AND spawning. Two responsibilities:
#
#   1. `assign_object_kinds(grid)` — rolls each registered `WorldObjectData`'s
#      `density_by_biome` against eligible cells and writes
#      `TerrainCell.object_kind`. Called every Regenerate; deterministic per
#      object-rng seed, and it also picks the run's EcosystemProfile.
#   2. `paint(grid, world, pathfinder)` — instantiates Node2D occupants for
#      every flagged cell and parents them under `world`.
#
# Why not in TerrainGenerator: density data now lives on each
# `WorldObjectData.tres` (per-kind, not per-map), so it's natural for the
# painter — which already owns the kind→data registry — to do the placement
# pass. TerrainGenerator stays pure (heightfield, biomes, river, …).
#
# Re-entrancy / Regenerate:
#   - Every spawned instance joins group `&"procedural_object"`. On each
#     paint() call, prior group members under `world` are freed first so
#     clicking Regenerate doesn't stack rocks on top of old ones.
#   - Placement + variant picks draw from the rng the caller passes into
#     paint()/begin_spawn(). ProceduralWorld derives it from the terrain seed
#     (seed ^ 0xC8FAB0CC, the same derivation verify_terrain_invariants.gd and
#     the balance simulator use), so rock layouts are reproducible per seed.
#     A null rng falls back to randomize() for legacy callers.
#
# ============================================================================


# Kind → WorldObjectData. Single source of truth for the kinds the painter
# knows how to procgen-place. Every plant species spawns procedurally for the
# natural baseline scatter (which species, and how much, is the run's
# EcosystemProfile); players can plant the woody/rosette ones on top (the
# action layer reuses the same scene and .tres via `data_for`). Procgen
# instances join group `&"procedural_object"` and are cleared on Regenerate;
# player-planted ones aren't tagged and survive. `frailejon` is Espeletia
# grandiflora — the id predates the species list and is keyed on everywhere
# (FTUE, unlocks, sim), so it stays.
const _ROCK_DATA: WorldObjectData = preload("res://resources/objects/rock.tres")
const _ROCK_SNOW_DATA: WorldObjectData = preload("res://resources/objects/rock_snow.tres")
const _ROCK_MOSS_DATA: WorldObjectData = preload("res://resources/objects/rock_moss.tres")
const _FRAILEJON_DATA: WorldObjectData = preload("res://resources/objects/frailejon.tres")
const _ESPELETIA_BARCLAYANA_DATA: WorldObjectData = preload("res://resources/objects/espeletia_barclayana.tres")
const _ESPELETIA_HARTWEGIANA_DATA: WorldObjectData = preload("res://resources/objects/espeletia_hartwegiana.tres")
const _CALAMAGROSTIS_DATA: WorldObjectData = preload("res://resources/objects/calamagrostis.tres")
const _CHUSQUEA_DATA: WorldObjectData = preload("res://resources/objects/chusquea.tres")
const _CORTADERIA_DATA: WorldObjectData = preload("res://resources/objects/cortaderia.tres")
const _HYPERICUM_DATA: WorldObjectData = preload("res://resources/objects/hypericum.tres")
const _ARCYTOPHYLLUM_DATA: WorldObjectData = preload("res://resources/objects/arcytophyllum.tres")

const _DATA_BY_KIND: Dictionary = {
	&"rock": _ROCK_DATA,
	&"rock_snow": _ROCK_SNOW_DATA,
	&"rock_moss": _ROCK_MOSS_DATA,
	&"frailejon": _FRAILEJON_DATA,
	&"espeletia_barclayana": _ESPELETIA_BARCLAYANA_DATA,
	&"espeletia_hartwegiana": _ESPELETIA_HARTWEGIANA_DATA,
	&"calamagrostis": _CALAMAGROSTIS_DATA,
	&"chusquea": _CHUSQUEA_DATA,
	&"cortaderia": _CORTADERIA_DATA,
	&"hypericum": _HYPERICUM_DATA,
	&"arcytophyllum": _ARCYTOPHYLLUM_DATA,
}

# Kind → PackedScene. All boulder-shaped kinds share `rock.tscn` and all
# plant kinds share `frailejon.tscn` — the Sprite2D + shadow shader config is
# identical within a family; only the texture variants (and, for plants, the
# growth/shadow/displaceable flags) differ, and those come off the instance's
# `data` resource (overridden in the spawn loop). This dict lives
# here — not on WorldObjectData — to break the rock.tscn ↔ rock.tres
# load-time cycle.
const _ROCK_SCENE: PackedScene = preload("res://scenes/objects/rock.tscn")
const _FRAILEJON_SCENE: PackedScene = preload("res://scenes/tools/frailejon.tscn")

const _SCENE_BY_KIND: Dictionary = {
	&"rock": _ROCK_SCENE,
	&"rock_snow": _ROCK_SCENE,
	&"rock_moss": _ROCK_SCENE,
	&"frailejon": _FRAILEJON_SCENE,
	&"espeletia_barclayana": _FRAILEJON_SCENE,
	&"espeletia_hartwegiana": _FRAILEJON_SCENE,
	&"calamagrostis": _FRAILEJON_SCENE,
	&"chusquea": _FRAILEJON_SCENE,
	&"cortaderia": _FRAILEJON_SCENE,
	&"hypericum": _FRAILEJON_SCENE,
	&"arcytophyllum": _FRAILEJON_SCENE,
}

const _GROUP_PROCEDURAL: StringName = &"procedural_object"

# The ecosystems a run can draw. One is picked per grid by the FIRST draw of
# the object rng stream (see assign_object_kinds), so every caller that seeds
# the stream the same way — ProceduralWorld, SimWorld, the invariants harness —
# lands on the same mountain for the same seed without passing it around.
# Order matters: it is the index the draw selects. Append, never reorder.
const _PROFILES: Array[EcosystemProfile] = [
	preload("res://resources/ecosystems/chingaza.tres"),
	preload("res://resources/ecosystems/guerrero.tres"),
	preload("res://resources/ecosystems/nevados.tres"),
]

# Above this many plant occupants per grid, assign_object_kinds warns. Each
# plant is one or two CanvasItems and canvas-item count is the measured
# web-frame lever (dev-notes/performance.md); the target is ~350–450. Tune
# per-kind densities down rather than thinning after the fact.
const PLANT_BUDGET: int = 600

## The one authored derivation for the object-placement RNG stream:
## rng.seed = terrain_seed ^ OBJECT_SEED_XOR. Lives here (the consumer of the
## stream) so ProceduralWorld, SimWorld, and the terrain harness all reference
## the same constant instead of re-authoring the literal.
const OBJECT_SEED_XOR: int = 0xC8FAB0CC

# Gaussian σ (in altitude half-steps) for the per-kind altitude preference
# applied during placement. Matches the tile painter's `_SIGMA_ALT` so an
# author who has internalized the variant-picker's altitude tuning gets the
# same falloff shape here. ~exp(-2) at 3 half-steps off, ~exp(-8) at 6.
const _SIGMA_ALT: float = 3.0


## Pick the run's ecosystem, then roll every registered kind against every
## eligible cell and write the winner into `TerrainCell.object_kind`. Cells
## previously flagged are reset before rolling, so calling this twice on the
## same grid produces a fresh scatter rather than stacking flags.
##
## Eligible cells: `kind == GROUND` AND `ground_shape ∈ {FULL_CUBE, FLAT}`.
##
## Per cell, every kind gets a weight
##   d_k = density_by_biome[biome] × ecosystem scale × altitude × water × patch
## and the cell is occupied with probability min(Σ d_k, 1), the occupant drawn
## proportionally to the weights. This is a WEIGHTED pick, not first-hit-wins:
## with a dozen competing kinds, dictionary order must not be a balance knob.
## Σ d_k > 1 saturates — two kinds at 0.8 on the same cell do not make it
## 160% full, they split it.
##
## `profile` is the ecosystem. When null it is drawn from `rng` — the FIRST
## draw of the stream — so every caller that seeds the object rng the same
## way (ProceduralWorld, SimWorld, the harness) gets the same mountain per
## seed with no plumbing. The choice is written to `grid.ecosystem`.
##
## `rng` defaults to a freshly randomized RNG so successive calls yield
## different layouts. Pass a seeded RNG for reproducibility.
static func assign_object_kinds(
	grid: TerrainGrid,
	rng: RandomNumberGenerator = null,
	profile: EcosystemProfile = null,
) -> void:
	if grid == null:
		return
	if _DATA_BY_KIND.is_empty():
		return
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.randomize()

	if profile == null:
		profile = _PROFILES[rng.randi_range(0, _PROFILES.size() - 1)]
	grid.ecosystem = profile

	# Per-kind precompute, in registry order. The ecosystem scale applies to
	# PLANT kinds only — rocks are geology, not flora, and a profile listing
	# them would just be noise. Kinds scaled to 0 are dropped here so the
	# per-cell loop never sees them.
	var kinds: Array[StringName] = []
	var datas: Array[WorldObjectData] = []
	var scales: PackedFloat32Array = PackedFloat32Array()
	var noises: Array = []  # FastNoiseLite or null, parallel to `kinds`
	var need_water_dist: bool = false
	for kind: StringName in _DATA_BY_KIND.keys():
		var data: WorldObjectData = _DATA_BY_KIND[kind]
		var scale: float = 1.0
		if data is PlantObjectData:
			scale = profile.scale_for(kind)
			if (data as PlantObjectData).water_affinity != 0.0:
				need_water_dist = true
		if scale <= 0.0:
			continue
		kinds.append(kind)
		datas.append(data)
		scales.append(scale)
		# Patch noise: one generator per patchy kind, seeded from the stream
		# (one draw, fixed order) xor the kind name so two species never
		# share an outline even at the same draw.
		var noise: FastNoiseLite = null
		if data.patch_frequency > 0.0:
			noise = FastNoiseLite.new()
			noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
			noise.frequency = data.patch_frequency
			noise.seed = int(hash(kind)) ^ rng.randi()
		noises.append(noise)

	# Distance-to-water field, computed once per call IF any surviving plant
	# kind reads it (affinity or avoidance). Multi-source BFS over
	# face-connected cells is O(W * H) — much cheaper than a per-cell radius
	# scan inside the placement loop.
	var water_dist: PackedInt32Array = PackedInt32Array()
	if need_water_dist:
		water_dist = _compute_water_distance(grid)

	var n: int = kinds.size()
	var weights: PackedFloat32Array = PackedFloat32Array()
	weights.resize(n)
	var plant_count: int = 0

	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			c.object_kind = &""
			if c.kind != TerrainCell.Kind.GROUND:
				continue
			if c.ground_shape != TerrainCell.GroundShape.FULL_CUBE \
					and c.ground_shape != TerrainCell.GroundShape.FLAT:
				continue
			var total: float = 0.0
			for i in n:
				var data: WorldObjectData = datas[i]
				var d: float = float(data.density_by_biome.get(c.biome, 0.0))
				if d > 0.0:
					d *= scales[i]
					d *= _altitude_term(data, c.altitude)
					if need_water_dist and data is PlantObjectData:
						var wa: float = (data as PlantObjectData).water_affinity
						if wa != 0.0:
							d *= _water_term(wa, water_dist[y * grid.width + x])
					if noises[i] != null:
						d *= _patch_term(noises[i], data.patch_cut, data.patch_edge, x, y)
				weights[i] = d
				total += d
			if total <= 0.0:
				continue
			if rng.randf() >= minf(total, 1.0):
				continue
			# Occupied: draw the kind proportionally to its weight.
			var pick: float = rng.randf() * total
			var acc: float = 0.0
			var chosen: int = n - 1
			for i in n:
				acc += weights[i]
				if pick < acc:
					chosen = i
					break
			c.object_kind = kinds[chosen]
			if datas[chosen] is PlantObjectData:
				plant_count += 1

	if plant_count > PLANT_BUDGET:
		push_warning(
			"ObjectPainter: %d plants on a %dx%d grid (ecosystem '%s') — over PLANT_BUDGET %d. Lower per-kind densities; see dev-notes/performance.md."
			% [plant_count, grid.width, grid.height, profile.id, PLANT_BUDGET]
		)


## The registered data for `kind`, or null. For the action layer, which
## spawns player-placed plants from the same .tres the painter scatters.
## Every registered object kind. For tools and tests that need to sweep the
## registry rather than restate it — a hardcoded species list in a checker is
## a list that silently stops covering what was added after it.
static func kinds() -> Array:
	return _DATA_BY_KIND.keys()


static func data_for(kind: StringName) -> WorldObjectData:
	return _DATA_BY_KIND.get(kind)


## The scene every plant kind is rendered with. Kind-specific behaviour comes
## from the `data` resource swapped in at spawn, not from separate scenes.
static func plant_scene() -> PackedScene:
	return _FRAILEJON_SCENE


## The ecosystem profile with `id`, or null when unknown / empty. Used by
## `ProceduralWorld.ecosystem_override` and tools to pin a mountain.
static func profile_by_id(id: StringName) -> EcosystemProfile:
	if id == &"":
		return null
	for p in _PROFILES:
		if p.id == id:
			return p
	push_warning("ObjectPainter: unknown ecosystem id '%s'." % id)
	return null


## Every ecosystem a run can draw, in draw-index order.
static func profiles() -> Array[EcosystemProfile]:
	return _PROFILES


# Altitude multiplier in [0, 1]. A band (`altitude_band.x >= 0`) is a plateau
# with Gaussian shoulders on the distance to its nearest edge; otherwise the
# legacy single-peak Gaussian on `preferred_altitude`; otherwise flat. Both
# use `_SIGMA_ALT` so one internalised falloff shape serves both.
static func _altitude_term(data: WorldObjectData, altitude: int) -> float:
	var dd: float = 0.0
	if data.altitude_band.x >= 0:
		if altitude < data.altitude_band.x:
			dd = float(data.altitude_band.x - altitude)
		elif altitude > data.altitude_band.y:
			dd = float(altitude - data.altitude_band.y)
	elif data.preferred_altitude > 0:
		dd = float(altitude - data.preferred_altitude)
	else:
		return 1.0
	return exp(- (dd * dd) / (2.0 * _SIGMA_ALT * _SIGMA_ALT))


# Water multiplier in [0, 1] from a signed affinity and a BFS distance.
# `dist == INT32_MAX` (no water on the grid) collapses attraction to 0 and
# avoidance to 1 — the correct degenerate behaviour in both directions.
static func _water_term(affinity: float, dist: int) -> float:
	var fd: float = float(dist)
	var g: float = exp(-absf(affinity) * fd * fd)
	return g if affinity > 0.0 else 1.0 - g


# Patch multiplier in [0, 1]: noise at or above `cut` ramps linearly to 1 over
# `edge`, so a patch is a plateau with a soft rim rather than a hard outline.
# The ramp is a FIXED width on the noise scale, not "to the noise ceiling":
# TYPE_SIMPLEX_SMOOTH only reaches ±0.75 (p90 = 0.33), so a ramp to 1.0 would
# average ~0.2 across a whole patch interior and silently halve every patchy
# species — the first report_flora_scatter run measured exactly that. `edge` is
# per species (WorldObjectData.patch_edge) because the pajonal matrix and a
# chuscal want opposite shapes: wide-and-low is a soft mosaic, narrow-and-high
# is a small dense stand with a sharp boundary.
static func _patch_term(noise: FastNoiseLite, cut: float, edge: float, x: int, y: int) -> float:
	var v: float = noise.get_noise_2d(float(x), float(y))
	return clampf((v - cut) / maxf(edge, 0.001), 0.0, 1.0)


# Multi-source BFS over 4-connected face neighbors. Returns a flat W*H
# PackedInt32Array of step counts to the nearest WATER cell. WATER cells
# themselves are seeded with 0; ground cells touching water resolve to 1.
# Cells with no water reachable in the grid keep INT32_MAX (i.e. "infinity"
# for the caller's exp-falloff multiplier — collapses to 0).
static func _compute_water_distance(grid: TerrainGrid) -> PackedInt32Array:
	var w: int = grid.width
	var h: int = grid.height
	var n: int = w * h
	var out: PackedInt32Array = PackedInt32Array()
	out.resize(n)
	const INF_DIST: int = 2147483647
	for i in n:
		out[i] = INF_DIST
	var frontier: PackedInt32Array = PackedInt32Array()
	for y in h:
		for x in w:
			if grid.at(x, y).kind == TerrainCell.Kind.WATER:
				var idx: int = y * w + x
				out[idx] = 0
				frontier.append(idx)
	# Simple FIFO BFS. Head pointer rather than pop_front (which reallocs).
	var head: int = 0
	while head < frontier.size():
		var cur: int = frontier[head]
		head += 1
		var cd: int = out[cur]
		var cx: int = cur % w
		var cy: int = cur / w
		var nd: int = cd + 1
		# 4-connected on the data grid (face-neighbors on the diamond grid:
		# NE/NW/SE/SW map to ±x and ±y here).
		if cx > 0:
			var i_l: int = cur - 1
			if out[i_l] > nd:
				out[i_l] = nd
				frontier.append(i_l)
		if cx < w - 1:
			var i_r: int = cur + 1
			if out[i_r] > nd:
				out[i_r] = nd
				frontier.append(i_r)
		if cy > 0:
			var i_u: int = cur - w
			if out[i_u] > nd:
				out[i_u] = nd
				frontier.append(i_u)
		if cy < h - 1:
			var i_d: int = cur + w
			if out[i_d] > nd:
				out[i_d] = nd
				frontier.append(i_d)
	return out


## Spawn a Node2D for every cell flagged with an object_kind. Must run AFTER
## Pathfinder.rebuild so the new TileGrid exists for occupant registration —
## each Node2D's `_ready()` calls `pf.grid().set_occupant(cell, self)`.
##
## Runs `assign_object_kinds` first (non-deterministic), then clears prior
## group `&"procedural_object"` children under `world`, then spawns. Player-
## placed occupants (frailejones) are not in that group and survive.
static func paint(
	grid: TerrainGrid,
	world: Node2D,
	pathfinder: Pathfinder,
	rng: RandomNumberGenerator = null,
	profile: EcosystemProfile = null,
) -> void:
	var ctx: Dictionary = begin_spawn(grid, world, pathfinder, rng, profile)
	if ctx.is_empty():
		return
	while not spawn_step(ctx, 0x7FFFFFFF):
		pass


## Begins a chunked spawn job: validates inputs, rolls `assign_object_kinds`,
## clears prior procedural-group children, and returns a context Dictionary
## that spawn_step consumes. Returns {} on invalid input. Driving spawn_step
## with a small row budget across frames keeps instantiation (100-500 nodes)
## from freezing the main thread on load. Pass a seeded `rng` for
## reproducible layouts (ProceduralWorld derives one from the terrain seed);
## null keeps the legacy randomized behavior. `profile` pins the ecosystem;
## null draws it from `rng` (see assign_object_kinds).
static func begin_spawn(
	grid: TerrainGrid,
	world: Node2D,
	pathfinder: Pathfinder,
	rng: RandomNumberGenerator = null,
	profile: EcosystemProfile = null,
) -> Dictionary:
	if grid == null:
		push_error("ObjectPainter.begin_spawn: grid is null.")
		return {}
	if world == null:
		push_error("ObjectPainter.begin_spawn: world Node2D is null — wire it in the inspector.")
		return {}
	if pathfinder == null:
		push_error("ObjectPainter.begin_spawn: pathfinder is null.")
		return {}

	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.randomize()

	assign_object_kinds(grid, rng, profile)
	_clear_existing(world)

	return {
		"grid": grid,
		"world": world,
		"pathfinder": pathfinder,
		"rng": rng,
		"y": 0,
	}


## Spawns up to `max_rows` rows of flagged occupants. Returns true once every
## row has been spawned.
static func spawn_step(ctx: Dictionary, max_rows: int) -> bool:
	if ctx.is_empty():
		return true
	var grid: TerrainGrid = ctx["grid"]
	var spawned: int = 0
	while spawned < max_rows:
		var y: int = ctx["y"]
		if y >= grid.height:
			return true
		_spawn_row(grid, ctx["world"], ctx["pathfinder"], ctx["rng"], y)
		ctx["y"] = y + 1
		spawned += 1
	return int(ctx["y"]) >= grid.height


## Coarse 0..1 completion fraction for progress UI.
static func spawn_progress(ctx: Dictionary) -> float:
	if ctx.is_empty():
		return 1.0
	var h: int = ctx["grid"].height
	return clampf(float(ctx["y"]) / float(maxi(h, 1)), 0.0, 1.0)


# Spawns every flagged occupant in row `y`. Instantiation + add_child + the
# pathfinder.cell_to_world placement run on the main thread (scene-tree access),
# so this is the unit a chunked caller advances per frame.
static func _spawn_row(
	grid: TerrainGrid,
	world: Node2D,
	pathfinder: Pathfinder,
	rng: RandomNumberGenerator,
	y: int,
) -> void:
	for x in grid.width:
		var c: TerrainCell = grid.at(x, y)
		if c.object_kind == &"":
			continue
		var scene: PackedScene = _SCENE_BY_KIND.get(c.object_kind)
		if scene == null:
			push_warning(
				"ObjectPainter: unknown object_kind '%s' at (%d, %d)."
				% [c.object_kind, x, y]
			)
			continue
		var inst: Node2D = scene.instantiate()
		inst.cell = Vector2i(x, y)
		# Override the .tscn-wired `data` with the kind-specific resource.
		# Multiple kinds share `rock.tscn`, so the @export default
		# (rock.tres) needs to be replaced with rock_snow.tres /
		# rock_moss.tres / etc. before _ready runs (which happens at
		# add_child below) so variant lookups read from the right .tres.
		var data: WorldObjectData = _DATA_BY_KIND[c.object_kind]
		if "data" in inst:
			inst.data = data
		# Variant pick — read variant count off the (now-overridden) data.
		if "rock_variant" in inst and data.variants.size() > 0:
			inst.rock_variant = rng.randi_range(0, data.variants.size() - 1)
		# Plant kinds use `variants` as growth stages, not random skins.
		# Procgen scatter (paramo background) should look established, so
		# spread across stages instead of all sprouting from stage 0. The
		# field's growth loop continues to advance from whichever stage we
		# seed here. Set BEFORE add_child so _ready picks up the correct
		# texture on its initial _apply_variant_texture call.
		if "growth_stage" in inst and data.variants.size() > 0:
			inst.growth_stage = rng.randi_range(0, data.variants.size() - 1)
		# Tag for cleanup on next regenerate.
		inst.add_to_group(_GROUP_PROCEDURAL)
		# Add BEFORE setting global_position so _ready (which depends on
		# pathfinder.altitude_center(cell)) runs with the world transform
		# resolved.
		world.add_child(inst)
		inst.global_position = pathfinder.cell_to_world(inst.cell)


# Free any procedurally-spawned objects parented under `world`. Called after
# placement and before respawn so successive Regenerates don't stack.
# queue_free defers to end-of-frame; safe because Pathfinder.rebuild()
# between calls constructs a fresh TileGrid — old occupant claims live on
# the discarded grid and don't conflict with new claims on the new grid.
static func _clear_existing(world: Node2D) -> void:
	for child in world.get_children():
		if child.is_in_group(_GROUP_PROCEDURAL):
			child.queue_free()
