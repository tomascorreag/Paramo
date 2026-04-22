class_name Ladder
extends Traversal

# ============================================================================
# Ladder
# ============================================================================
#
# Vertical climb between two flat floors at different altitudes separated by
# a camera-facing wall (NE or NW face, Minecraft-style). Spans ONE cardinal
# cell: origin `C` -> top `C + dir`, where `dir ∈ {NE=(0,-1), NW=(-1,0)}`.
# Height must be a positive integer number of full cubes (altitude delta =
# 2 * k, k >= 1).
#
# Painted tiles:
#   - k LADDER_* tiles stacked at the ORIGIN cell `C` at altitudes
#     `base+1, base+3, …, base+(2k-1)`, one per full cube. Painting on C
#     (not C+dir) places the sprite's back-face — drawn on the tile's
#     NE/NW side — on the shared diamond plane between C and the wall at
#     C+dir, so the ladder visually "hangs" on the wall from camera view.
#     The tiles are NOT walkable (absent from tile_grid._SHAPES) and don't
#     participate in shape-based pathfinding.
#
# Pathfinding:
#   - Climb is expressed as a Pathfinder "traversal edge" between origin and
#     top cells. The edge bypasses the shape-based altitude check in
#     TileGrid.can_transition, so A* can take one step up/down the ladder
#     regardless of the altitude delta. The edge survives rebuild().
#
# ============================================================================


enum Result {
	OK,
	NOT_WALKABLE_ORIGIN,
	NOT_WALKABLE_TOP,
	BAD_DIRECTION,
	BAD_HEIGHT,
	WALL_COLUMN_MISSING,
	OCCUPIED,
	SAME_CELL,
}


# NE and NW are the camera-facing wall faces in this project's iso compass
# (see tile_slots.gd). SE/SW are the hidden back sides of a cube and don't
# show a ladder sprite — we reject those directions outright.
const VALID_DIRS: Array = [Vector2i(0, -1), Vector2i(-1, 0)]

# Upper limit on climb height (in full cubes). Caps find_candidates' scan and
# clamps pathological validations. The real ceiling is whether the structure
# layer stack covers the altitudes we want to paint at.
const MAX_HEIGHT_CUBES: int = 4


@export var origin_cell: Vector2i
@export var top_cell: Vector2i
@export var base_altitude: int = 0
@export var height_cubes: int = 1


var _placer: StructurePlacer
var _pathfinder: Pathfinder


# ----------------------------------------------------------------------------
# Configuration & build
# ----------------------------------------------------------------------------

# Prepare a freshly-instantiated Ladder for building. Call before `build()`.
static func configure(
	inst: Ladder,
	origin: Vector2i,
	top: Vector2i,
	base_alt: int,
	placer: StructurePlacer,
	pf: Pathfinder,
) -> void:
	inst.origin_cell = origin
	inst.top_cell = top
	inst.base_altitude = base_alt
	inst._placer = placer
	inst._pathfinder = pf


func build() -> void:
	if _placer == null or _pathfinder == null:
		push_error("Ladder.build(): not configured — call Ladder.configure() first.")
		return

	var top_tile := _pathfinder.get_tile(top_cell)
	if top_tile == null:
		push_error("Ladder.build(): no tile at top_cell %s." % top_cell)
		return
	var top_alt: int = top_tile.altitude_low
	height_cubes = (top_alt - base_altitude) / 2

	var plan := plan_tiles(origin_cell, top_cell, base_altitude, top_alt)
	if plan.is_empty():
		push_error(
			"Ladder.build(): invalid geometry origin=%s top=%s base_alt=%s top_alt=%s."
			% [origin_cell, top_cell, base_altitude, top_alt]
		)
		return

	for entry in plan:
		if _placer.paint(entry["cell"], entry["kind"], entry["altitude"]):
			_record(entry["cell"], entry["altitude"])

	_pathfinder.add_traversal_edge(origin_cell, top_cell)
	_pathfinder.rebuild()

	# Anchor at origin's altitude-lifted world pos (parity with Bridge).
	var base_world := _pathfinder.cell_to_world(origin_cell)
	global_position = base_world + Vector2(0.0, -base_altitude * Pathfinder.HALF_STEP_PX)


