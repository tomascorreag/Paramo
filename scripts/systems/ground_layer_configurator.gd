@tool
class_name GroundLayerConfigurator
extends Node

# ============================================================================
# ground_layer_configurator.gd — editor-only helper
# ============================================================================
#
# Writes the four altitude-derived properties on every listed TileMapLayer:
#   y_sort_enabled = true
#   y_sort_origin  = altitude * altitude_unit_px
#   position.y     = -altitude * altitude_unit_px
#   meta/altitude  = altitude
#
# Never creates, deletes, or re-parents nodes — only edits properties of the
# layers you drag into the `layers` array. The `altitudes` array is kept
# index-aligned with `layers` via a setter on `layers` (growing `altitudes`
# is automatic; new slots default to 0 until you fill them in).
#
# ---------------------------------------------------------------------------
# Basic usage (editor only, game need not run):
#   1. Add this node anywhere in a map scene.
#   2. Drag TileMapLayers into `layers` in the inspector.
#   3. Fill per-row altitude in `altitudes`.
#   4. Click "Apply" to write the derived properties back to every layer.
#   5. Save the scene.
#
# ---------------------------------------------------------------------------
# Adding a new ground layer (e.g. `Ground5`):
#   1. In the scene tree, right-click `World` → Add Child Node → TileMapLayer.
#      Name it `GroundN` following the existing sequence.
#   2. Assign its `tile_set` to the same TileSet used by the other grounds
#      (e.g. `res://resources/tiles/base_tileset.tres`).
#   3. Paint tiles on it as usual. Do NOT manually set y_sort_enabled,
#      y_sort_origin, position, or meta/altitude — Apply will write all four.
#   4. Select this `LayerConfigurator`. In the `layers` array, click the `+`
#      to add a slot and drag the new TileMapLayer in.
#   5. In `altitudes`, enter the integer altitude for that slot.
#   6. Click Apply. Save the scene.
#   7. Add the new layer to any other system that tracks the ground stack —
#      most importantly `Pathfinder.tile_map_layers` on the same scene — so
#      pathfinding and altitude lookups include it.
#
# ---------------------------------------------------------------------------
# Removing a ground layer:
#   1. Delete the TileMapLayer node from the scene tree.
#   2. Remove its (now-null) slot from `layers` AND the matching index from
#      `altitudes`. They must stay index-aligned.
#   3. Remove it from `Pathfinder.tile_map_layers` as well.
#   No Apply needed — there's nothing left to write to.
#
# ---------------------------------------------------------------------------
# Re-ordering layers:
#   Order within the arrays has no effect on the written properties — each
#   (layer, altitude) pair is independent. Order them however is readable
#   (typically lowest altitude first). If you reorder `layers`, reorder the
#   corresponding entries in `altitudes` to keep indices aligned.
#
# ---------------------------------------------------------------------------
# Altitude convention:
#   - `altitude` is an integer step, not a pixel value. The pixel offset per
#     step is `altitude_unit_px` (default 8, under the Advanced group).
#   - `altitude = 0` is the ground-level baseline. Negative altitudes sit
#     below it (basins, rivers), positive altitudes stack upward.
#   - Steps do NOT have to be contiguous. `[-2, 0, 1, 2, 4, 6]` is fine —
#     gaps just mean no layer at that tier in this scene.
#   - Downstream readers (`Pathfinder.layer_altitude()`, `CellData`, entity
#     interpolators) all read `meta/altitude` back, so whatever you write
#     here becomes the single source of truth for that layer.
#
# ---------------------------------------------------------------------------
# What NOT to put in `layers`:
#   - Non-ground TileMapLayers you don't want position-shifted (e.g. an
#     overlay that must stay at y=0 regardless of altitude).
#   - Child TileMapLayers that inherit transforms from a shifted parent
#     (their absolute position would double-shift).
#   - The type is `Array[TileMapLayer]`; the editor will refuse other node
#     types, but a null slot is silently skipped by Apply.
#
# ============================================================================


@export var layers: Array[TileMapLayer] = []:
	set(value):
		layers = value
		altitudes.resize(layers.size())

@export var altitudes: Array[int] = []

@export_tool_button("Apply") var apply_action := _apply

@export_group("Advanced")
## Pixel offset per altitude step. Ground tiles are drawn with a ~8 px
## vertical shift per altitude tier in Paramo's isometric art.
@export var altitude_unit_px: int = 8


func _apply() -> void:
	if layers.size() != altitudes.size():
		push_warning("layers (%d) and altitudes (%d) differ in size; aborting." % [layers.size(), altitudes.size()])
		return
	var applied := 0
	for i in layers.size():
		var layer := layers[i]
		if layer == null:
			continue
		var alt: int = altitudes[i]
		layer.y_sort_enabled = true
		layer.y_sort_origin = alt * altitude_unit_px
		layer.position.y = -alt * altitude_unit_px
		layer.set_meta("altitude", alt)
		applied += 1
	print("GroundLayerConfigurator: applied to %d layers." % applied)
