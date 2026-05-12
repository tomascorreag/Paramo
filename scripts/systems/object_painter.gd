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
#      `TerrainCell.object_kind`. Called every Regenerate; non-deterministic
#      so each call produces a fresh scatter at the same terrain seed.
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
#   - Variant pick is non-deterministic per call (RandomNumberGenerator
#     .randomize), as is placement. Frailejones (player-placed, not in the
#     procedural group) are unaffected.
#
# ============================================================================


# Kind → WorldObjectData. Single source of truth for the kinds the painter
# knows how to procgen-place. Frailejones spawn procedurally for the natural
# baseline scatter; players can still plant more (the action layer reuses
# the same scene). Procgen instances join group `&"procedural_object"` and
# are cleared on Regenerate; player-planted ones aren't tagged and survive.
const _ROCK_DATA: WorldObjectData = preload("res://resources/objects/rock.tres")
const _ROCK_SNOW_DATA: WorldObjectData = preload("res://resources/objects/rock_snow.tres")
const _ROCK_MOSS_DATA: WorldObjectData = preload("res://resources/objects/rock_moss.tres")
const _FRAILEJON_DATA: WorldObjectData = preload("res://resources/objects/frailejon.tres")

const _DATA_BY_KIND: Dictionary = {
	&"rock": _ROCK_DATA,
	&"rock_snow": _ROCK_SNOW_DATA,
	&"rock_moss": _ROCK_MOSS_DATA,
	&"frailejon": _FRAILEJON_DATA,
}

# Kind → PackedScene. All boulder-shaped kinds share `rock.tscn` — the
# Sprite2D + shadow shader config is identical across rock / rock_snow /
# rock_moss; only the texture variants differ, and those come off the
# instance's `data` resource (overridden in the spawn loop). This dict lives
# here — not on WorldObjectData — to break the rock.tscn ↔ rock.tres
# load-time cycle.
const _ROCK_SCENE: PackedScene = preload("res://scenes/objects/rock.tscn")
const _FRAILEJON_SCENE: PackedScene = preload("res://scenes/tools/frailejon.tscn")

const _SCENE_BY_KIND: Dictionary = {
	&"rock": _ROCK_SCENE,
	&"rock_snow": _ROCK_SCENE,
	&"rock_moss": _ROCK_SCENE,
	&"frailejon": _FRAILEJON_SCENE,
}

const _GROUP_PROCEDURAL: StringName = &"procedural_object"

# Gaussian σ (in altitude half-steps) for the per-kind altitude preference
# applied during placement. Matches the tile painter's `_SIGMA_ALT` so an
# author who has internalized the variant-picker's altitude tuning gets the
# same falloff shape here. ~exp(-2) at 3 half-steps off, ~exp(-8) at 6.
const _SIGMA_ALT: float = 3.0


## Roll each registered kind's `density_by_biome` against every eligible cell
## and write the winner into `TerrainCell.object_kind`. Cells previously
## flagged are reset before rolling, so calling this twice on the same grid
## produces a fresh scatter rather than stacking flags.
##
## Eligible cells: `kind == GROUND` AND `ground_shape ∈ {FULL_CUBE, FLAT}`.
## When multiple kinds have non-zero density on the same biome, they're
## rolled in dictionary-key order — first hit wins.
##
## `rng` defaults to a freshly randomized RNG so successive calls yield
## different layouts. Pass an explicit RNG (e.g. seeded) if you need
## reproducibility (only the verify-invariants harness does today).
static func assign_object_kinds(grid: TerrainGrid, rng: RandomNumberGenerator = null) -> void:
	if grid == null:
		return
	if _DATA_BY_KIND.is_empty():
		return
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.randomize()

	# Distance-to-water field, computed once per call IF any registered plant
	# kind uses water_affinity > 0. Multi-source BFS over face-connected cells
	# is O(W * H) — much cheaper than a per-cell radius scan inside the
	# placement loop. Skipped entirely when no plant kind needs it, so adding
	# more plain (non-water-biased) plant kinds costs nothing.
	var water_dist: PackedInt32Array = PackedInt32Array()
	var need_water_dist: bool = false
	for kind in _DATA_BY_KIND.keys():
		var d_kind: WorldObjectData = _DATA_BY_KIND[kind]
		if d_kind is PlantObjectData and (d_kind as PlantObjectData).water_affinity > 0.0:
			need_water_dist = true
			break
	if need_water_dist:
		water_dist = _compute_water_distance(grid)

	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			c.object_kind = &""
			if c.kind != TerrainCell.Kind.GROUND:
				continue
			if c.ground_shape != TerrainCell.GroundShape.FULL_CUBE \
					and c.ground_shape != TerrainCell.GroundShape.FLAT:
				continue
			for kind in _DATA_BY_KIND.keys():
				var data: WorldObjectData = _DATA_BY_KIND[kind]
				var d: float = float(data.density_by_biome.get(c.biome, 0.0))
				if d <= 0.0:
					continue
				# Optional altitude preference. `preferred_altitude <= 0`
				# means "no preference" (matches the tile painter's pa
				# semantics): the term drops out and density is used flat.
				if data.preferred_altitude > 0:
					var ad: float = float(c.altitude - data.preferred_altitude)
					d *= exp(- (ad * ad) / (2.0 * _SIGMA_ALT * _SIGMA_ALT))
				# Plant-only water-proximity bias. Reads the precomputed
				# BFS field; dist == INT_MAX (no water on the grid) collapses
				# the term to 0, which is the correct degenerate behavior.
				if need_water_dist and data is PlantObjectData:
					var wa: float = (data as PlantObjectData).water_affinity
					if wa > 0.0:
						var dist: int = water_dist[y * grid.width + x]
						var fd: float = float(dist)
						d *= exp(-wa * fd * fd)
				if rng.randf() < d:
					c.object_kind = kind
					break


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
) -> void:
	if grid == null:
		push_error("ObjectPainter.paint: grid is null.")
		return
	if world == null:
		push_error("ObjectPainter.paint: world Node2D is null — wire it in the inspector.")
		return
	if pathfinder == null:
		push_error("ObjectPainter.paint: pathfinder is null.")
		return

	var rng := RandomNumberGenerator.new()
	rng.randomize()

	assign_object_kinds(grid, rng)
	_clear_existing(world)

	for y in grid.height:
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
