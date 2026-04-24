class_name Traversal
extends Node2D

# ============================================================================
# Traversal (base class)
# ============================================================================
#
# Shared base for player-built traversal structures (bridges, ladders, …).
# A Traversal is a thin logic/scene wrapper around a set of tiles painted on
# the shared Structures TileMapLayers via StructurePlacer. The tiles are the
# actual walkable geometry — the Traversal node holds no collision of its own
# and exists mainly to: (a) own the lifecycle of its painted cells, (b) expose
# a place for per-instance state (future: condition, animations, signals).
#
# Subclasses override `build()` to paint their tiles and must call `_record()`
# for every painted (cell, altitude) pair so `despawn()` can erase them later.
#
# ============================================================================


# Each element: { "cell": Vector2i, "altitude": int }
var _painted: Array[Dictionary] = []


func _record(cell: Vector2i, altitude: int) -> void:
	_painted.append({"cell": cell, "altitude": altitude})


# Subclasses must override and paint their tiles via `placer`. Returns true on
# success; false when the traversal couldn't be built (invalid geometry,
# missing layers, etc.), in which case the subclass is responsible for rolling
# back any partial paint state and the caller frees the node.
func build() -> bool:
	push_error("Traversal.build() must be overridden by subclass.")
	return false


# Erase every painted tile this traversal owns, then free.
# Caller is responsible for rebuilding the pathfinding grid afterwards.
func despawn(placer: StructurePlacer) -> void:
	for p in _painted:
		placer.erase(p["cell"], p["altitude"])
	_painted.clear()
	queue_free()


func painted_cells() -> Array[Dictionary]:
	return _painted.duplicate()
