class_name SpawnFlash
extends Node2D

## The "something just happened here" flash.
##
##  - PLANTED / BUILT: the thing ARRIVES as a dithered gradient at its real
##    colours, travelling from the cell nearest the player to the furthest
##    (a fence run grows away from you, a ladder climbs), turns flat white the
##    moment it is whole, and the white fades off it. Timeline in
##    `placed_tween`; the gradient is the shader's `reveal_*` uniforms.
##  - DISCOVERED: the plant flares gold and settles, a plain fade both ways.
##    Timeline in `discovered_tween`.
##
## One shader include (assets/shaders/flash_common.gdshaderinc), two hosts:
##
##  - PLANTS carry the flash in their own material. A plant already has a
##    material on two CanvasItems (the sprite and the clump extras drawn in
##    Frailejon._draw), and that material sways per fragment, so an overlay
##    drawn without the sway would ghost against it. Frailejon duplicates its
##    sway material (or takes a plain flash.gdshader when the species has none)
##    for the length of the flash and restores the shared one after.
##
##  - STRUCTURES are tiles on a shared TileMapLayer, which has one material for
##    every cell and no way to hide one, so each painted cell gets a node of
##    THIS class under its layer: it ERASES the cell, draws the tile's atlas
##    region itself through the flash material, and REPAINTS the cell when the
##    tween ends (or on leaving the tree early). The first cut left the tile
##    painted and drew the flash over it, and a ladder that is already there
##    cannot arrive. Every node of one construction shares ONE material and
##    ONE tween, so the gradient runs across the whole thing. A pathfinder
##    rebuild while a cell is bare would drop an ingested tile (a bridge deck)
##    from the grid, so a graph change during the flash is answered with one
##    more rebuild after the repaint.
##
## Tweens are NODE-bound (host.create_tween), so they freeze with the world
## under the pause menu / journal instead of finishing behind it.

const SHADER: Shader = preload("res://assets/shaders/flash.gdshader")
## Every live structure overlay, so a tool can assert none outlives its tween.
const GROUP: StringName = &"spawn_flash"

## Built / planted: the brightest neutral in the palette.
const BUILD_COLOR: Color = Palette.TEXT
## Identified for the first time: the gold this project already uses for
## "look here" (the unread inspect glyph, hover borders).
const DISCOVER_COLOR: Color = Palette.ACCENT

## Arrival: a base plus a little per cell, so a long fence run takes visibly
## longer to grow than a single post but not proportionally so.
const REVEAL_BASE: float = 0.4
const REVEAL_PER_CELL: float = 0.08
## The white fading off the arrived thing.
const SETTLE: float = 0.9
## Discovery: gold fading on, a hold, gold fading off. Half the build's
## tempo, so re-reading a field note is a quicker gesture than building.
const RISE: float = 0.225
const HOLD: float = 0.05
const DISCOVER_SETTLE: float = 0.45
## How far in front of its own tile a structure overlay sorts, in pixels.
const SORT_EPS: float = 0.5


# ----------------------------------------------------------------------------
# Timelines (shared by the plant path and the overlay path)
# ----------------------------------------------------------------------------

## Tween on `host`: `mat` reveals its art from world point `from` to `to` over
## `cells` cells' worth of time, snaps to the flash colour, fades it off.
static func placed_tween(host: Node, mat: ShaderMaterial, from: Vector2, to: Vector2,
		cells: int = 1) -> Tween:
	if to.is_equal_approx(from):
		to = from + Vector2(0.0, 1.0)
	mat.set_shader_parameter(&"flash_color", BUILD_COLOR)
	mat.set_shader_parameter(&"flash_amount", 0.0)
	mat.set_shader_parameter(&"reveal_from", from)
	mat.set_shader_parameter(&"reveal_to", to)
	mat.set_shader_parameter(&"reveal_amount", 0.0)
	var tw := host.create_tween()
	tw.tween_property(mat, "shader_parameter/reveal_amount", 1.0, reveal_time(cells))
	tw.tween_callback(mat.set_shader_parameter.bind(&"flash_amount", 1.0))
	tw.tween_property(mat, "shader_parameter/flash_amount", 0.0, SETTLE)
	return tw


