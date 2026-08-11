class_name GrassLadder
extends RefCounted

## Orders a grass source's tiles into per-species LADDERS of grass length, so a
## cell's appearance can follow its vegetation value continuously instead of
## snapping between "grass" and "dirt".
##
## ---------------------------------------------------------------------------
## What a ladder is
## ---------------------------------------------------------------------------
##
## The grass atlas paints the same cube several times at different grass
## LENGTHS, in two grass TYPES (a warm tone and a cool one). The warm ladder's
## top rung is the tall pale paja — the same grass left to grow out, not a
## species of its own, and the only rung whose tile is 1x3 rather than 1x2.
## Terrain generation already picks one of them per cell — see TerrainPainter's
## variant resolver, which weights by altitude, clumping and selection weight.
## That pick is the cell's MAXIMUM: paramo grass does not grow taller than the
## stand that belongs there.
##
## This class reads two custom_data fields off the atlas and groups the tiles:
##
##   grass_tone     which species/tone the tile belongs to (>= 1; 0 = opt out)
##   grass_length   how long the grass is, ascending (>= 1; 0 = opt out)
##
## Tiles sharing (tile_kind, grass_tone) form one ladder, sorted by length. A
## cell's rung index is where its GENERATED coord sits in that ladder, and
## degradation walks it down toward rung 0 while recovery walks it back up —
## never past the rung it was generated at, and never off its own ladder, which
## is what keeps the tone constant while the length moves.
##
## Both fields default to 0, which means "not laddered": a tile that opts out
## (every slope, wall and stair) reports a top rung of
## 0, and callers then behave exactly as they did before ladders existed — one
## grass appearance, swapped for dirt at the bare threshold.
##
## ---------------------------------------------------------------------------
## Why data and not a constant table
## ---------------------------------------------------------------------------
##
## Adding a length step, or a third tone, must stay a pure .tres edit — that is
## the project's data-driven rule and the reason the variant weights live on the
## atlas too. Nothing here names a coordinate.

const TONE_LAYER: String = "grass_tone"
const LENGTH_LAYER: String = "grass_length"

# "<kind>|<tone>" -> Array[Vector2i], ascending by grass_length.
var _rungs: Dictionary[String, Array] = {}
# coord -> its index within its own ladder.
var _rung_of: Dictionary[Vector2i, int] = {}
# coord -> the ladder key it belongs to.
var _key_of: Dictionary[Vector2i, String] = {}
# coord -> its authored grass_tone, for tools and tests that want to report
# which species a cell is wearing without re-reading the atlas.
var _tone_of: Dictionary[Vector2i, int] = {}


func _init(tile_set: TileSet, source_id: int) -> void:
	if tile_set == null:
		return
	# Reuse the canonical atlas scanner rather than walking the source again —
	# it already resolves tile_kind and reads custom data by layer NAME, so a
	# reordered custom_data layer list cannot silently shift what is read here.
	var idx := TileKindIndex.new(tile_set, source_id)
	var by_key: Dictionary[String, Array] = {}
	for kind: StringName in idx.all_painted_names():
		for coord: Vector2i in idx.coords_for(kind):
			var tone: int = _int_attr(idx, coord, TONE_LAYER)
			var length: int = _int_attr(idx, coord, LENGTH_LAYER)
			if tone <= 0 or length <= 0:
				continue
			var key: String = "%s|%d" % [kind, tone]
			_tone_of[coord] = tone
			by_key.get_or_add(key, []).append([length, coord])

	for key: String in by_key:
		var entries: Array = by_key[key]
		# Ascending by authored length. Ties keep atlas order, which is
		# arbitrary but stable — two rungs authored at the same length are an
		# authoring mistake, not a case worth defining.
		entries.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
		var coords: Array[Vector2i] = []
		for e: Array in entries:
			var c: Vector2i = e[1]
			_rung_of[c] = coords.size()
			_key_of[c] = key
			coords.append(c)
		_rungs[key] = coords


static func _int_attr(idx: TileKindIndex, coord: Vector2i, layer: String) -> int:
	var v: Variant = idx.get_attr(coord, layer)
	return 0 if v == null else int(v)


## The rung `coord` occupies in its own ladder — i.e. how many SHORTER rungs of
## the same tone exist below it. 0 for anything not laddered, which callers read
## as "this tile has no shorter form".
func top_rung(coord: Vector2i) -> int:
	return _rung_of.get(coord, 0)


## How many rungs `coord`'s ladder has in total, 1 for anything not laddered.
## `top_rung` says where a coord sits; this says how far the ladder goes, which
## is what tells a single-rung species apart from the bottom of a long one — the
## two report the same `top_rung` and mean opposite things.
func rung_count(coord: Vector2i) -> int:
	var key: String = _key_of.get(coord, "")
	return 1 if key.is_empty() else (_rungs[key] as Array).size()


## The authored grass_tone of `coord`, or 0 for a tile that opts out. Only
## meaningful for comparing two coords: the numbers name species, not an order.
func tone_of(coord: Vector2i) -> int:
	return _tone_of.get(coord, 0)


## The tile `coord`'s ladder wears at `rung`, clamped to the ladder. Returns
## `coord` unchanged when it is not laddered, so a caller never has to branch.
func coord_at(coord: Vector2i, rung: int) -> Vector2i:
	var key: String = _key_of.get(coord, "")
	if key.is_empty():
		return coord
	var coords: Array = _rungs[key]
	return coords[clampi(rung, 0, coords.size() - 1)]
