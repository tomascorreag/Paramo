extends Node

# ============================================================================
# FireManager (autoload)
# ============================================================================
#
# Owns the wildfire simulation: ignition rolls on low-altitude grass tiles,
# per-burning-cell burn progression, spread to 4-neighbour grass tiles, and
# the grass→dirt swap on burn-out.
#
# Lazy resolution: the autoload is alive across the title screen and other
# non-gameplay scenes. It silently idles while no Pathfinder exists, picks
# one up the moment one enters the tree (via get_tree().node_added), and
# clears its state whenever Pathfinder.graph_changed fires (a map reload or
# rebuild starts the simulation over with a fresh grid).
#
# Tuning sits at the top of the file. Current preset: "aggressive" — frequent
# ignitions, fast burns, fast spread. Drop BASE_IGNITION_RATE / SPREAD_RATE
# for a calmer slice.
#
# Public signal:
#   tile_burned(cell)   emitted after a cell completes its burn.
#
# ============================================================================


# --- Tuning ----------------------------------------------------------------

# Per-sample chance, before all multipliers. Combined with K_IGNITION_SAMPLES
# this becomes ~K * BASE expected new-fire attempts per tick.
const BASE_IGNITION_RATE_PER_SAMPLE: float = 0.04
const K_IGNITION_SAMPLES: int = 4 # per ignition tick
const IGNITION_TICK_SECONDS: float = 0.25

const BURN_RATE_PER_SECOND: float = 0.10 # ~10s for a full burn
const SPREAD_RATE_PER_NEIGHBOUR_PER_SECOND: float = 0.1
const SPREAD_THRESHOLD: float = 0.25 # only spread once the source is well established

const WATER_SEARCH_R: int = 6 # max bounded BFS radius (cells)
const ALTITUDE_FALLOFF_SCALE: float = 4.0 # exp(-alt / scale)
const DAY_SIGMA: float = 0.18 # day-curve gaussian width

const MAX_CONCURRENT_BURNING: int = 80 # safety cap

# --- Rain coupling ---
# Spread chance hits zero at this rain intensity. Linear ramp from 0 (no rain
# = full spread) to RAIN_SPREAD_ZERO_AT (spread = 0).
const RAIN_SPREAD_ZERO_AT: float = 0.5
# Above this intensity, burning cells start rolling for extinguish each tick.
const RAIN_EXTINGUISH_THRESHOLD: float = 0.5
# Per-second extinguish chance at rain=1.0. Scales linearly between the
# threshold and 1.0.
const RAIN_EXTINGUISH_RATE_PER_SECOND: float = 0.8

const DAY_NIGHT_GROUP: StringName = &"day_night_controller"

# Source IDs in base_tileset.tres — kept in sync with TerrainPainter.
const SOURCE_GRASS: int = 0
const SOURCE_WATER: int = 3
const SOURCE_DIRT: int = 2

const _NEIGHBOR_DIRS: Array[Vector2i] = [
	Vector2i(1, 0),
	Vector2i(-1, 0),
	Vector2i(0, 1),
	Vector2i(0, -1),
]

const VFX_CONTAINER_GROUP: StringName = &"vfx_container"


# --- Signals ---------------------------------------------------------------

signal tile_burned(cell: Vector2i)


# --- State -----------------------------------------------------------------

var _pathfinder: Node = null # Pathfinder (typed loosely to avoid autoload class_name pin)
var _grid: Object = null # TileGrid
var _vfx_container: Node2D = null
var _time_manager: Node = null
var _day_night: Node = null # DayNightSceneController, for rain query

# cell -> { "vfx": BurningCellVFX, "amount": float, "frailejon": Node2D (or null) }
var _burning: Dictionary = {}

var _water_dist_cache: Dictionary[Vector2i, int] = {}

# Per-TileSet TileKindIndex for the dirt source. Built lazily on first
# ignition; cleared on graph_changed when a new map (and possibly a new
# TileSet) replaces the live grid.
var _dirt_index_by_tileset: Dictionary = {}

var _ignition_accum: float = 0.0


func _ready() -> void:
	_time_manager = get_node_or_null("/root/TimeManager")
	# Pathfinder may already exist (autoload loads after scene tree on instant
	# scene transitions) — try to grab one up front; otherwise we'll catch the
	# next one via node_added.
	_try_resolve_pathfinder()
	get_tree().node_added.connect(_on_node_added)