## Tween on `host` that fades `mat` to full gold, holds, and fades back.
static func discovered_tween(host: Node, mat: ShaderMaterial) -> Tween:
	mat.set_shader_parameter(&"flash_color", DISCOVER_COLOR)
	mat.set_shader_parameter(&"flash_amount", 0.0)
	mat.set_shader_parameter(&"reveal_amount", 1.0)
	var tw := host.create_tween()
	tw.tween_property(mat, "shader_parameter/flash_amount", 1.0, RISE)
	tw.tween_interval(HOLD)
	tw.tween_property(mat, "shader_parameter/flash_amount", 0.0, DISCOVER_SETTLE)
	return tw


static func reveal_time(cells: int) -> float:
	return REVEAL_BASE + REVEAL_PER_CELL * maxi(cells - 1, 0)


# ----------------------------------------------------------------------------
# Structure overlays
# ----------------------------------------------------------------------------

## Flash everything `traversals` painted as ONE construction growing away from
## `near_cell` (the cell the player built from). Reads the atlas coords back off
## the layers, so it needs no per-kind knowledge and shows the variant that
## actually landed — which is why a fence RUN is passed whole, after every
## fence is down: each fence's build turns its neighbours, and a cell an
## overlay has already taken over would be repainted under it.
static func flash_built(traversals: Array, placer: StructurePlacer, near_cell: Vector2i) -> void:
	if placer == null:
		return
	var entries: Array[Dictionary] = []
	for t in traversals:
		if not (t is Traversal):
			continue
		for p: Dictionary in (t as Traversal).painted_cells():
			var layer: TileMapLayer = placer.layer_for(int(p["altitude"]))
			if layer != null:
				entries.append({"layer": layer, "cell": p["cell"] as Vector2i})
	flash_layer_cells(entries, near_cell)


## Spawn one overlay per `{layer, cell}` entry, all on one material and one
## tween, revealing from the entry nearest `near_cell` to the one furthest.
## Returns the nodes (empty when nothing was paintable).
static func flash_layer_cells(entries: Array[Dictionary], near_cell: Vector2i) -> Array[SpawnFlash]:
	var nodes: Array[SpawnFlash] = []
	var worlds: Array[Vector2] = []
	var ranks: Array[float] = []
	for e: Dictionary in entries:
		var layer: TileMapLayer = e["layer"]
		var cell: Vector2i = e["cell"]
		if layer == null or layer.tile_set == null or not layer.is_inside_tree():
			continue
		var src_id: int = layer.get_cell_source_id(cell)
		if src_id < 0:
			continue
		var src := layer.tile_set.get_source(src_id) as TileSetAtlasSource
		if src == null or src.texture == null:
			continue
		var node := SpawnFlash.new()
		node._layer = layer
		node._cell = cell
		node._src = src
		node._src_id = src_id
		node._coords = layer.get_cell_atlas_coords(cell)
		nodes.append(node)
		var world: Vector2 = layer.to_global(layer.map_to_local(cell))
		worlds.append(world)
		# Nearest by cell distance; among a ladder's tiles on one cell, the
		# lowest on screen first, so the ladder climbs.
		var d: Vector2i = cell - near_cell
		ranks.append(float(maxi(absi(d.x), absi(d.y))) - world.y * 0.0001)
	if nodes.is_empty():
		return nodes

	var lo: int = 0
	var hi: int = 0
	for i in ranks.size():
		if ranks[i] < ranks[lo]:
			lo = i
		if ranks[i] > ranks[hi]:
			hi = i
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	for n: SpawnFlash in nodes:
		n.material = mat
		n._layer.add_child(n)
	# One tween for the group, on the first node; it finishes every node.
	var leader: SpawnFlash = nodes[0]
	var tw := placed_tween(leader, mat, worlds[lo], worlds[hi], nodes.size())
	tw.finished.connect(func() -> void:
		for n: SpawnFlash in nodes:
			if is_instance_valid(n):
				n._finish())
	return nodes


