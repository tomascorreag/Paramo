class_name TileGrid
extends RefCounted

# ============================================================================
# TileGrid
# ============================================================================
#
# Collapsed replacement for the prior TileTopology + ElevationGrid split. One
# class that:
#
#   1. Owns the SHAPE lookup table (tile_kind -> rise direction / ramp size).
#   2. Reads altitude from each TileMapLayer's "altitude" metadata (int,
#      half-steps). All tiles on a layer share the layer's altitude.
#   3. Builds the per-cell state (a 2D CellData array) by scanning a set of
#      TileMapLayers.
#   4. Answers walkability, altitude, and transition queries for pathfinding.
#
# ----------------------------------------------------------------------------
# Storage: 2D CellData array
# ----------------------------------------------------------------------------
#
# Cells are held in `_tiles: Array[Array[CellData]]` sized to the union of all
# TileMapLayer used_rects, with the origin offset stored in `_bounds`. Cells
# with no tile on any layer are `null` slots.
#
# Assumption: no new cell positions are added at runtime — only the contents
# of existing cells change (health, moisture, biodiversity, occupancy). The
# TileMap footprint is the whole playfield. If that assumption breaks, call
# rebuild() with the expanded layer set.
#
# Mutating per-cell runtime fields: `get_tile(cell)` returns the live
# CellData; change fields on it in place (RefCounted, shared instance).
#
# ----------------------------------------------------------------------------
# Altitude unit
# ----------------------------------------------------------------------------
#
# Altitudes are INTEGER half-steps. One half-step = 8 screen pixels.
# A FULL_CUBE step = 2 half-steps. A HALF_CUBE step = 1 half-step.
#
# For ramps, the layer's altitude is the LOW end. The HIGH end is derived as
# `low + ramp_size` where `ramp_size` comes from the shape table (full
# slope/stair = 2, half slope/stair = 1). Paint ramps on their LOW-end layer.
#
# ----------------------------------------------------------------------------
# Stair convention (LOCKED — lower layer, positive deltas)
# ----------------------------------------------------------------------------
#
# Paint the stair where its FEET land. A STAIR_NE on a layer with altitude 0
# bridges altitude 0 (low end) to altitude 2 (high end). The stair ART is
# calibrated so its low end sits at the altitude-0 walkable surface line and
# its high end visually reaches the altitude-2 line.
#
# ----------------------------------------------------------------------------
# Column stacking rule
# ----------------------------------------------------------------------------
#
# Multiple layers can contribute tiles to the same (x, y) cell. When they do,
# the HIGHEST-altitude walkable tile wins — you stand on the tallest stack.
# A non-walkable tile (WALL_*) at or above the tallest walkable tile blocks
# the column.
#
# Cells with no tile on any layer aren't tracked: `is_walkable()` returns
# false for them, `can_transition()` rejects edges into them.
#
# ============================================================================


const _TILE_KIND_FIELD: String = "tile_kind"
const _ALTITUDE_META: String = "altitude"


# --- Shape table: pure rise semantics, no altitude math --------------------
#
# Each entry: { ramp_size: int (0 for flats), rise: Vector2i (ZERO for flats) }
# Shapes NOT in this dict are treated as non-walkable (WALL_*, EDGE_*,
# decorative tiles).
const _RISE_NE: Vector2i = Vector2i( 0, -1)
const _RISE_NW: Vector2i = Vector2i(-1,  0)
const _RISE_SE: Vector2i = Vector2i( 1,  0)
const _RISE_SW: Vector2i = Vector2i( 0,  1)

