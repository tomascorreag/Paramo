class_name TileDebugOverlay
extends Node2D

# ============================================================================
# TileDebugOverlay
# ============================================================================
#
# Scene-level debug visualization for pathfinder / tile calibration. Does
# three things when enabled:
#
#   1. Draws a small colored dot at every walkable cell's LOGICAL walkable
#      surface position (cell_to_world + VISUAL_SURFACE_OFFSET +
#      altitude offset). This is what the pathfinder thinks the player's
#      feet should be planted at.
#
#   2. Highlights the currently hovered cell (resolved via
#      pathfinder.resolve_click(mouse_pos)) with a larger dot.
#
#   3. Drives a Label with hovered-cell info: coord, tile_kind, altitude.
#
# Usage:
#   - Add as a child of the test scene root, above your tile layers in the
#     tree so _draw() overlays on top.
#   - Drag the Pathfinder node into `pathfinder` (or leave blank to fall
#      back to group "pathfinder").
#   - Drag a Label into `debug_label` to see textual hover info (optional).
#   - Toggle `enabled` to switch the whole overlay on/off.
#
# The overlay uses _process to chase the cursor and call queue_redraw()
# every frame; cheap enough for a debug node.
#
# ============================================================================


@export var pathfinder: Pathfinder
@export var debug_label: Label
@export var enabled: bool = false

# Visual tweakables (kept as exports for quick calibration in the editor).
@export var walkable_dot_radius: float = 1.5
@export var walkable_dot_color: Color = Color(0.3, 1.0, 0.4, 0.9)
@export var hover_dot_radius: float = 4.0
@export var hover_dot_color: Color = Color(1.0, 0.9, 0.2, 0.95)
@export var cell_outline_color: Color = Color(1.0, 0.9, 0.2, 0.7)


var _hover_cell: Vector2i = Pathfinder.NO_CELL


func _ready() -> void:
	if pathfinder == null:
		pathfinder = get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	if pathfinder == null:
		push_error("TileDebugOverlay: no Pathfinder wired and none found in group '%s'." % Pathfinder.GROUP_NAME)
	# Make sure we draw on top of tile layers.
	z_index = 100
	z_as_relative = false


func _process(_delta: float) -> void:
	if not enabled or pathfinder == null:
		return

	var mouse_global := get_global_mouse_position()
	_hover_cell = pathfinder.resolve_click(mouse_global)
	_update_label()
	queue_redraw()


func _draw() -> void:
	if not enabled or pathfinder == null:
		return

	# All drawing is done in this node's LOCAL space. Compute positions in
	# global space, then convert via to_local().
	var cells := _pathfinder_walkable_cells()
	for cell in cells:
		var p := _cell_visual_surface_global(cell)
		draw_circle(to_local(p), walkable_dot_radius, walkable_dot_color)

	if _hover_cell != Pathfinder.NO_CELL:
		var hp := _cell_visual_surface_global(_hover_cell)
		draw_circle(to_local(hp), hover_dot_radius, hover_dot_color)


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

func _pathfinder_walkable_cells() -> Array[Vector2i]:
	var g := pathfinder.grid()
	if g == null:
		return []
	return g.walkable_cells()


# Global-space position of the logical walkable surface for a cell, matching
# exactly how Player.gd computes its own global_position.
func _cell_visual_surface_global(cell: Vector2i) -> Vector2:
	var base := pathfinder.cell_to_world(cell)
	var alt := pathfinder.altitude_center(cell)
	return base + Pathfinder.VISUAL_SURFACE_OFFSET + Vector2(0.0, -alt * Pathfinder.HALF_STEP_PX)


func _update_label() -> void:
	if debug_label == null:
		return
	if _hover_cell == Pathfinder.NO_CELL:
		debug_label.text = "cell: —    kind: —    alt: —"
		return
	var tile := pathfinder.get_tile(_hover_cell)
	if tile == null:
		debug_label.text = "cell: %s    kind: —    alt: —" % _hover_cell
		return
	debug_label.text = "cell: %s    kind: %s    alt: %s" % [_hover_cell, tile.tile_kind, tile.altitude_center]
