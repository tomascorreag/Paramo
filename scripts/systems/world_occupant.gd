class_name WorldOccupant
extends Node2D

# ============================================================================
# WorldOccupant
# ============================================================================
#
# Authoring base for Node2D scenes that register as cell occupants on
# TileGrid (frailejones, rocks, future fences/signage). Provides default
# implementations of the three methods TileGrid and Pathfinder duck-type
# against:
#
#   - occupant_kind()    StringName identifier; matches WorldObjectData.id
#   - blocks_movement()  consulted by TileGrid.is_walkable
#   - walk_penalty()     consulted by Pathfinder._cell_enter_cost
#
# Subclassing is OPTIONAL. TileGrid uses has_method() lookups, so any Node2D
# that exposes the same three methods with the same signatures works (used
# by Traversal subclasses, which keep their existing inheritance chain).
# Subclass when starting a fresh Node2D scene; expose the methods directly
# when bolting onto an existing class hierarchy.
#
# Lifecycle (subclass responsibility):
#   - Set `cell` before adding to the world.
#   - In _ready(): call _register_with_grid() once the Pathfinder grid exists.
#   - Connect to Pathfinder.graph_changed and re-register on every emission
#     (fresh rebuild() drops the previous grid's occupant assignments).
#   - In _exit_tree(): clear the registration so a stale node doesn't leave
#     a dangling Node2D reference on the grid.
#
# ============================================================================


@export var cell: Vector2i


func occupant_kind() -> StringName:
	return &""


func blocks_movement() -> bool:
	return false


func walk_penalty() -> float:
	return 0.0