# Erase painted tiles AND unregister the traversal edge. Overrides the base
# despawn so we clear both sides of the ladder's footprint.
func despawn(placer: StructurePlacer) -> void:
	if _pathfinder != null:
		_pathfinder.remove_traversal_edge(origin_cell, top_cell)
	super.despawn(placer)


# Returns the (cell, kind, altitude) entries a ladder would paint between
# cells `a` and `b` at altitudes `alt_a` and `alt_b`. Pure — no side effects.
# Empty array when the geometry is invalid: same altitude (no height),
# non-multiple of 2 delta, or a direction from the lower cell to the upper
# cell that is not NE or NW (ladders only hang on camera-facing walls).
#
# The caller may pass the pair in either order; the function orients by
# altitude so `plan_tiles(lower, upper, low, high)` and
# `plan_tiles(upper, lower, high, low)` produce the same plan. The ladder
# tiles always paint on the LOWER cell so the back-face renders on the
# shared NE/NW plane between lower and upper.
static func plan_tiles(
	a: Vector2i, b: Vector2i, alt_a: int, alt_b: int
) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var lower: Vector2i
	var upper: Vector2i
	var base_alt: int
	var top_alt: int
	if alt_a < alt_b:
		lower = a; upper = b; base_alt = alt_a; top_alt = alt_b
	elif alt_b < alt_a:
		lower = b; upper = a; base_alt = alt_b; top_alt = alt_a
	else:
		return out  # equal altitudes → no ladder
	var dir := _step_direction(lower, upper)
	if dir == Vector2i.ZERO or not VALID_DIRS.has(dir):
		return out
	var delta: int = top_alt - base_alt
	if delta % 2 != 0:
		return out
	var k: int = delta / 2  # full-cube count

	var kind := _ladder_kind(dir)
	for i in range(1, k + 1):
		out.append({
			"cell": lower,
			"kind": kind,
			"altitude": base_alt + 2 * i - 1,
		})
	return out


# ----------------------------------------------------------------------------
# Pure helpers
# ----------------------------------------------------------------------------

static func _step_direction(from: Vector2i, to: Vector2i) -> Vector2i:
	var d := to - from
	if d == Vector2i.ZERO:
		return Vector2i.ZERO
	if d.x != 0 and d.y != 0:
		return Vector2i.ZERO
	return Vector2i(signi(d.x), signi(d.y))


# dir is the step from origin to top. The ladder sprite hangs on the wall
# face that is shared between origin and top — i.e. the face on `top`'s side
# pointing BACK toward origin. For dir=NE (0,-1) the top is up-right, and
# the ladder visually drapes down its SW face, which is the same plane as
# origin's NE face. We select the art variant whose sprite is designed to
# render on that plane.
static func _ladder_kind(dir: Vector2i) -> StringName:
	if dir == Vector2i(0, -1):
		return TileSlots.LADDER_NE
	if dir == Vector2i(-1, 0):
		return TileSlots.LADDER_NW
	return &""


# ----------------------------------------------------------------------------
# Validation
# ----------------------------------------------------------------------------

