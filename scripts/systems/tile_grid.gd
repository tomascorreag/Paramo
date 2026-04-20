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
#   3. Builds the per-cell state dict by scanning a set of TileMapLayers.
#   4. Answers walkability, altitude, and transition queries for pathfinding.
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


# Per-cell record. Dictionary for speed; all runtime state.
#
# Keys:
#   walkable:        bool
#   layer:           TileMapLayer (which layer contributed the winning tile)
#   tile_kind:       StringName
#   rise_dir:        Vector2i    (ZERO for flats)
#   altitude_low:    int         (half-steps; the layer's altitude meta)
#   altitude_high:   int         (half-steps; low + ramp_size)
#   altitude_center: float       (half-steps; (low + high) / 2.0)
var _cells: Dictionary[Vector2i, Dictionary] = {}

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
	_cells.clear()
	_layers.clear()
	_layer_altitudes.clear()
	_altitudes_desc.clear()

	var alt_set: Dictionary[int, bool] = {}

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

	# Cache sorted altitude list for resolve_click.
	for a in alt_set.keys():
		_altitudes_desc.append(a)
	_altitudes_desc.sort()
	_altitudes_desc.reverse()

	for layer in _layers:
		_ingest_layer(layer)


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
		var entry := {
			"walkable": true,
			"layer": layer,
			"tile_kind": kind,
			"rise_dir": rise_dir,
			"altitude_low": altitude_low,
			"altitude_high": altitude_high,
			"altitude_center": (altitude_low + altitude_high) / 2.0,
		}
		_merge_walkable(cell, entry)


# Merge a walkable tile into _cells[cell] using the "tallest wins" rule.
func _merge_walkable(cell: Vector2i, entry: Dictionary) -> void:
	if not _cells.has(cell):
		_cells[cell] = entry
		return

	var existing: Dictionary = _cells[cell]
	if not existing.get("walkable", false):
		var block_alt: int = existing.get("altitude_low", 0)
		if block_alt >= int(entry["altitude_high"]):
			return
		_cells[cell] = entry
		return

	var existing_high: int = existing.get("altitude_high", 0)
	var new_high: int = entry["altitude_high"]
	if new_high > existing_high:
		_cells[cell] = entry
	elif new_high == existing_high:
		push_warning(
			"TileGrid: cell %s has two walkable tiles at altitude_high=%d; keeping first."
			% [cell, existing_high]
		)


func _merge_blocked(cell: Vector2i, layer: TileMapLayer, altitude: int) -> void:
	if not _cells.has(cell):
		_cells[cell] = _make_blocked_entry(layer, altitude)
		return

	var existing: Dictionary = _cells[cell]
	if not existing.get("walkable", false):
		var cur_alt: int = existing.get("altitude_low", 0)
		if altitude > cur_alt:
			_cells[cell] = _make_blocked_entry(layer, altitude)
		return

	var existing_high: int = existing.get("altitude_high", 0)
	if altitude >= existing_high:
		_cells[cell] = _make_blocked_entry(layer, altitude)


func _make_blocked_entry(layer: TileMapLayer, altitude: int) -> Dictionary:
	return {
		"walkable": false,
		"layer": layer,
		"tile_kind": &"",
		"rise_dir": Vector2i.ZERO,
		"altitude_low": altitude,
		"altitude_high": altitude,
		"altitude_center": float(altitude),
	}


# ----------------------------------------------------------------------------
# Public queries
# ----------------------------------------------------------------------------

func is_walkable(cell: Vector2i) -> bool:
	var info: Dictionary = _cells.get(cell, {})
	return info.get("walkable", false)


func altitude_center(cell: Vector2i) -> float:
	var info: Dictionary = _cells.get(cell, {})
	return info.get("altitude_center", 0.0)


func cell_info(cell: Vector2i) -> Dictionary:
	return _cells.get(cell, {})


# Returns the ramp size (in half-steps) for this cell:
#   0 for flats, unknown cells, or non-walkable cells
#   1 for half-height ramps (HALF_SLOPE_*, HALF_STAIR_*)
#   2 for full-height ramps (SLOPE_*, STAIR_*)
func ramp_size(cell: Vector2i) -> int:
	var info: Dictionary = _cells.get(cell, {})
	if info.is_empty():
		return 0
	return info.altitude_high - info.altitude_low


func layer_of(cell: Vector2i) -> TileMapLayer:
	var info: Dictionary = _cells.get(cell, {})
	return info.get("layer", null)


# Roughness of the winning tile at `cell` (from the "roughness" custom_data
# layer on the tileset). 0.0 when: the cell has no tile, no tile_data, the
# tileset lacks the "roughness" layer, or the value is unset.
#
# Used by shadow shaders to scale vertical-displacement noise. Float custom
# data defaults to 0.0 for unset tiles, so adding the layer to a tileset is
# safe without immediately authoring every tile.
func roughness_at(cell: Vector2i) -> float:
	var info: Dictionary = _cells.get(cell, {})
	var layer: TileMapLayer = info.get("layer", null)
	if layer == null:
		return 0.0
	var data := layer.get_cell_tile_data(cell)
	if data == null:
		return 0.0
	var tile_set := layer.tile_set
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
	for cell in _cells:
		if _cells[cell].get("walkable", false):
			out.append(cell)
	return out


# Altitude at the edge of `cell` facing `dir` (half-steps, int).
# For flats: exit == enter == altitude_low (== altitude_high).
# For ramps: depends on whether dir matches the rise direction.
func exit_altitude(cell: Vector2i, dir: Vector2i) -> int:
	var info: Dictionary = _cells.get(cell, {})
	if not info.get("walkable", false):
		return -9999
	var rise: Vector2i = info.get("rise_dir", Vector2i.ZERO)
	var low: int = info.get("altitude_low", 0)
	var high: int = info.get("altitude_high", 0)
	if rise == Vector2i.ZERO:
		return low
	if dir == rise:
		return high
	if dir == -rise:
		return low
	return -9999  # perpendicular exit — forbidden


# Altitude at the edge of `cell` when entered from step direction `from_dir`.
# `from_dir` is the step vector (to - from) that brought the agent into cell.
func enter_altitude(cell: Vector2i, from_dir: Vector2i) -> int:
	var info: Dictionary = _cells.get(cell, {})
	if not info.get("walkable", false):
		return -9999
	var rise: Vector2i = info.get("rise_dir", Vector2i.ZERO)
	var low: int = info.get("altitude_low", 0)
	var high: int = info.get("altitude_high", 0)
	if rise == Vector2i.ZERO:
		return low
	if from_dir == rise:
		return low
	if from_dir == -rise:
		return high
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
	var info: Dictionary = _cells.get(cell, {})
	if not info.get("walkable", false):
		return []
	var rise: Vector2i = info.get("rise_dir", Vector2i.ZERO)
	var low: int = info.get("altitude_low", 0)
	var high: int = info.get("altitude_high", 0)
	if rise == Vector2i.ZERO:
		return [low]
	if dir == rise:
		return [high]
	if dir == -rise:
		return [low]
	# Perpendicular edge: permissive for half-ramps only.
	var kind: StringName = info.get("tile_kind", &"")
	if _HALF_RAMPS.has(kind):
		return [low, high]
	return []


# ----------------------------------------------------------------------------
# Internal helpers
# ----------------------------------------------------------------------------

static func _find_custom_data_layer(tile_set: TileSet, layer_name: String) -> int:
	var count := tile_set.get_custom_data_layers_count()
	for i in count:
		if tile_set.get_custom_data_layer_name(i) == layer_name:
			return i
	return -1
