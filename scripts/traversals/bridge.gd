class_name Bridge
extends Traversal

# ============================================================================
# Bridge
# ============================================================================
#
# A variable-length bridge: entry HALF_STAIR, one or more HALF_CUBE decks,
# exit HALF_STAIR. Spans a cardinal-diagonal line between two same-altitude
# endpoints on the TileGrid. Painted on the shared Structures layers spawned
# by StructureLayerManager.
#
# Altitude layout (verified against tile_grid.gd):
#   - Entry stair  -> Structures<base_altitude>     (low end = N, high = N+1)
#   - Deck tiles   -> Structures<base_altitude + 1> (FLAT sits flush at the
#                                                    layer's altitude N+1)
#   - Exit stair   -> Structures<base_altitude>     (rise points back toward
#                                                    origin)
#
# ============================================================================


enum Result {
	OK,
	NOT_WALKABLE_ORIGIN,
	NOT_WALKABLE_FAR,
	ALTITUDE_MISMATCH,
	NOT_DIAGONAL,
	TOO_SHORT,
	SAME_CELL,
	OCCUPIED,
}


@export var origin_cell: Vector2i
@export var far_cell: Vector2i
@export var base_altitude: int = 0


var _placer: StructurePlacer
var _pathfinder: Pathfinder


# ----------------------------------------------------------------------------
# Configuration & build
# ----------------------------------------------------------------------------

# Prepare a freshly-instantiated Bridge for building. Call before `build()`.
static func configure(
	inst: Bridge,
	origin: Vector2i,
	far: Vector2i,
	base_alt: int,
	placer: StructurePlacer,
	pf: Pathfinder,
) -> void:
	inst.origin_cell = origin
	inst.far_cell = far
	inst.base_altitude = base_alt
	inst._placer = placer
	inst._pathfinder = pf


func build() -> void:
	if _placer == null or _pathfinder == null:
		push_error("Bridge.build(): not configured — call Bridge.configure() first.")
		return

	var plan := plan_tiles(origin_cell, far_cell, base_altitude)
	if plan.is_empty():
		push_error("Bridge.build(): invalid geometry between %s and %s." % [origin_cell, far_cell])
		return

	for entry in plan:
		if _placer.paint(entry["cell"], entry["kind"], entry["altitude"]):
			_record(entry["cell"], entry["altitude"])

	_pathfinder.rebuild()

	# Anchor position at the origin cell's altitude-lifted world pos. Useful
	# later for attaching animations, SFX, or per-bridge decoration.
	var base_world := _pathfinder.cell_to_world(origin_cell)
	global_position = base_world + Vector2(0.0, -base_altitude * Pathfinder.HALF_STEP_PX)


