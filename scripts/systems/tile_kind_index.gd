class_name TileKindIndex
extends RefCounted

# ============================================================================
# TileKindIndex
# ============================================================================
#
# Runtime lookup from slot name (TileSlots.FOO) to atlas coord (Vector2i) for
# a single biome source inside a TileSet. Built once by scanning the atlas
# source's tiles for the `tile_kind` custom data field. Replaces any manual
# hand-sync of atlas coordinates into the schema file.
#
# Usage:
#   var index := TileKindIndex.new(tile_set, TileSlots.BIOME_BASE_SOURCE_ID)
#   if index.has(TileSlots.FLAT):
#       ground_layer.set_cell(cell, src_id, index.coord(TileSlots.FLAT))
#
# Performance pattern — always CACHE the coord if you're going to place more
# than one tile of the same kind:
#   var flat_coord := index.coord(TileSlots.FLAT)
#   for cell in cells:
#       ground_layer.set_cell(cell, src_id, flat_coord)
#
# On construction, the index checks the atlas against TileSlots in ONE
# direction: a tile_kind in the atlas that isn't a declared TileSlots constant
# -> push_warning (typo in the editor's custom data field).
#
# The opposite direction — "a TileSlots constant with no painted tile here" —
# is NOT checked, because it cannot be decided from one source. TileSlots is the
# union of every slot across every biome/structure source, and each source
# paints a subset by design, so that check warned 257 times on a normal level1
# run (6 sources x every slot the other 5 own) and could never be made clean.
# An index that never went quiet was worth nothing as a signal and buried the
# warnings that do mean something. `index.has()` is the runtime answer to "is
# this slot on this source"; whether a slot is painted SOMEWHERE belongs to a
# test over the shipped tileset, not to a per-construction warning.
#
# Preconditions:
#   - The TileSet MUST have a custom data layer named "tile_kind" (String).
#     If missing, _init() pushes an error and the index stays empty.
#   - Each painted tile that should be addressable by name MUST have its
#     `tile_kind` custom data set to a String matching a TileSlots constant.
#   - Source id passed in MUST resolve to a TileSetAtlasSource (not a scene
#     collection source or other exotic source type).
#
# ============================================================================


const _TILE_KIND_FIELD: String = "tile_kind"
const _TILE_SLOTS_PATH: String = "res://scripts/data/tile_slots.gd"
const _UNSET: Vector2i = Vector2i(-1, -1)

var _source_id: int = -1
var _name_to_coord: Dictionary[StringName, Vector2i] = {}
var _name_to_all_coords: Dictionary[StringName, Array] = {}
var _coord_to_data: Dictionary[Vector2i, TileData] = {}
var _tile_set: TileSet = null
# custom-data layer name -> its id on _tile_set, or -1 for "no such layer".
# `get_attr` is called by name and would otherwise linear-scan the layer list on
# every call; GrassLadder asks twice per painted grass tile.
var _layer_id_cache: Dictionary[String, int] = {}


func _init(tile_set: TileSet, source_id: int) -> void:
	_source_id = source_id
	_tile_set = tile_set

	if tile_set == null:
		push_error("TileKindIndex: tile_set is null.")
		return

	var source := tile_set.get_source(source_id) as TileSetAtlasSource
	if source == null:
		push_error(
			"TileKindIndex: source %d in tile_set is not a TileSetAtlasSource."
			% source_id
		)
		return

	var kind_layer_id := _find_custom_data_layer(tile_set, _TILE_KIND_FIELD)
	if kind_layer_id < 0:
		push_error(
			"TileKindIndex: TileSet has no custom data layer named '%s'. "
			% _TILE_KIND_FIELD
			+ "Add it in the TileSet inspector under Custom Data Layers (type: String)."
		)
		return

	_scan_atlas(source, kind_layer_id)
	_validate_against_tile_slots()


# ----------------------------------------------------------------------------
# Public lookup
# ----------------------------------------------------------------------------

func coord(kind_name: StringName) -> Vector2i:
	return _name_to_coord.get(kind_name, _UNSET)


func has(kind_name: StringName) -> bool:
	return _name_to_coord.has(kind_name)


# All atlas coords with the given tile_kind on this source. Order matches the
# atlas-scan order (TileSetAtlasSource.get_tile_id index). Empty if unpainted.
func coords_for(kind_name: StringName) -> Array:
	return _name_to_all_coords.get(kind_name, [])