var _layer: TileMapLayer
var _cell: Vector2i
var _src: TileSetAtlasSource
var _src_id: int = -1
var _coords: Vector2i
var _restored: bool = false
## A Pathfinder rebuild happened while the cell was bare; see the header.
var _graph_changed_meanwhile: bool = false
var _pathfinder: Pathfinder
## Sorting: the node's y IS its y-sort key, and it must land just in front of
## where the tile sorts. A tile sorts at cell y + the LAYER's y_sort_origin +
## the TileData's y_sort_origin; a child node of the layer gets NEITHER
## (measured: at altitude 12 the layer's origin is 96 and an overlay at plain
## cell y sat 96 px behind its own tile, invisible at every smaller shift and
## fully visible from exactly +96 on). So the node takes both shifts plus a
## hair, and _draw subtracts them again so the art does not move.
var _sort_shift: float = 0.0


func _ready() -> void:
	if _layer == null or _src == null:
		queue_free()
		return
	# Same frame as the tile: the layer's altitude lift applies to us too. Its
	# y_sort_origin does NOT — see _sort_shift.
	add_to_group(GROUP)
	position = _layer.map_to_local(_cell)
	var td: TileData = _src.get_tile_data(_coords, 0)
	_sort_shift = float(_layer.y_sort_origin) + (float(td.y_sort_origin) if td != null else 0.0) + SORT_EPS
	position.y += _sort_shift
	# Take the picture over from the layer for the length of the flash.
	_layer.erase_cell(_cell)
	_pathfinder = get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	if _pathfinder != null:
		_pathfinder.graph_changed.connect(_on_graph_changed)


func _on_graph_changed() -> void:
	_graph_changed_meanwhile = true


func _finish() -> void:
	_restore_tile()
	queue_free()


# Also on the way out of the tree, so a scene change or an early free mid-flash
# never leaves a hole where a structure is.
func _exit_tree() -> void:
	_restore_tile()


func _restore_tile() -> void:
	if _restored:
		return
	_restored = true
	if _pathfinder != null and is_instance_valid(_pathfinder) \
			and _pathfinder.graph_changed.is_connected(_on_graph_changed):
		_pathfinder.graph_changed.disconnect(_on_graph_changed)
	if _layer == null or not is_instance_valid(_layer) or _src_id < 0:
		return
	# Only refill a cell that is still bare: something that painted it meanwhile
	# (a fence turning on a neighbour's build) knows better than our snapshot.
	if _layer.get_cell_source_id(_cell) == -1:
		_layer.set_cell(_cell, _src_id, _coords)
	if _graph_changed_meanwhile and _pathfinder != null and is_instance_valid(_pathfinder):
		_pathfinder.rebuild()


func _draw() -> void:
	if _src == null:
		return
	var region: Rect2 = _src.get_tile_texture_region(_coords)
	var tex_origin: Vector2i = Vector2i.ZERO
	var td: TileData = _src.get_tile_data(_coords, 0)
	if td != null:
		tex_origin = td.texture_origin
	# TileMapLayer's drawing rule, measured (scripts/tools/preview_spawn_flash.gd):
	# the region is centred on map_to_local(cell) and pushed by -texture_origin.
	# NOT BurningCellVFX's version, which adds half a tile on top of that.
	var at: Vector2 = -Vector2(tex_origin) - region.size * 0.5 - Vector2(0.0, _sort_shift)
	draw_texture_rect_region(_src.texture, Rect2(at, region.size), region)
