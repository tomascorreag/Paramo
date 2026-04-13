extends GutTest

# ===========================================================================
# Pathfinder._cell_to_id / _id_to_cell — pure static math
# ===========================================================================

# Constants mirrored from Pathfinder for readable expected values.
const BIAS: int = 10000
const STRIDE: int = 100000


func _expected_id(x: int, y: int) -> int:
	return (x + BIAS) * STRIDE + (y + BIAS)


# --- _cell_to_id ---

func test_cell_to_id_origin() -> void:
	assert_eq(Pathfinder._cell_to_id(Vector2i(0, 0)), _expected_id(0, 0))


func test_cell_to_id_positive() -> void:
	assert_eq(Pathfinder._cell_to_id(Vector2i(5, 3)), _expected_id(5, 3))


func test_cell_to_id_negative() -> void:
	assert_eq(Pathfinder._cell_to_id(Vector2i(-3, -7)), _expected_id(-3, -7))


# --- _id_to_cell ---

func test_id_to_cell_origin() -> void:
	assert_eq(Pathfinder._id_to_cell(_expected_id(0, 0)), Vector2i(0, 0))


func test_id_to_cell_positive() -> void:
	assert_eq(Pathfinder._id_to_cell(_expected_id(5, 3)), Vector2i(5, 3))


func test_id_to_cell_negative() -> void:
	assert_eq(Pathfinder._id_to_cell(_expected_id(-3, -7)), Vector2i(-3, -7))


# --- Roundtrips ---

func test_roundtrip_origin() -> void:
	var cell := Vector2i(0, 0)
	assert_eq(Pathfinder._id_to_cell(Pathfinder._cell_to_id(cell)), cell)


func test_roundtrip_positive() -> void:
	var cell := Vector2i(42, 99)
	assert_eq(Pathfinder._id_to_cell(Pathfinder._cell_to_id(cell)), cell)


func test_roundtrip_negative() -> void:
	var cell := Vector2i(-500, -1000)
	assert_eq(Pathfinder._id_to_cell(Pathfinder._cell_to_id(cell)), cell)


func test_roundtrip_max_bias() -> void:
	var cell := Vector2i(9999, 9999)
	assert_eq(Pathfinder._id_to_cell(Pathfinder._cell_to_id(cell)), cell)


func test_roundtrip_min_bias() -> void:
	var cell := Vector2i(-9999, -9999)
	assert_eq(Pathfinder._id_to_cell(Pathfinder._cell_to_id(cell)), cell)


# --- Uniqueness ---

func test_unique_ids() -> void:
	var cells: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1),
		Vector2i(-1, 0), Vector2i(0, -1), Vector2i(100, -100),
	]
	var ids: Dictionary = {}
	for cell in cells:
		var id := Pathfinder._cell_to_id(cell)
		assert_false(ids.has(id), "Duplicate ID for cell %s" % cell)
		ids[id] = true