# Validates a ladder spanning cells `a` and `b` in either order. The caller
# may pass the first-clicked cell as `a` and the second-clicked as `b`
# regardless of which is higher — the function orients by altitude and
# checks that the direction from LOWER to UPPER is NE or NW (the only
# camera-facing wall faces that carry a ladder sprite).
#
# Error codes use "ORIGIN" for the first argument and "TOP" for the second
# to match caller-side UX language, not the internal lower/upper roles.
static func validate(
	a: Vector2i, b: Vector2i, grid: TileGrid, blocked_cells: Dictionary = {}
) -> int:
	if a == b:
		return Result.SAME_CELL
	if grid == null:
		return Result.NOT_WALKABLE_ORIGIN
	if not grid.is_walkable(a):
		return Result.NOT_WALKABLE_ORIGIN
	if not grid.is_walkable(b):
		return Result.NOT_WALKABLE_TOP

	var ai := grid.get_tile(a)
	var bi := grid.get_tile(b)
	if ai == null or bi == null:
		return Result.BAD_HEIGHT
	# Both endpoints must be flats — a ladder from/to a ramp has no sensible
	# anchor altitude.
	if ai.altitude_low != ai.altitude_high or bi.altitude_low != bi.altitude_high:
		return Result.BAD_HEIGHT

	# Orient to (lower, upper) by altitude. Equal altitudes → no height delta,
	# no ladder.
	var lower: Vector2i
	var upper: Vector2i
	var base_alt: int
	var top_alt: int
	if ai.altitude_low < bi.altitude_low:
		lower = a; upper = b; base_alt = ai.altitude_low; top_alt = bi.altitude_low
	elif bi.altitude_low < ai.altitude_low:
		lower = b; upper = a; base_alt = bi.altitude_low; top_alt = ai.altitude_low
	else:
		return Result.BAD_HEIGHT

	var dir := _step_direction(lower, upper)
	if dir == Vector2i.ZERO or not VALID_DIRS.has(dir):
		return Result.BAD_DIRECTION

	var delta: int = top_alt - base_alt
	if delta % 2 != 0:
		return Result.BAD_HEIGHT

	# Wall column check: the column at `lower + dir` (which equals `upper`'s
	# (x,y)) must exist. The upper cell's walkable entry already sits at
	# top_alt, so a populated tile here implies the wall stack under it is
	# present. Missing → out-of-bounds or empty cell.
	var wall_cell := lower + dir
	var wall_tile := grid.get_tile(wall_cell)
	if wall_tile == null:
		return Result.WALL_COLUMN_MISSING

	if not blocked_cells.is_empty():
		if blocked_cells.has(a) or blocked_cells.has(b):
			return Result.OCCUPIED

	return Result.OK


## Valid second-click endpoints for a ladder rooted at `origin`. Scans all
## four cardinal neighbors and returns the ones that form a valid ladder with
## `origin` — either as the UPPER landing of a bottom-up build (neighbor is
## NE/NW and higher) or the LOWER landing of a top-down build (neighbor is
## SE/SW and lower, so that from lower's perspective the dir to origin is
## NE/NW). Up to 4 cells returned. Respects `max_height_cubes`.
static func find_candidates(
	origin: Vector2i,
	grid: TileGrid,
	max_height_cubes: int = MAX_HEIGHT_CUBES,
	blocked_cells: Dictionary = {},
) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if grid == null:
		return out
	var oi := grid.get_tile(origin)
	if oi == null or not oi.walkable:
		return out
	if oi.altitude_low != oi.altitude_high:
		return out

	const _ALL_DIRS: Array = [
		Vector2i(0, -1),  # NE — bottom-up candidate if higher
		Vector2i(-1, 0),  # NW — bottom-up candidate if higher
		Vector2i(1, 0),   # SE — top-down candidate if lower
		Vector2i(0, 1),   # SW — top-down candidate if lower
	]
	for dir: Vector2i in _ALL_DIRS:
		var nb: Vector2i = origin + dir
		if validate(origin, nb, grid, blocked_cells) != Result.OK:
			continue
		var ni := grid.get_tile(nb)
		if ni == null:
			continue
		var k: int = absi(ni.altitude_low - oi.altitude_low) / 2
		if k < 1 or k > max_height_cubes:
			continue
		out.append(nb)
	return out


static func result_name(r: int) -> String:
	match r:
		Result.OK: return "OK"
		Result.NOT_WALKABLE_ORIGIN: return "NOT_WALKABLE_ORIGIN"
		Result.NOT_WALKABLE_TOP: return "NOT_WALKABLE_TOP"
		Result.BAD_DIRECTION: return "BAD_DIRECTION"
		Result.BAD_HEIGHT: return "BAD_HEIGHT"
		Result.WALL_COLUMN_MISSING: return "WALL_COLUMN_MISSING"
		Result.OCCUPIED: return "OCCUPIED"
		Result.SAME_CELL: return "SAME_CELL"
	return "UNKNOWN"