const _SHAPES: Dictionary = {
	# --- Flats (sit flush on their layer's altitude) -----------------------
	&"FLAT":            {"ramp_size": 0, "rise": Vector2i.ZERO},
	&"FULL_CUBE":       {"ramp_size": 0, "rise": Vector2i.ZERO},
	&"HALF_CUBE":       {"ramp_size": 0, "rise": Vector2i.ZERO},

	# --- Full-height ramps (low -> low + 2) --------------------------------
	&"SLOPE_NE":        {"ramp_size": 2, "rise": _RISE_NE},
	&"SLOPE_NW":        {"ramp_size": 2, "rise": _RISE_NW},
	&"SLOPE_SE":        {"ramp_size": 2, "rise": _RISE_SE},
	&"SLOPE_SW":        {"ramp_size": 2, "rise": _RISE_SW},

	&"STAIR_NE":        {"ramp_size": 2, "rise": _RISE_NE},
	&"STAIR_NW":        {"ramp_size": 2, "rise": _RISE_NW},
	&"STAIR_SE":        {"ramp_size": 2, "rise": _RISE_SE},
	&"STAIR_SW":        {"ramp_size": 2, "rise": _RISE_SW},

	# --- Half-height ramps (low -> low + 1) --------------------------------
	&"HALF_SLOPE_NE":   {"ramp_size": 1, "rise": _RISE_NE},
	&"HALF_SLOPE_NW":   {"ramp_size": 1, "rise": _RISE_NW},
	&"HALF_SLOPE_SE":   {"ramp_size": 1, "rise": _RISE_SE},
	&"HALF_SLOPE_SW":   {"ramp_size": 1, "rise": _RISE_SW},

	&"HALF_STAIR_NE":   {"ramp_size": 1, "rise": _RISE_NE},
	&"HALF_STAIR_NW":   {"ramp_size": 1, "rise": _RISE_NW},
	&"HALF_STAIR_SE":   {"ramp_size": 1, "rise": _RISE_SE},
	&"HALF_STAIR_SW":   {"ramp_size": 1, "rise": _RISE_SW},

	# Non-walkable (implicitly excluded from this dict):
	#   WALL_NW, WALL_NE, WALL_SE, WALL_SW, EDGE_*
}


# Half-height ramps (ramp_size == 1). Pathfinding treats these as permissive
# on their perpendicular edges: a neighbor at `low` can step on/off from the
# two sides perpendicular to the rise (in addition to the rise-axis low end),
# and likewise a neighbor at `high` can use the perpendicular sides. Full
# ramps (ramp_size == 2) remain strictly axis-locked.
const _HALF_RAMPS: Dictionary = {
	&"HALF_SLOPE_NE": true, &"HALF_SLOPE_NW": true,
	&"HALF_SLOPE_SE": true, &"HALF_SLOPE_SW": true,
	&"HALF_STAIR_NE": true, &"HALF_STAIR_NW": true,
	&"HALF_STAIR_SE": true, &"HALF_STAIR_SW": true,
}


# Union of all layer used_rects, computed in build(). The 2D array indexes
# off `_bounds.position` so a cell `c` maps to `_tiles[c.y - _bounds.position.y][c.x - _bounds.position.x]`.
var _bounds: Rect2i = Rect2i(0, 0, 0, 0)

# 2D grid of cell state. `_tiles[y_idx][x_idx]` is a CellData or null (no tile
# painted at that cell on any layer).
var _tiles: Array[Array] = []  # Array[Array[CellData]] — typed inner arrays

# Layers in paint order as provided to build().
var _layers: Array[TileMapLayer] = []

# Layer altitudes cached at build time, keyed by layer reference.
var _layer_altitudes: Dictionary[TileMapLayer, int] = {}

# Unique layer altitudes sorted descending — used by resolve_click.
var _altitudes_desc: Array[int] = []


# ----------------------------------------------------------------------------
# Build
# ----------------------------------------------------------------------------

func build(layers: Array[TileMapLayer]) -> void:
	_layers.clear()
	_layer_altitudes.clear()
	_altitudes_desc.clear()
	_tiles.clear()
	_bounds = Rect2i(0, 0, 0, 0)

	var alt_set: Dictionary[int, bool] = {}
	var valid_layers: Array[TileMapLayer] = []

	for layer in layers:
		if layer == null:
			push_warning("TileGrid: null TileMapLayer in input; skipping.")
			continue
		if layer.tile_set == null:
			push_warning("TileGrid: layer '%s' has no TileSet; skipping." % layer.name)
			continue

		if not layer.has_meta(_ALTITUDE_META):
			push_warning(
				"TileGrid: layer '%s' missing '%s' meta — defaulting to 0. "
				% [layer.name, _ALTITUDE_META]
				+ "Set it in the inspector's Metadata section."
			)

		var alt: int = layer.get_meta(_ALTITUDE_META, 0)
		_layers.append(layer)
		_layer_altitudes[layer] = alt
		alt_set[alt] = true
		valid_layers.append(layer)

	# Cache sorted altitude list for resolve_click.
	for a in alt_set.keys():
		_altitudes_desc.append(a)
	_altitudes_desc.sort()
	_altitudes_desc.reverse()

	# Compute bounds as the union of every layer's used_rect. Empty bounds
	# stays as (0,0,0,0) — queries return null / false.
	_bounds = _compute_bounds_union(valid_layers)
	if _bounds.size.x > 0 and _bounds.size.y > 0:
		_allocate_tiles(_bounds.size)

	for layer in _layers:
		_ingest_layer(layer)


