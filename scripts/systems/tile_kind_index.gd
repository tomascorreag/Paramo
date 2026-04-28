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
# On construction, the index validates both directions against TileSlots:
#   - a tile_kind in the atlas that isn't a declared TileSlots constant
#     -> push_warning (typo in the editor's custom data field)
#   - a TileSlots constant with no painted tile in the atlas
#     -> push_warning (unpainted slot; index.has() returns false)
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
	var layer_id := _find_custom_data_layer(_tile_set, layer_name)
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
	var slots_script: Script = load(_TILE_SLOTS_PATH)
	if slots_script == null:
		push_error(
			"TileKindIndex: could not load TileSlots script at %s — skipping validation."
			% _TILE_SLOTS_PATH
		)
		return

	var declared_names: Dictionary[StringName, bool] = {}
	var constants: Dictionary = slots_script.get_script_constant_map()
	for const_name in constants:
		var const_value: Variant = constants[const_name]
		if const_value is StringName:
			declared_names[const_value as StringName] = true

	# Declared but unpainted: slot names in TileSlots with no matching tile.
	for declared in declared_names:
		if not _name_to_coord.has(declared):
			push_warning(
				"TileKindIndex: slot '%s' declared in TileSlots but not painted on source %d. "
				% [declared, _source_id]
				+ "index.has() will return false; index.coord() returns (-1, -1)."
			)

	# Painted but undeclared: tile_kind strings in the atlas with no TileSlots entry.
	for found in _name_to_coord:
		if not declared_names.has(found):
			push_warning(
				"TileKindIndex: tile_kind '%s' on source %d is not declared in TileSlots (typo?). "
				% [found, _source_id]
				+ "Add a const to TileSlots or fix the custom data value."
			)


# ----------------------------------------------------------------------------
# Internal: locate custom data layer by name
# ----------------------------------------------------------------------------

static func _find_custom_data_layer(tile_set: TileSet, layer_name: String) -> int:
	var count := tile_set.get_custom_data_layers_count()
	for i in count:
		if tile_set.get_custom_data_layer_name(i) == layer_name:
			return i
	return -1
