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
# a place for per-instance state (future: condition, animations, signals),
# (c) register itself as the cell occupant on TileGrid so other systems can
# query "what's at this cell" through one path.
#
# Subclasses override `build()` to paint their tiles and must call `_record()`
# for every painted (cell, altitude) pair so `despawn()` can erase them later.
# After painting (and any pathfinder rebuild), call `_register_with_grid()`
# so the Traversal claims its occupied cells on TileGrid.
#
# Occupancy semantics: traversals are walkable (blocks_movement = false) —
# they exist precisely TO add walkability. The occupant registration is for
# uniqueness / placement collision (so two structures don't both root on the
# same cell), not for movement blocking. Subclasses set occupant_kind() so
# downstream code can filter by kind (occupants_of_kind(&"bridge_deck")).
#
# ============================================================================


# Each element: { "cell": Vector2i, "altitude": int }
var _painted: Array[Dictionary] = []

# Set true once _register_with_grid has connected to graph_changed. Avoids
# double-connecting if a subclass calls register more than once.
var _grid_signal_connected: bool = false


func _record(cell: Vector2i, altitude: int) -> void:
	_painted.append({"cell": cell, "altitude": altitude})


# Subclasses must override and paint their tiles via `placer`. Returns true on
# success; false when the traversal couldn't be built (invalid geometry,
# missing layers, etc.), in which case the subclass is responsible for rolling
# back any partial paint state and the caller frees the node.
func build() -> bool:
	push_error("Traversal.build() must be overridden by subclass.")
	return false


# Erase every painted tile this traversal owns, clear the occupant claims on
# TileGrid, then free. Caller is responsible for rebuilding the pathfinding
# grid afterwards.
func despawn(placer: StructurePlacer) -> void:
	_clear_grid_occupants()
	for p in _painted:
		placer.erase(p["cell"], p["altitude"])
	_painted.clear()
	queue_free()


func painted_cells() -> Array[Dictionary]:
	return _painted.duplicate()


# True iff `cell` is one this traversal considers itself to stand on for the
# purposes of "can the player remove me without being stranded?". Default:
# any painted cell. Subclasses override when a cell is a functional part of
# the traversal but isn't painted (e.g. Ladder.top_cell).
func occupies_cell(cell: Vector2i) -> bool:
	for entry in _painted:
		if entry["cell"] == cell:
			return true
	return false


# Cells this traversal CLAIMS as occupant on TileGrid. Default: every painted
# cell. Ladder overrides to also include top_cell — a ladder hangs on a wall
# but pathfinding treats top_cell as a functional endpoint, and other
# placement systems must see it as occupied to prevent stacking.
func occupied_cells() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for entry in _painted:
		out.append(entry["cell"])
	return out


# --- Occupant registration (TileGrid integration) --------------------------

# Subclasses (and their override-of-build) call this AFTER any pathfinder
# rebuild that landed them on a fresh TileGrid. Registers the structure as
# occupant on every cell from `occupied_cells()` and connects to
# Pathfinder.graph_changed so future rebuilds re-register automatically.
func _register_with_grid() -> void:
	var pf := _get_pathfinder()
	if pf == null:
		return
	var grid: TileGrid = pf.grid()
	if grid == null:
		return
	for cell in occupied_cells():
		grid.set_occupant(cell, self)
	if not _grid_signal_connected:
		if not pf.graph_changed.is_connected(_on_graph_changed):
			pf.graph_changed.connect(_on_graph_changed)
		_grid_signal_connected = true


func _clear_grid_occupants() -> void:
	var pf := _get_pathfinder()
	if pf == null:
		return
	var grid: TileGrid = pf.grid()
	if grid == null:
		return
	for cell in occupied_cells():
		grid.clear_occupant(cell, self)


# graph_changed fires on rebuild and on traversal-edge changes. The new grid
# (post-rebuild) has no occupants, so we re-register every claim. Idempotent
# when the grid already has us — set_occupant returns true silently.
func _on_graph_changed() -> void:
	if not is_inside_tree():
		return
	var pf := _get_pathfinder()
	if pf == null:
		return
	var grid: TileGrid = pf.grid()
	if grid == null:
		return
	for cell in occupied_cells():
		grid.set_occupant(cell, self)


func _get_pathfinder() -> Pathfinder:
	return get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder


# --- Occupant interface (duck-typed by TileGrid / Pathfinder) --------------

func occupant_kind() -> StringName:
	return &""


func blocks_movement() -> bool:
	return false


func walk_penalty() -> float:
	return 0.0
