class_name AltitudeFogController
extends Node

# ============================================================================
# AltitudeFogController
# ============================================================================
#
# Darkens TileMapLayers proportionally to the absolute altitude difference
# between each layer and the player. Layers at the player's current altitude
# stay at full brightness (white modulate); the further a layer is from the
# player vertically, the darker it gets, capped at `max_darkness`.
#
# The transition is smoothed via an exponential approach (frame-rate
# independent), so when the player crosses altitudes — including mid-step
# while climbing a ladder — the brightness gradient slides continuously.
#
# Discovers layers automatically by walking `world` for TileMapLayer
# descendants tagged with `meta/altitude`. Layers added at runtime (e.g. by
# StructureLayerManager) are picked up on the next frame via the
# `child_entered_tree` signal. Layers whose name starts with "Preview" are
# skipped — those have their own modulation logic (placement ghost tints).
#
# ============================================================================


@export var world: Node2D
@export var player: Player

@export_group("Darkening")
## Brightness reduction per altitude unit (half-step) of distance from the
## player. The default 0.025 means a 4-unit (2-cube) gap costs 0.10 brightness.
@export_range(0.0, 0.25, 0.005) var darkness_per_unit: float = 0.025
## Hard cap on brightness reduction. 0.5 = layers cap at 50% brightness no
## matter how far they are from the player.
@export_range(0.0, 1.0, 0.01) var max_darkness: float = 0.4

@export_group("Smoothing")
## Exponential approach rate for the brightness lerp. Higher = snappier.
## ~5 lands within ~0.5s of a target after the player crosses altitudes.
@export_range(0.5, 20.0, 0.5) var lerp_rate: float = 5.0


var _layers: Array[TileMapLayer] = []
var _layer_altitudes: Array[int] = []
var _current_brightness: Array[float] = []
var _rescan_queued: bool = false

# Convergence tracking. When the player altitude hasn't changed and every
# layer's brightness has settled within _CONVERGE_EPSILON of its target, we
# skip the per-layer modulate writes. Re-engages the moment the altitude
# moves or rescan() injects fresh layers.
const _CONVERGE_EPSILON: float = 0.001
var _last_alt: float = INF
var _converged: bool = false


func _ready() -> void:
	if player == null:
		player = get_tree().get_first_node_in_group(&"player") as Player
	if world != null:
		# child_entered_tree / child_exiting_tree fire once per node mutation.
		# `_queue_rescan` de-dupes within a single frame via `_rescan_queued`
		# (the deferred `rescan()` call clears the flag when it actually
		# runs), so a burst of N adds/removes in the same frame collapses to
		# one rescan. Cross-frame topology changes intentionally trigger
		# separate rescans because they reflect real layer-set changes the
		# fog needs to react to (e.g. StructureLayerManager spawning a new
		# preview layer mid-game).
		world.child_entered_tree.connect(_on_world_child_entered)
		world.child_exiting_tree.connect(_on_world_child_exiting)
	# Defer the initial scan so sibling _ready calls (LayerConfigurator,
	# StructureLayerManager) finish populating altitude metadata first.
	_queue_rescan()


func _process(delta: float) -> void:
	if player == null or _layers.is_empty():
		return
	var alt: float = player.current_altitude()
	if alt != _last_alt:
		_converged = false
		_last_alt = alt
	if _converged:
		return
	var k: float = 1.0 - exp(-lerp_rate * delta)
	var all_settled: bool = true
	for i in _layers.size():
		var layer: TileMapLayer = _layers[i]
		if layer == null:
			continue
		var target: float = _target_brightness(alt, _layer_altitudes[i])
		var b: float = lerpf(_current_brightness[i], target, k)
		if absf(b - target) > _CONVERGE_EPSILON:
			all_settled = false
		_current_brightness[i] = b
		var c: Color = layer.modulate
		layer.modulate = Color(b, b, b, c.a)
	_converged = all_settled


# Public: force a re-scan of `world`. Call after any code path that adds or
# removes altitude-tagged TileMapLayers without going through the normal
# child_entered_tree path on `world`.
func rescan() -> void:
	_rescan_queued = false
	var found: Array[TileMapLayer] = []
	var alts: Array[int] = []
	if world != null:
		_collect(world, found, alts)

	# Preserve in-progress brightness for layers we already track so the
	# lerp doesn't pop when a new layer joins partway through a transition.
	var prev: Dictionary = {}
	for i in _layers.size():
		if _layers[i] != null:
			prev[_layers[i]] = _current_brightness[i]

	_layers = found
	_layer_altitudes = alts
	_current_brightness.resize(found.size())
	# Fresh layers may not be at their target yet; resume the lerp loop.
	_converged = false

	var alt: float = player.current_altitude() if player != null else 0.0
	for i in found.size():
		var layer: TileMapLayer = found[i]
		if prev.has(layer):
			_current_brightness[i] = prev[layer]
		else:
			# Newly tracked layer: seed at the target value so it doesn't
			# fade in from full brightness on first frame.
			var target: float = _target_brightness(alt, alts[i])
			_current_brightness[i] = target
			var c: Color = layer.modulate
			layer.modulate = Color(target, target, target, c.a)


func _queue_rescan() -> void:
	if _rescan_queued:
		return
	_rescan_queued = true
	rescan.call_deferred()


func _collect(node: Node, out_layers: Array[TileMapLayer], out_alts: Array[int]) -> void:
	for child in node.get_children():
		if child is TileMapLayer and child.has_meta("altitude") \
				and not String(child.name).begins_with("Preview"):
			out_layers.append(child)
			out_alts.append(int(child.get_meta("altitude")))
		_collect(child, out_layers, out_alts)


func _on_world_child_entered(_n: Node) -> void:
	_queue_rescan()


func _on_world_child_exiting(_n: Node) -> void:
	_queue_rescan()


func _target_brightness(player_alt: float, layer_alt: int) -> float:
	var d: float = absf(player_alt - float(layer_alt))
	var darkness: float = minf(max_darkness, d * darkness_per_unit)
	return 1.0 - darkness
