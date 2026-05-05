class_name TerrainGrid
extends RefCounted

# ============================================================================
# TerrainGrid
# ============================================================================
#
# 2D container of TerrainCell records used by TerrainGenerator (writes) and
# TerrainPainter (reads). Always pre-allocated to width x height; every cell
# is a TerrainCell instance (never null) — caller checks `cell.kind` for
# emptiness instead of nullness.
#
# ============================================================================


var width: int = 0
var height: int = 0

# Row-major, indexed as `_cells[y * width + x]`.
var _cells: Array[TerrainCell] = []


func _init(w: int, h: int) -> void:
	width = w
	height = h
	_cells.resize(w * h)
	for i in _cells.size():
		_cells[i] = TerrainCell.make_empty()


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < width and y < height


func at(x: int, y: int) -> TerrainCell:
	return _cells[y * width + x]


func set_cell(x: int, y: int, cell: TerrainCell) -> void:
	_cells[y * width + x] = cell


# Returns the cell at (x,y) or null when out of bounds — used by the painter
# and shore-mask logic to peek at neighbors without crashing on edges.
func at_or_null(x: int, y: int) -> TerrainCell:
	if not in_bounds(x, y):
		return null
	return _cells[y * width + x]