func _compute_bounds_union(layers: Array[TileMapLayer]) -> Rect2i:
	var has_any := false
	var result := Rect2i()
	for layer in layers:
		var r := layer.get_used_rect()
		if r.size.x <= 0 or r.size.y <= 0:
			continue
		if not has_any:
			result = r
			has_any = true
		else:
			result = result.merge(r)
	return result


func _allocate_tiles(size: Vector2i) -> void:
	_tiles.resize(size.y)
	for y in size.y:
		var row: Array[CellData] = []
		row.resize(size.x)  # fills with null
		_tiles[y] = row


func _ingest_layer(layer: TileMapLayer) -> void:
	var tile_set := layer.tile_set
	var kind_layer_id := _find_custom_data_layer(tile_set, _TILE_KIND_FIELD)
	if kind_layer_id < 0:
		push_error(
			"TileGrid: layer '%s' TileSet has no '%s' custom data layer."
			% [layer.name, _TILE_KIND_FIELD]
		)
		return

	var altitude_low: int = _layer_altitudes.get(layer, 0)

	for cell in layer.get_used_cells():
		var data := layer.get_cell_tile_data(cell)
		if data == null:
			continue

		var kind_raw: Variant = data.get_custom_data_by_layer_id(kind_layer_id)
		var kind_str: String = ""
		if kind_raw is String:
			kind_str = kind_raw as String

		if kind_str.is_empty():
			_merge_blocked(cell, layer, altitude_low)
			continue

		var kind := StringName(kind_str)
		if not _SHAPES.has(kind):
			_merge_blocked(cell, layer, altitude_low)
			continue

		var shape: Dictionary = _SHAPES[kind]
		var ramp_size: int = shape["ramp_size"]
		var rise_dir: Vector2i = shape["rise"]
		var altitude_high: int = altitude_low + ramp_size
		var entry := CellData.make_walkable(layer, kind, rise_dir, altitude_low, altitude_high)
		_merge_walkable(cell, entry)


# Merge a walkable tile into `cell`'s slot using the "tallest wins" rule.
func _merge_walkable(cell: Vector2i, entry: CellData) -> void:
	var existing := _get_raw(cell)
	if existing == null:
		_put_raw(cell, entry)
		return

	if not existing.walkable:
		if existing.altitude_low >= entry.altitude_high:
			return
		_put_raw(cell, entry)
		return

	if entry.altitude_high > existing.altitude_high:
		_put_raw(cell, entry)
	elif entry.altitude_high == existing.altitude_high:
		push_warning(
			"TileGrid: cell %s has two walkable tiles at altitude_high=%d; keeping first."
			% [cell, existing.altitude_high]
		)


func _merge_blocked(cell: Vector2i, layer: TileMapLayer, altitude: int) -> void:
	var existing := _get_raw(cell)
	if existing == null:
		_put_raw(cell, CellData.make_blocked(layer, altitude))
		return

	if not existing.walkable:
		if altitude > existing.altitude_low:
			_put_raw(cell, CellData.make_blocked(layer, altitude))
		return

	if altitude >= existing.altitude_high:
		_put_raw(cell, CellData.make_blocked(layer, altitude))


# Raw 2D-array write. Caller must have ensured `cell` is in bounds. Used only
# internally by merge logic during build.
func _put_raw(cell: Vector2i, data: CellData) -> void:
	var dx := cell.x - _bounds.position.x
	var dy := cell.y - _bounds.position.y
	if dx < 0 or dy < 0 or dx >= _bounds.size.x or dy >= _bounds.size.y:
		push_error("TileGrid: cell %s out of bounds %s — skipping." % [cell, _bounds])
		return
	_tiles[dy][dx] = data


