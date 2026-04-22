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
# index-aligned with `layers` via a setter on `layers`.
#
# Usage (editor only, game need not run):
#   1. Add this node anywhere in a map scene.
#   2. Drag TileMapLayers into `layers` in the inspector.
#   3. Fill per-row altitude in `altitudes`, or click "Read Altitudes From
#      Metadata" to seed from existing meta/altitude values.
#   4. Click "Apply" to write the derived properties back to every layer.
#   5. Save the scene.
#
# ============================================================================


@export var layers: Array[TileMapLayer] = []:
	set(value):
		layers = value
		altitudes.resize(layers.size())

@export var altitudes: Array[int] = []

@export_tool_button("Apply") var apply_action := _apply
@export_tool_button("Read Altitudes From Metadata") var read_action := _read_from_metadata

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


func _read_from_metadata() -> void:
	altitudes.resize(layers.size())
	for i in layers.size():
		var layer := layers[i]
		if layer == null:
			altitudes[i] = 0
			continue
		altitudes[i] = int(layer.get_meta("altitude", 0))
	notify_property_list_changed()
	print("GroundLayerConfigurator: read altitudes %s" % [altitudes])
