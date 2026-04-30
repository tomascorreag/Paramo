@tool
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

# Editor-only previews. Driven by inspector toggles, independent of the runtime
# Debug autoload (which doesn't run in @tool context). Drawn in _draw() when
# Engine.is_editor_hint() is true. Reads tile_map_layers off `pathfinder` (its
# exported array is readable without the script running, since @tool isn't
# required to inspect another node's exported property).
@export var editor_show_tile_indices: bool = false:
	set(value):
		editor_show_tile_indices = value
		if Engine.is_editor_hint():
			queue_redraw()
@export var editor_show_tile_altitudes: bool = false:
	set(value):
		editor_show_tile_altitudes = value
		if Engine.is_editor_hint():
			queue_redraw()

# Visual tweakables (kept as exports for quick calibration in the editor).
@export var walkable_dot_radius: float = 1.5
@export var walkable_dot_color: Color = Color(0.3, 1.0, 0.4, 0.9)
@export var hover_dot_radius: float = 4.0
@export var hover_dot_color: Color = Color(1.0, 0.9, 0.2, 0.95)
@export var cell_outline_color: Color = Color(1.0, 0.9, 0.2, 0.7)
@export var index_font_size: int = 6
@export var index_color: Color = Color(1.0, 1.0, 1.0, 0.95)
@export var index_shadow_color: Color = Color(0.0, 0.0, 0.0, 0.9)


var _hover_cell: Vector2i = Pathfinder.NO_CELL
var _index_font: Font


func _ready() -> void:
	_index_font = ThemeDB.fallback_font
	# Make sure we draw on top of tile layers.
	z_index = 100
	z_as_relative = false
	if Engine.is_editor_hint():
		return
	if pathfinder == null:
		pathfinder = get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	if pathfinder == null:
		push_error("TileDebugOverlay: no Pathfinder wired and none found in group '%s'." % Pathfinder.GROUP_NAME)
	Debug.tile_indices_changed.connect(_on_tile_indices_changed)
	Debug.tile_altitudes_changed.connect(_on_tile_indices_changed)


func _on_tile_indices_changed(_is_enabled: bool) -> void:
	queue_redraw()


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if enabled and pathfinder != null:
		var mouse_global := get_global_mouse_position()
		_hover_cell = pathfinder.resolve_click(mouse_global)
		queue_redraw()
	_update_label()


func _draw() -> void:
	if Engine.is_editor_hint():
		_draw_editor_overlay()
		return
	if pathfinder == null:
		return

	if Debug.show_tile_indices:
		_draw_tile_indices()
	if Debug.show_tile_altitudes:
		_draw_tile_altitudes()

	if not enabled:
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


func _draw_tile_indices() -> void:
	if _index_font == null:
		return
	var cells := _pathfinder_walkable_cells()
	for cell in cells:
		var text := "%d,%d" % [cell.x, cell.y]
		var size := _index_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, index_font_size)
		var center := to_local(_cell_visual_surface_global(cell))
		var pos := center - Vector2(size.x * 0.5, -size.y * 0.25)
		draw_string(_index_font, pos + Vector2(0.7, 0.7), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, index_font_size, index_shadow_color)
		draw_string(_index_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, index_font_size, index_color)


# Per-cell highest-visible-top (the value the shadow cutoff compares
# against). Iterates every cell in grid bounds — not just walkables — so
# non-walkable obstructions (walls, voids, decorative overlays) that may
# silently trigger the shadow cutoff get labeled at their visible top.
func _draw_tile_altitudes() -> void:
	if _index_font == null:
		return
	var g := pathfinder.grid()
	if g == null:
		return
	var b: Rect2i = g.bounds()
	for y in range(b.position.y, b.position.y + b.size.y):
		for x in range(b.position.x, b.position.x + b.size.x):
			var cell := Vector2i(x, y)
			var top: float = pathfinder.highest_visible_top(cell)
			if is_nan(top):
				continue  # No tile painted on any layer here.
			var text: String = "%d" % int(top)
			var size := _index_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, index_font_size)
			var center := to_local(_cell_visual_surface_global_at_top(cell, top))
			# Stack altitude above the coord line if both are visible; otherwise
			# center it on the cell.
			var y_off: float = -index_font_size * 0.55 if Debug.show_tile_indices else 0.0
			var pos := center - Vector2(size.x * 0.5, -size.y * 0.25 + y_off)
			draw_string(_index_font, pos + Vector2(0.7, 0.7), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, index_font_size, index_shadow_color)
			draw_string(_index_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, index_font_size, index_color)


# Editor-only preview: walks every painted cell on every wired TileMapLayer
# and labels it with "x,y" and/or its layer altitude. Bypasses Pathfinder/grid
# (neither builds in @tool context) and the runtime Debug autoload (likewise).
func _draw_editor_overlay() -> void:
	if _index_font == null:
		_index_font = ThemeDB.fallback_font
	if pathfinder == null:
		return
	if not (editor_show_tile_indices or editor_show_tile_altitudes):
		return
	for layer in pathfinder.tile_map_layers:
		if layer == null:
			continue
		var altitude: int = int(layer.get_meta(&"altitude", 0))
		for cell in layer.get_used_cells():
			var center := to_local(layer.to_global(layer.map_to_local(cell)))
			var lines: Array[String] = []
			if editor_show_tile_indices:
				lines.append("%d,%d" % [cell.x, cell.y])
			if editor_show_tile_altitudes:
				lines.append("a%d" % altitude)
			var line_h: float = float(index_font_size)
			var total_h: float = line_h * lines.size()
			for i in range(lines.size()):
				var text: String = lines[i]
				var size := _index_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, index_font_size)
				var pos := center - Vector2(size.x * 0.5, total_h * 0.5 - line_h * (i + 0.85))
				draw_string(_index_font, pos + Vector2(0.7, 0.7), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, index_font_size, index_shadow_color)
				draw_string(_index_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, index_font_size, index_color)


# Same as _cell_visual_surface_global, but uses an explicit visual_top
# (half-step units) instead of altitude_center, so non-walkable cells get
# labeled at their actual visible top without consulting merged metadata.
func _cell_visual_surface_global_at_top(cell: Vector2i, top: float) -> Vector2:
	var base := pathfinder.cell_to_world(cell)
	return base + Pathfinder.VISUAL_SURFACE_OFFSET + Vector2(0.0, -top * Pathfinder.HALF_STEP_PX)


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
	if not Debug.enabled and not enabled:
		debug_label.visible = false
		return
	debug_label.visible = true
	var fps: int = int(Engine.get_frames_per_second())
	var draws: int = int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var nodes: int = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var perf_str: String = "FPS: %d    draws: %d    nodes: %d" % [fps, draws, nodes]

	if not enabled or pathfinder == null or _hover_cell == Pathfinder.NO_CELL:
		debug_label.text = perf_str
		return
	var tile := pathfinder.get_tile(_hover_cell)
	if tile == null:
		debug_label.text = "%s\ncell: %s    kind: —    alt: —" % [perf_str, _hover_cell]
		return
	var top: float = pathfinder.highest_visible_top(_hover_cell)
	var top_str: String = "—" if is_nan(top) else "%d" % int(top)
	debug_label.text = "%s\ncell: %s    kind: %s    alt: %s    vt: %s" % [
		perf_str, _hover_cell, tile.tile_kind, tile.altitude_center, top_str
	]