# Raw 2D-array read. Returns null when the cell is out of bounds OR when no
# tile exists at that cell on any layer.
func _get_raw(cell: Vector2i) -> CellData:
	if _bounds.size.x <= 0 or _bounds.size.y <= 0:
		return null
	var dx := cell.x - _bounds.position.x
	var dy := cell.y - _bounds.position.y
	if dx < 0 or dy < 0 or dx >= _bounds.size.x or dy >= _bounds.size.y:
		return null
	return _tiles[dy][dx]


# ----------------------------------------------------------------------------
# Public queries
# ----------------------------------------------------------------------------

func is_walkable(cell: Vector2i) -> bool:
	var t := _get_raw(cell)
	return t != null and t.walkable


func altitude_center(cell: Vector2i) -> float:
	var t := _get_raw(cell)
	if t == null:
		return 0.0
	return t.altitude_center


## Live CellData for `cell`, or null when out of bounds / unpainted.
## Callers can mutate runtime fields (health, moisture, biodiversity) on the
## returned instance — it's the grid's stored reference.
func get_tile(cell: Vector2i) -> CellData:
	return _get_raw(cell)


func in_bounds(cell: Vector2i) -> bool:
	return _bounds.has_point(cell)


func bounds() -> Rect2i:
	return _bounds


# Returns the ramp size (in half-steps) for this cell:
#   0 for flats, unknown cells, or non-walkable cells
#   1 for half-height ramps (HALF_SLOPE_*, HALF_STAIR_*)
#   2 for full-height ramps (SLOPE_*, STAIR_*)
func ramp_size(cell: Vector2i) -> int:
	var t := _get_raw(cell)
	if t == null:
		return 0
	return t.altitude_high - t.altitude_low


func layer_of(cell: Vector2i) -> TileMapLayer:
	var t := _get_raw(cell)
	if t == null:
		return null
	return t.layer


# Roughness of the winning tile at `cell` (from the "roughness" custom_data
# layer on the tileset). 0.0 when: the cell has no tile, no tile_data, the
# tileset lacks the "roughness" layer, or the value is unset.
#
# Used by shadow shaders to scale vertical-displacement noise. Float custom
# data defaults to 0.0 for unset tiles, so adding the layer to a tileset is
# safe without immediately authoring every tile.
func roughness_at(cell: Vector2i) -> float:
	var t := _get_raw(cell)
	if t == null or t.layer == null:
		return 0.0
	var data := t.layer.get_cell_tile_data(cell)
	if data == null:
		return 0.0
	var tile_set := t.layer.tile_set
	var rough_id := _find_custom_data_layer(tile_set, "roughness")
	if rough_id < 0:
		return 0.0
	var v: Variant = data.get_custom_data_by_layer_id(rough_id)
	if v is float:
		return v
	if v is int:
		return float(v)
	return 0.0


func layers() -> Array[TileMapLayer]:
	return _layers.duplicate()


func layer_altitude(layer: TileMapLayer) -> int:
	return _layer_altitudes.get(layer, 0)


func altitudes_desc() -> Array[int]:
	return _altitudes_desc


func walkable_cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if _bounds.size.x <= 0 or _bounds.size.y <= 0:
		return out
	for y in _bounds.size.y:
		var row: Array = _tiles[y]
		for x in _bounds.size.x:
			var t: CellData = row[x]
			if t != null and t.walkable:
				out.append(Vector2i(x + _bounds.position.x, y + _bounds.position.y))
	return out


# Altitude at the edge of `cell` facing `dir` (half-steps, int).
# For flats: exit == enter == altitude_low (== altitude_high).
# For ramps: depends on whether dir matches the rise direction.
func exit_altitude(cell: Vector2i, dir: Vector2i) -> int:
	var t := _get_raw(cell)
	if t == null or not t.walkable:
		return -9999
	if t.rise_dir == Vector2i.ZERO:
		return t.altitude_low
	if dir == t.rise_dir:
		return t.altitude_high
	if dir == -t.rise_dir:
		return t.altitude_low
	return -9999  # perpendicular exit — forbidden