func _on_node_added(n: Node) -> void:
	if _pathfinder != null and is_instance_valid(_pathfinder):
		return
	# A Pathfinder joins its group in _enter_tree before this hook runs.
	if n.is_in_group(&"pathfinder"):
		_attach_to_pathfinder(n)


func _try_resolve_pathfinder() -> void:
	var pf := get_tree().get_first_node_in_group(&"pathfinder")
	if pf != null:
		_attach_to_pathfinder(pf)


func _attach_to_pathfinder(pf: Node) -> void:
	if _pathfinder == pf:
		return
	_pathfinder = pf
	if pf.has_signal(&"graph_changed") and not pf.graph_changed.is_connected(_on_graph_changed):
		pf.graph_changed.connect(_on_graph_changed)
	# Resolve grid lazily — Pathfinder builds in its _ready. Defer one frame.
	call_deferred(&"_refresh_grid_and_vfx")


func _refresh_grid_and_vfx() -> void:
	if _pathfinder == null or not is_instance_valid(_pathfinder):
		return
	if _pathfinder.has_method(&"grid"):
		_grid = _pathfinder.grid()
	_vfx_container = get_tree().get_first_node_in_group(VFX_CONTAINER_GROUP) as Node2D
	if _vfx_container == null:
		# Fall back to the Pathfinder's scene root — the user may not have
		# wired a VFXContainer on a custom map yet.
		_vfx_container = _pathfinder.get_parent() as Node2D
	_day_night = get_tree().get_first_node_in_group(DAY_NIGHT_GROUP)
	_water_dist_cache.clear()


func _on_graph_changed() -> void:
	# A new grid is in town. Burn-in-flight references go stale — wipe.
	for entry: Dictionary in _burning.values():
		var v: Node = entry.get("vfx") as Node
		if is_instance_valid(v):
			v.queue_free()
	_burning.clear()
	_water_dist_cache.clear()
	_dirt_index_by_tileset.clear()
	call_deferred(&"_refresh_grid_and_vfx")


# --- Per-frame loop --------------------------------------------------------

func _process(delta: float) -> void:
	if _grid == null:
		return

	var rain: float = _rain_intensity()
	_advance_burns(delta, rain)

	_ignition_accum += delta
	while _ignition_accum >= IGNITION_TICK_SECONDS:
		_ignition_accum -= IGNITION_TICK_SECONDS
		_roll_ignitions()


func _advance_burns(delta: float, rain: float) -> void:
	if _burning.is_empty():
		return
	# Cache rain-derived multipliers once per tick rather than per cell.
	var spread_mult: float = clampf(1.0 - rain / RAIN_SPREAD_ZERO_AT, 0.0, 1.0)
	var extinguish_p: float = 0.0
	if rain > RAIN_EXTINGUISH_THRESHOLD:
		var rain_excess: float = (rain - RAIN_EXTINGUISH_THRESHOLD) \
				/ maxf(1.0 - RAIN_EXTINGUISH_THRESHOLD, 0.0001)
		extinguish_p = clampf(rain_excess, 0.0, 1.0) \
				* RAIN_EXTINGUISH_RATE_PER_SECOND * delta

	var completed: Array[Vector2i] = []
	var extinguished: Array[Vector2i] = []
	# Snapshot keys so we can mutate _burning during spread.
	var cells: Array = _burning.keys()
	for cell: Vector2i in cells:
		var entry: Dictionary = _burning[cell]

		if extinguish_p > 0.0 and randf() < extinguish_p:
			extinguished.append(cell)
			continue

		var amount: float = float(entry.get("amount", 0.0))
		amount += BURN_RATE_PER_SECOND * delta
		entry["amount"] = amount

		var vfx: BurningCellVFX = entry.get("vfx") as BurningCellVFX
		if vfx != null and is_instance_valid(vfx):
			vfx.set_burn_amount(amount)

		var frj: Node = entry.get("frailejon") as Node
		if frj != null and is_instance_valid(frj) and frj.has_method(&"set_burn_amount"):
			frj.call(&"set_burn_amount", amount)

		if amount >= SPREAD_THRESHOLD and spread_mult > 0.0:
			_roll_spread(cell, delta, spread_mult)

		if amount >= 1.0:
			completed.append(cell)

	for cell: Vector2i in extinguished:
		_extinguish(cell)
	for cell: Vector2i in completed:
		_complete_burn(cell)