# Reads a custom_data field by layer name from the tile painted at `atlas_coord`
# on this source. Returns `null` if the coord is unknown to this index or the
# layer name doesn't exist on the TileSet.
func get_attr(atlas_coord: Vector2i, layer_name: String) -> Variant:
	var data: TileData = _coord_to_data.get(atlas_coord, null)
	if data == null:
		return null
	if _tile_set == null:
		return null
	var layer_id: int = _layer_id_cache.get(layer_name, -2)
	if layer_id == -2:
		# -1 (absent) is cached too, so a miss costs one scan, not one per call.
		layer_id = _find_custom_data_layer(_tile_set, layer_name)
		_layer_id_cache[layer_name] = layer_id
	if layer_id < 0:
		return null
	return data.get_custom_data_by_layer_id(layer_id)


func source_id() -> int:
	return _source_id


func all_painted_names() -> Array[StringName]:
	var out: Array[StringName] = []
	for k in _name_to_coord:
		out.append(k)
	return out


static func is_unset(c: Vector2i) -> bool:
	return c.x < 0 or c.y < 0


# ----------------------------------------------------------------------------
# Internal: atlas scan
# ----------------------------------------------------------------------------

func _scan_atlas(source: TileSetAtlasSource, kind_layer_id: int) -> void:
	var tile_count := source.get_tiles_count()
	for i in tile_count:
		var atlas_coord := source.get_tile_id(i)
		var data := source.get_tile_data(atlas_coord, 0)
		if data == null:
			continue

		var kind_value: Variant = data.get_custom_data_by_layer_id(kind_layer_id)
		if not (kind_value is String):
			continue
		var kind_str := kind_value as String
		if kind_str.is_empty():
			continue

		var kind_name := StringName(kind_str)
		_coord_to_data[atlas_coord] = data
		if not _name_to_all_coords.has(kind_name):
			_name_to_all_coords[kind_name] = []
		_name_to_all_coords[kind_name].append(atlas_coord)
		# First-painted coord wins for the single-coord lookup so legacy callers
		# (painter slope/flat resolution, pathfinder) keep their existing tile.
		if not _name_to_coord.has(kind_name):
			_name_to_coord[kind_name] = atlas_coord


# ----------------------------------------------------------------------------
# Internal: validate declared vs painted names
# ----------------------------------------------------------------------------

func _validate_against_tile_slots() -> void:
	var declared_names := _declared_slot_names()
	if declared_names.is_empty():
		return

	# Painted but undeclared: tile_kind strings in the atlas with no TileSlots
	# entry. The reverse direction is deliberately absent — see the header.
	for found in _name_to_coord:
		if not declared_names.has(found):
			push_warning(
				"TileKindIndex: tile_kind '%s' on source %d is not declared in TileSlots (typo?). "
				% [found, _source_id]
				+ "Add a const to TileSlots or fix the custom data value."
			)


# Every StringName constant on TileSlots, as a set. Reflected once per process,
# not once per index: the answer is the same for all six sources, and every
# TileKindIndex used to `load()` the script and walk its constant map again.
static var _declared_cache: Dictionary[StringName, bool] = {}
static var _declared_loaded: bool = false


static func _declared_slot_names() -> Dictionary[StringName, bool]:
	if _declared_loaded:
		return _declared_cache
	_declared_loaded = true
	var slots_script: Script = load(_TILE_SLOTS_PATH)
	if slots_script == null:
		push_error(
			"TileKindIndex: could not load TileSlots script at %s — skipping validation."
			% _TILE_SLOTS_PATH
		)
		return _declared_cache
	var constants: Dictionary = slots_script.get_script_constant_map()
	for const_name in constants:
		var const_value: Variant = constants[const_name]
		if const_value is StringName:
			_declared_cache[const_value as StringName] = true
	return _declared_cache


# ----------------------------------------------------------------------------
# Internal: locate custom data layer by name
# ----------------------------------------------------------------------------

static func _find_custom_data_layer(tile_set: TileSet, layer_name: String) -> int:
	var count := tile_set.get_custom_data_layers_count()
	for i in count:
		if tile_set.get_custom_data_layer_name(i) == layer_name:
			return i
	return -1