# Altitude at the edge of `cell` when entered from step direction `from_dir`.
# `from_dir` is the step vector (to - from) that brought the agent into cell.
func enter_altitude(cell: Vector2i, from_dir: Vector2i) -> int:
	var t := _get_raw(cell)
	if t == null or not t.walkable:
		return -9999
	if t.rise_dir == Vector2i.ZERO:
		return t.altitude_low
	if from_dir == t.rise_dir:
		return t.altitude_low
	if from_dir == -t.rise_dir:
		return t.altitude_high
	return -9999


# True iff an agent can step from `from` to `to` along 4-connected axis.
func can_transition(from: Vector2i, to: Vector2i) -> bool:
	if not is_walkable(from) or not is_walkable(to):
		return false
	var dir: Vector2i = to - from
	if abs(dir.x) + abs(dir.y) != 1:
		return false

	var exit_alts := _edge_altitudes(from, dir)
	if exit_alts.is_empty():
		return false
	var enter_alts := _edge_altitudes(to, -dir)
	if enter_alts.is_empty():
		return false
	for a in exit_alts:
		if a in enter_alts:
			return true
	return false


# Valid altitudes at the `dir`-facing edge of `cell`. Empty means the edge is
# impassable (perpendicular exit off a full ramp, or non-walkable cell). For
# half-ramps, perpendicular edges expose BOTH low and high so neighbors on
# either altitude can step on/off from the sides.
#
# Using an outward-facing direction convention: for exits, pass the step dir;
# for entries, pass the negation of the step dir (the side the agent came
# from, seen from the destination cell).
func _edge_altitudes(cell: Vector2i, dir: Vector2i) -> Array[int]:
	var t := _get_raw(cell)
	if t == null or not t.walkable:
		return []
	if t.rise_dir == Vector2i.ZERO:
		return [t.altitude_low]
	if dir == t.rise_dir:
		return [t.altitude_high]
	if dir == -t.rise_dir:
		return [t.altitude_low]
	# Perpendicular edge: permissive for half-ramps only.
	if _HALF_RAMPS.has(t.tile_kind):
		return [t.altitude_low, t.altitude_high]
	return []


# ----------------------------------------------------------------------------
# Test-only injection
# ----------------------------------------------------------------------------

## TEST-ONLY. Unit tests that exercise primitive queries without going through
## build() inject cells via this helper. Grows `_bounds` and reallocates
## `_tiles` as needed so tests don't have to manage bounds themselves.
func _test_put(cell: Vector2i, data: CellData) -> void:
	if _bounds.size.x <= 0 or _bounds.size.y <= 0:
		_bounds = Rect2i(cell, Vector2i(1, 1))
		_allocate_tiles(_bounds.size)
	elif not _bounds.has_point(cell):
		_expand_bounds_to_include(cell)
	_put_raw(cell, data)


func _expand_bounds_to_include(cell: Vector2i) -> void:
	var new_min_x := mini(_bounds.position.x, cell.x)
	var new_min_y := mini(_bounds.position.y, cell.y)
	var new_max_x := maxi(_bounds.position.x + _bounds.size.x, cell.x + 1)
	var new_max_y := maxi(_bounds.position.y + _bounds.size.y, cell.y + 1)
	var new_bounds := Rect2i(
		Vector2i(new_min_x, new_min_y),
		Vector2i(new_max_x - new_min_x, new_max_y - new_min_y),
	)

	var new_tiles: Array[Array] = []
	new_tiles.resize(new_bounds.size.y)
	for y in new_bounds.size.y:
		var row: Array[CellData] = []
		row.resize(new_bounds.size.x)
		new_tiles[y] = row

	for y in _bounds.size.y:
		var old_row: Array = _tiles[y]
		var dst_y := y + (_bounds.position.y - new_bounds.position.y)
		var dst_row: Array = new_tiles[dst_y]
		var dst_x_off := _bounds.position.x - new_bounds.position.x
		for x in _bounds.size.x:
			dst_row[x + dst_x_off] = old_row[x]

	_bounds = new_bounds
	_tiles = new_tiles


# ----------------------------------------------------------------------------
# Internal helpers
# ----------------------------------------------------------------------------

static func _find_custom_data_layer(tile_set: TileSet, layer_name: String) -> int:
	var count := tile_set.get_custom_data_layers_count()
	for i in count:
		if tile_set.get_custom_data_layer_name(i) == layer_name:
			return i
	return -1