func _roll_spread(from_cell: Vector2i, delta: float, rain_mult: float) -> void:
	var p_per_neighbour: float = SPREAD_RATE_PER_NEIGHBOUR_PER_SECOND * delta * rain_mult
	if p_per_neighbour <= 0.0:
		return
	for d in _NEIGHBOR_DIRS:
		var nb: Vector2i = from_cell + d
		if _burning.has(nb):
			continue
		if not _is_grass(nb):
			continue
		if randf() < p_per_neighbour:
			_ignite(nb)


func _roll_ignitions() -> void:
	if _burning.size() >= MAX_CONCURRENT_BURNING:
		return
	if _grid == null:
		return
	var b: Rect2i = _grid.bounds()
	if b.size.x <= 0 or b.size.y <= 0:
		return
	var day_mult: float = _day_curve()
	# Cheap early-out: at deep midnight, day_mult is near zero — skip the sampling.
	if day_mult < 0.001:
		return
	for i in K_IGNITION_SAMPLES:
		var c := Vector2i(
			b.position.x + randi() % b.size.x,
			b.position.y + randi() % b.size.y,
		)
		if _burning.has(c):
			continue
		if not _is_grass(c):
			continue

		var alt_mult: float = _altitude_falloff(_grid.altitude_center(c))
		var water_mult: float = _water_falloff(c)
		var p: float = BASE_IGNITION_RATE_PER_SAMPLE * day_mult * alt_mult * water_mult
		if randf() < p:
			_ignite(c)
			if _burning.size() >= MAX_CONCURRENT_BURNING:
				return


# --- Ignition / completion -------------------------------------------------

func _ignite(cell: Vector2i) -> void:
	if _burning.has(cell):
		return
	var cd = _grid.get_tile(cell)
	if cd == null or cd.layer == null:
		return
	var layer: TileMapLayer = cd.layer
	var atlas_coords: Vector2i = layer.get_cell_atlas_coords(cell)
	var grass_src := layer.tile_set.get_source(SOURCE_GRASS) as TileSetAtlasSource
	if grass_src == null:
		return

	# Resolve the dirt atlas coord matching the grass tile's tile_kind. We
	# can't reuse the grass atlas coord directly: grass has multi-variant
	# tiles (e.g. FULL_CUBE at several coords) while dirt typically paints
	# only one coord per kind, so a blind set_cell with the grass coord
	# silently leaves the cell empty when dirt has no tile there.
	var dirt_coord: Vector2i = _resolve_dirt_coord(layer.tile_set, cd.tile_kind)
	if TileKindIndex.is_unset(dirt_coord):
		# Dirt source has no equivalent kind — fall back to FLAT, which every
		# painted biome source is expected to have. If even that's missing,
		# we skip the swap so the cell isn't left empty.
		dirt_coord = _resolve_dirt_coord(layer.tile_set, &"FLAT")

	# Swap underlying tile to dirt immediately. The BurningCellVFX overlay
	# holds the grass texture and dissolves it pixel-by-pixel — as alpha drops,
	# the freshly-painted dirt tile shows through.
	if not TileKindIndex.is_unset(dirt_coord):
		layer.set_cell(cell, SOURCE_DIRT, dirt_coord, 0)

	var vfx := BurningCellVFX.new()
	vfx.setup(cell, layer, grass_src, atlas_coords)
	# Parent under the source TileMapLayer so the layer's altitude lift +
	# y_sort_origin place us in the same frame as the burning tile. Flames then
	# y-sort correctly against tiles on every other layer.
	layer.add_child(vfx)

	var occ: Node2D = cd.occupant
	var frailejon: Node = null
	if occ != null and occ.has_method(&"apply_burn_material"):
		occ.call(&"apply_burn_material")
		frailejon = occ

	_burning[cell] = {
		"vfx": vfx,
		"amount": 0.0,
		"frailejon": frailejon,
		# Cached for the extinguish-restore path: re-paint these on the source
		# layer to undo the ignition-time grass→dirt swap.
		"grass_coord": atlas_coords,
		"grass_layer": layer,
	}


