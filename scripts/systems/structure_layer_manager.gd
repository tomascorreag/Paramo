class_name StructureLayerManager
extends Node

# ============================================================================
# StructureLayerManager
# ============================================================================
#
# Spawns one "Structures<N>" TileMapLayer per altitude covered by the existing
# Ground layers (plus one above the highest) and registers them with the
# Pathfinder. Bridges and other traversal structures paint their tiles onto
# these layers via StructurePlacer; TileGrid already aggregates walkability
# across every registered layer, so pathfinding "just works" after rebuild.
#
# Scene-tree ordering: place this node AFTER the Pathfinder in the scene tree
# so its `_ready` runs after Pathfinder's initial `rebuild()`. We then append
# our layers and call `rebuild()` exactly once.
#
# The altitude range is [min(ground), max(ground) + 1] inclusive so bridges at
# the highest ground altitude still have a deck layer above them. The +1
# margin is the only reason odd altitudes get layers even though no Ground
# layer paints at odd altitudes today.
#
# ============================================================================


const GROUP_NAME: StringName = &"structure_layer_manager"


@export var pathfinder: Pathfinder
@export var world: Node2D
@export var structures_tileset: TileSet
@export var structures_source_id: int = 1  # WoodIsoTiles
@export_range(0.0, 1.0, 0.05) var preview_alpha: float = 0.5


var _by_altitude: Dictionary[int, TileMapLayer] = {}
var _preview_by_altitude: Dictionary[int, TileMapLayer] = {}
var _flash_tween: Tween
var _flashing: bool = false


func _enter_tree() -> void:
	add_to_group(GROUP_NAME)


func _ready() -> void:
	if pathfinder == null:
		pathfinder = get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	if pathfinder == null:
		push_error("StructureLayerManager: no Pathfinder found; structures layers not spawned.")
		return
	if world == null:
		push_error("StructureLayerManager: `world` export not set; aborting.")
		return
	if structures_tileset == null:
		push_error("StructureLayerManager: `structures_tileset` export not set; aborting.")
		return

	var min_alt: int = 0
	var max_alt: int = 0
	var seen := false
	for layer in pathfinder.tile_map_layers:
		if layer == null:
			continue
		if not layer.has_meta("altitude"):
			continue
		var a: int = layer.get_meta("altitude", 0)
		if not seen:
			min_alt = a
			max_alt = a
			seen = true
		else:
			min_alt = mini(min_alt, a)
			max_alt = maxi(max_alt, a)

	if not seen:
		push_warning("StructureLayerManager: no Ground layers with altitude meta found; skipping.")
		return

	# +1 margin so a bridge at the highest ground altitude still has a deck
	# layer above it.
	for alt in range(min_alt, max_alt + 2):
		_spawn(alt)

	pathfinder.rebuild()


func _spawn(alt: int) -> void:
	var layer := TileMapLayer.new()
	layer.name = "Structures%s" % _alt_suffix(alt)
	layer.tile_set = structures_tileset
	layer.y_sort_enabled = true
	layer.y_sort_origin = alt * int(Pathfinder.HALF_STEP_PX)
	layer.position = Vector2(0.0, -alt * Pathfinder.HALF_STEP_PX)
	layer.set_meta("altitude", alt)
	world.add_child(layer)

	_by_altitude[alt] = layer
	pathfinder.tile_map_layers.append(layer)

	# Parallel preview layer — visual-only ghost target for placement previews.
	# Not registered with the pathfinder so painted tiles don't affect walkability.
	var preview := TileMapLayer.new()
	preview.name = "PreviewStructures%s" % _alt_suffix(alt)
	preview.tile_set = structures_tileset
	preview.y_sort_enabled = true
	preview.y_sort_origin = alt * int(Pathfinder.HALF_STEP_PX)
	preview.position = Vector2(0.0, -alt * Pathfinder.HALF_STEP_PX)
	preview.set_meta("altitude", alt)
	preview.modulate = Color(1.0, 1.0, 1.0, preview_alpha)
	world.add_child(preview)

	_preview_by_altitude[alt] = preview


static func _alt_suffix(alt: int) -> String:
	# Godot node names can't contain "-"; use "N" (negative) prefix for clarity.
	if alt < 0:
		return "N%d" % (-alt)
	return "%d" % alt


# ----------------------------------------------------------------------------
# Public queries
# ----------------------------------------------------------------------------

func layer_for_altitude(alt: int) -> TileMapLayer:
	return _by_altitude.get(alt, null)


func preview_layer_for_altitude(alt: int) -> TileMapLayer:
	return _preview_by_altitude.get(alt, null)


# ----------------------------------------------------------------------------
# Preview tint / flash
# ----------------------------------------------------------------------------

# Tint presets (alpha is filled in from `preview_alpha` at call time so
# resizing the export in-editor still works).
func _tint_valid() -> Color:
	return Color(1.0, 1.0, 1.0, preview_alpha)


func _tint_invalid() -> Color:
	return Color(1.4, 0.4, 0.4, preview_alpha)


func _tint_invalid_peak() -> Color:
	return Color(2.4, 0.2, 0.2, minf(1.0, preview_alpha + 0.4))


# Apply a tint preset to every preview layer. No-op during a running flash so
# a concurrent animation isn't clobbered mid-interp.
func set_preview_valid() -> void:
	_apply_tint(_tint_valid())


func set_preview_invalid() -> void:
	_apply_tint(_tint_invalid())


# Force-reset the preview tint, killing any running flash. Call when leaving
# placement mode so stale invalid-tint doesn't bleed into the next session.
func reset_preview_tint() -> void:
	_kill_flash_tween()
	_apply_tint_direct(_tint_valid())


func _apply_tint(c: Color) -> void:
	if _flashing:
		return
	_apply_tint_direct(c)


# Brief red-brighten-then-back animation on all preview layers. Used to signal
# an invalid click while the player is aiming a traversal.
func flash_invalid() -> void:
	if _preview_by_altitude.is_empty():
		return
	_kill_flash_tween()
	_flashing = true
	_flash_tween = get_tree().create_tween()
	_flash_tween.tween_method(_apply_tint_direct, _tint_invalid(), _tint_invalid_peak(), 0.08)
	_flash_tween.tween_method(_apply_tint_direct, _tint_invalid_peak(), _tint_invalid(), 0.18)
	_flash_tween.finished.connect(_on_flash_finished)


func _apply_tint_direct(c: Color) -> void:
	for layer in _preview_by_altitude.values():
		layer.modulate = c


func _on_flash_finished() -> void:
	_flashing = false


func _kill_flash_tween() -> void:
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	_flash_tween = null
	_flashing = false


func has_layer(alt: int) -> bool:
	return _by_altitude.has(alt)


func known_altitudes() -> Array[int]:
	var out: Array[int] = []
	for a in _by_altitude.keys():
		out.append(a)
	out.sort()
	return out
