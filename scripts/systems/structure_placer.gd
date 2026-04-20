class_name StructurePlacer
extends RefCounted

# ============================================================================
# StructurePlacer
# ============================================================================
#
# Thin helper that routes (cell, kind, altitude) paint calls to the correct
# Structures TileMapLayer spawned by StructureLayerManager. Callers (Bridge
# and other Traversal subclasses) batch their paints and rebuild the
# Pathfinder grid once at the end — this placer never rebuilds on its own.
#
# TileKindIndex is cached per-tileset so multiple Structures layers sharing
# one tileset share a single atlas scan.
#
# ============================================================================


var _slm: StructureLayerManager
var _source_id: int
var _preview: bool = false
var _index_by_tileset: Dictionary[TileSet, TileKindIndex] = {}


func _init(slm: StructureLayerManager, preview: bool = false) -> void:
	_slm = slm
	_preview = preview
	if slm != null:
		_source_id = slm.structures_source_id


func paint(cell: Vector2i, kind: StringName, target_altitude: int) -> bool:
	if _slm == null:
		push_warning("StructurePlacer.paint: no StructureLayerManager.")
		return false
	var layer := _resolve_layer(target_altitude)
	if layer == null:
		push_warning(
			"StructurePlacer.paint: no %s layer for altitude %d."
			% ["preview" if _preview else "Structures", target_altitude]
		)
		return false
	var idx := _index_for(layer.tile_set)
	if idx == null:
		return false
	var coord := idx.coord(kind)
	if TileKindIndex.is_unset(coord):
		push_warning(
			"StructurePlacer.paint: unknown tile kind '%s' on source %d."
			% [kind, _source_id]
		)
		return false
	layer.set_cell(cell, _source_id, coord)
	return true


func erase(cell: Vector2i, target_altitude: int) -> void:
	if _slm == null:
		return
	var layer := _resolve_layer(target_altitude)
	if layer == null:
		return
	layer.erase_cell(cell)


func layer_for(altitude: int) -> TileMapLayer:
	if _slm == null:
		return null
	return _resolve_layer(altitude)


func _resolve_layer(altitude: int) -> TileMapLayer:
	if _preview:
		return _slm.preview_layer_for_altitude(altitude)
	return _slm.layer_for_altitude(altitude)


func _index_for(tile_set: TileSet) -> TileKindIndex:
	if tile_set == null:
		return null
	if _index_by_tileset.has(tile_set):
		return _index_by_tileset[tile_set]
	var idx := TileKindIndex.new(tile_set, _source_id)
	_index_by_tileset[tile_set] = idx
	return idx