# Returns the (cell, kind, altitude) entries a bridge would paint between
# `origin` and `far`. Empty array only when the geometry has no orthogonal
# cardinal axis (same cell or true diagonal). For steps == 1, returns the two
# stairs with no deck — validator still flags this as TOO_SHORT, but the plan
# is useful for previews. Pure — no scene-tree or pathfinder side effects.
static func plan_tiles(origin: Vector2i, far: Vector2i, base_altitude: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var dir := _step_direction(origin, far)
	if dir == Vector2i.ZERO:
		return out
	var steps: int = absi(far.x - origin.x) + absi(far.y - origin.y)

	var entry_kind := _entry_stair_kind(dir)
	var exit_kind := _exit_stair_kind(dir)
	var deck_kind := TileSlots.FLAT
	var deck_altitude: int = base_altitude + 1

	out.append({"cell": origin, "kind": entry_kind, "altitude": base_altitude})
	for i in range(1, steps):
		out.append({"cell": origin + dir * i, "kind": deck_kind, "altitude": deck_altitude})
	out.append({"cell": far, "kind": exit_kind, "altitude": base_altitude})
	return out


# ----------------------------------------------------------------------------
# Pure helpers (testable without a tree)
# ----------------------------------------------------------------------------

# Returns one of Vector2i(±1, 0) or Vector2i(0, ±1) when from->to is a straight
# cardinal-diagonal line; Vector2i.ZERO otherwise (same cell or non-diagonal).
static func _step_direction(from: Vector2i, to: Vector2i) -> Vector2i:
	var d := to - from
	if d == Vector2i.ZERO:
		return Vector2i.ZERO
	if d.x != 0 and d.y != 0:
		return Vector2i.ZERO
	return Vector2i(signi(d.x), signi(d.y))


# Entry stair rises toward the deck (toward far_cell).
# Per tile_slots compass:
#   dir ( 0, -1)  NE-ward  -> HALF_STAIR_NE
#   dir (-1,  0)  NW-ward  -> HALF_STAIR_NW
#   dir ( 1,  0)  SE-ward  -> HALF_STAIR_SE
#   dir ( 0,  1)  SW-ward  -> HALF_STAIR_SW
static func _entry_stair_kind(dir: Vector2i) -> StringName:
	if dir == Vector2i( 0, -1): return TileSlots.HALF_STAIR_NE
	if dir == Vector2i(-1,  0): return TileSlots.HALF_STAIR_NW
	if dir == Vector2i( 1,  0): return TileSlots.HALF_STAIR_SE
	if dir == Vector2i( 0,  1): return TileSlots.HALF_STAIR_SW
	return &""


# Exit stair rises back toward origin — i.e. the entry stair for the opposite
# direction.
static func _exit_stair_kind(dir: Vector2i) -> StringName:
	return _entry_stair_kind(-dir)


# ----------------------------------------------------------------------------
# Validation
# ----------------------------------------------------------------------------

# Pure validator against a TileGrid. Controller calls via `pathfinder.grid()`.
# `blocked_cells` is an optional `{Vector2i: any}` set — any cell along the
# bridge plan present in the dict yields Result.OCCUPIED.
static func validate(
	origin: Vector2i, far: Vector2i, grid: TileGrid, blocked_cells: Dictionary = {}
) -> int:
	if origin == far:
		return Result.SAME_CELL
	if grid == null:
		return Result.NOT_WALKABLE_ORIGIN
	if not grid.is_walkable(origin):
		return Result.NOT_WALKABLE_ORIGIN
	if not grid.is_walkable(far):
		return Result.NOT_WALKABLE_FAR

	var d := far - origin
	if d.x != 0 and d.y != 0:
		return Result.NOT_DIAGONAL
	var steps: int = absi(d.x) + absi(d.y)
	if steps < 2:
		return Result.TOO_SHORT

	var oi := grid.cell_info(origin)
	var fi := grid.cell_info(far)
	var o_low: int = oi.get("altitude_low", 0)
	var o_high: int = oi.get("altitude_high", 0)
	var f_low: int = fi.get("altitude_low", 0)
	var f_high: int = fi.get("altitude_high", 0)
	# Only flats allowed as endpoints (ramps have low != high).
	if o_low != o_high or f_low != f_high:
		return Result.ALTITUDE_MISMATCH
	if o_low != f_low:
		return Result.ALTITUDE_MISMATCH

	if not blocked_cells.is_empty():
		var dir := _step_direction(origin, far)
		for i in range(0, steps + 1):
			if blocked_cells.has(origin + dir * i):
				return Result.OCCUPIED

	return Result.OK


## Closest valid endpoint per cardinal direction. For each of the 4 cardinals,
## walks outward from `origin + dir * 2` and returns the first endpoint that
## passes `validate(...) == OK`. Returns up to 4 cells (some directions may
## have no valid endpoint within `max_scan` steps).
static func find_candidates(
	origin: Vector2i,
	grid: TileGrid,
	max_scan: int = 20,
	blocked_cells: Dictionary = {},
) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if grid == null:
		return out
	var dirs := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	for dir: Vector2i in dirs:
		for step in range(2, max_scan + 1):
			var candidate: Vector2i = origin + dir * step
			if validate(origin, candidate, grid, blocked_cells) == Result.OK:
				out.append(candidate)
				break
	return out


static func result_name(r: int) -> String:
	match r:
		Result.OK: return "OK"
		Result.NOT_WALKABLE_ORIGIN: return "NOT_WALKABLE_ORIGIN"
		Result.NOT_WALKABLE_FAR: return "NOT_WALKABLE_FAR"
		Result.ALTITUDE_MISMATCH: return "ALTITUDE_MISMATCH"
		Result.NOT_DIAGONAL: return "NOT_DIAGONAL"
		Result.TOO_SHORT: return "TOO_SHORT"
		Result.SAME_CELL: return "SAME_CELL"
		Result.OCCUPIED: return "OCCUPIED"
	return "UNKNOWN"