func _extinguish(cell: Vector2i) -> void:
	# Rain put the fire out before it burned through. Roll the cell back to its
	# pre-ignition state: re-paint grass on the source layer, clear the
	# frailejon's burn material, and despawn the VFX. No tile_burned signal —
	# nothing actually finished burning. Assumes no other system has mutated
	# this cell since ignition (true today; FireManager is the only writer).
	var entry: Dictionary = _burning.get(cell, {})
	if entry.is_empty():
		return

	var vfx: Node = entry.get("vfx") as Node
	if is_instance_valid(vfx):
		vfx.queue_free()

	var grass_layer: TileMapLayer = entry.get("grass_layer") as TileMapLayer
	var grass_coord: Vector2i = entry.get("grass_coord", Vector2i(-1, -1))
	if grass_layer != null and grass_coord.x >= 0:
		grass_layer.set_cell(cell, SOURCE_GRASS, grass_coord, 0)

	var frj: Node = entry.get("frailejon") as Node
	if is_instance_valid(frj) and frj.has_method(&"clear_burn_material"):
		frj.call(&"clear_burn_material")

	_burning.erase(cell)


func _complete_burn(cell: Vector2i) -> void:
	var entry: Dictionary = _burning.get(cell, {})
	if entry.is_empty():
		return

	var vfx: Node = entry.get("vfx") as Node
	if is_instance_valid(vfx):
		vfx.queue_free()

	var frj: Node = entry.get("frailejon") as Node
	if is_instance_valid(frj):
		frj.queue_free()

	_burning.erase(cell)
	tile_burned.emit(cell)


# --- Probability terms -----------------------------------------------------

func _rain_intensity() -> float:
	if _day_night != null and is_instance_valid(_day_night) \
			and _day_night.has_method(&"get_rain_current_intensity"):
		return float(_day_night.call(&"get_rain_current_intensity"))
	return 0.0


func _day_curve() -> float:
	if _time_manager == null:
		return 1.0
	var t: float = float(_time_manager.time_of_day)
	var dx: float = (t - 0.5) / DAY_SIGMA
	return exp(-dx * dx)


func _altitude_falloff(alt: float) -> float:
	# Smooth falloff: ~1.0 at altitude 0, ~exp(-3) ≈ 0.05 at altitude 12.
	return clampf(exp(-maxf(alt, 0.0) / ALTITUDE_FALLOFF_SCALE), 0.0, 1.0)


func _water_falloff(cell: Vector2i) -> float:
	var d: int = _distance_to_water(cell)
	if d <= 0:
		return 0.0
	if d >= WATER_SEARCH_R:
		return 1.0
	# Smooth ramp from 0 at d=1 to ~1.0 at d=WATER_SEARCH_R.
	return clampf(float(d) / float(WATER_SEARCH_R), 0.0, 1.0)


# --- Tile classification ---------------------------------------------------

func _is_grass(cell: Vector2i) -> bool:
	if _grid == null:
		return false
	var cd = _grid.get_tile(cell)
	if cd == null or cd.layer == null:
		return false
	return cd.layer.get_cell_source_id(cell) == SOURCE_GRASS


func _is_water_layer(layer: TileMapLayer, cell: Vector2i) -> bool:
	if layer == null:
		return false
	return layer.get_cell_source_id(cell) == SOURCE_WATER


func _resolve_dirt_coord(tile_set: TileSet, kind: StringName) -> Vector2i:
	if tile_set == null:
		return Vector2i(-1, -1)
	var idx: TileKindIndex = _dirt_index_by_tileset.get(tile_set, null)
	if idx == null:
		idx = TileKindIndex.new(tile_set, SOURCE_DIRT)
		_dirt_index_by_tileset[tile_set] = idx
	return idx.coord(kind)


func _distance_to_water(cell: Vector2i) -> int:
	# Bounded BFS, memoised. Returns 0 if `cell` itself is water,
	# WATER_SEARCH_R if no water is found within the radius.
	if _water_dist_cache.has(cell):
		return _water_dist_cache[cell]

	var visited: Dictionary[Vector2i, bool] = {}
	var queue: Array = [[cell, 0]]
	var head: int = 0
	visited[cell] = true
	var result: int = WATER_SEARCH_R
	while head < queue.size():
		var entry: Array = queue[head]
		head += 1
		var c: Vector2i = entry[0]
		var d: int = entry[1]

		var cd = _grid.get_tile(c)
		if cd != null and cd.layer != null and _is_water_layer(cd.layer, c):
			result = d
			break

		if d >= WATER_SEARCH_R:
			continue
		for dir in _NEIGHBOR_DIRS:
			var n := c + dir
			if visited.has(n):
				continue
			visited[n] = true
			queue.append([n, d + 1])

	_water_dist_cache[cell] = result
	return result
