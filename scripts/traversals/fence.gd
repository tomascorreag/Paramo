class_name Fence
extends Traversal

# ============================================================================
# Fence
# ============================================================================
#
# Barbed wire on concrete posts, occupying ONE cell and painting ONE tile.
# Unlike the other Traversals it does not ADD movement — it REMOVES it: the cell
# it stands on is non-walkable while it stands.
#
# It is a Traversal anyway, and that is deliberate rather than lazy: the
# placement pipeline (two-click mode, ghost preview, candidate hints, occupant
# registry, trash removal) is keyed on that base class and a fence needs every
# part of it. The base's `blocks_movement() -> false` is the ONE thing that
# doesn't fit, and it exists precisely to be overridden — TileGrid.is_walkable
# duck-types the call per occupant, so flipping it here is the entire barrier
# mechanism. No pathfinding code knows fences exist.
#
# ----------------------------------------------------------------------------
# One fence = one cell
# ----------------------------------------------------------------------------
#
# A run lays N of these, not one object spanning N cells, so the trash action
# takes out exactly the tile you pointed at. Placement is still two clicks: the
# second click on the ORIGIN cell plants a single fence, on any other cell it
# lays the line between them.
#
# ----------------------------------------------------------------------------
# Orientation is not authored, it is derived — and ties go to the OLDER fence
# ----------------------------------------------------------------------------
#
# Which of the two art variants a fence shows depends on which of its four
# neighbours are also fences (see `kind_at`). Orientation is therefore a
# property of the LOCAL NEIGHBOURHOOD, not of the fence, and it changes under a
# fence when something is built or removed beside it — so every add and every
# remove refreshes the neighbours too (`refresh_art`, `_refresh_neighbours`), or
# a line ends up with a post facing nothing.
#
# A cell with fences on BOTH axes cannot show both: there is no corner piece in
# the atlas, and layering the two whole-cell variants has no correct answer
# (their southernmost posts tie at y=+4, so screen depth cannot order them). The
# tie-break is BUILD ORDER — the axis carrying the older neighbour wins, via
# `build_index`.
#
# That single rule also buys the behaviour a "locked axis" flag would have:
# a fence keeps the connection it made first, because that neighbour stays the
# older one however many arrive later. And unlike a lock it self-corrects — take
# the winning neighbour away and the fence turns to face whatever is left,
# instead of preserving a connection to a gap.
#
# ============================================================================


enum Result {
	OK,
	NOT_WALKABLE_ORIGIN,
	NOT_WALKABLE_FAR,
	ALTITUDE_MISMATCH,
	NOT_DIAGONAL,
	TOO_LONG,
	OCCUPIED,
	NOT_SOLID,
}


## Upper bound on a run's length in CELLS. Matches find_candidates' scan window
## so the candidate hints and the commit validator agree on "too long".
##
## There is no lower bound: a one-cell run is the single fence, and `validate`
## accepts `origin == far` for exactly that reason.
const MAX_CELLS: int = 20

## The four cardinals, grouped by the AXIS their art runs along. Both signs of an
## axis take the same variant — a fence has an orientation, not a facing.
const _NE_AXIS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(0, 1)]
const _NW_AXIS: Array[Vector2i] = [Vector2i(-1, 0), Vector2i(1, 0)]

## Stands in for "no fence on this axis" when comparing ages. Any real
## build_index is smaller, so an axis with nothing on it always loses.
const _NO_FENCE: int = 1 << 62

## Age given to a PENDING cell — one that a preview says is about to become a
## fence. Younger than every real fence, so a ghosted run never wins a tie
## against something already standing.
const _PENDING_AGE: int = _NO_FENCE - 1


@export var cell: Vector2i
@export var altitude: int = 0

## Monotonic placement counter, used only to break both-axes ties. Assigned in
## build(); -1 until then.
var build_index: int = -1


# Shared across every fence in the scene. Static because the ordering has to be
# global — two fences built in different runs still need to compare.
static var _next_build_index: int = 0

var _placer: StructurePlacer
var _pathfinder: Pathfinder
var _kind: StringName = &""


# ----------------------------------------------------------------------------
# Configuration & build
# ----------------------------------------------------------------------------

## Prepare a freshly-instantiated Fence for building. Call before `build()`.
static func configure(
	inst: Fence,
	at: Vector2i,
	alt: int,
	placer: StructurePlacer,
	pf: Pathfinder,
) -> void:
	inst.cell = at
	inst.altitude = alt
	inst._placer = placer
	inst._pathfinder = pf


## Returns true on success, false if the fence couldn't be built. On false
## nothing is left painted and the caller should free the node.
func build() -> bool:
	if _placer == null or _pathfinder == null:
		push_error("Fence.build(): not configured — call Fence.configure() first.")
		return false

	build_index = _next_build_index
	_next_build_index += 1

	# Claim the cell BEFORE choosing art: `kind_at` reads the occupant registry,
	# so a fence that has not registered yet is invisible to its own neighbours
	# and they would all conclude it isn't there.
	_register_with_grid()
	if not refresh_art():
		_clear_grid_occupants()
		_disconnect_from_pathfinder()
		return false
	_refresh_neighbours()

	# The barrier is the occupant claim, which changes is_walkable without
	# changing any geometry — the painted tile is listed in tile_grid._DECORATIVE
	# and skipped by ingest. So there is nothing to re-ingest and rebuild() would
	# be a full grid scan for nothing; but the SIGNAL still has to fire, because
	# that is what drops the cached reachability set the action menu and
	# UXOverlay read.
	_pathfinder.notify_graph_changed()

	# Anchor at the cell's altitude-lifted world position (parity with Bridge and
	# Ladder). Nothing is drawn from this node — the tile is — but it gives the
	# node a sensible place to hang future per-fence audio or effects.
	global_position = _pathfinder.cell_to_world(cell) \
		+ Vector2(0.0, -altitude * Pathfinder.HALF_STEP_PX)
	return true


## Take the fence down, then let its neighbours re-decide their orientation
## without it.
func despawn(placer: StructurePlacer) -> void:
	var pf := _pathfinder
	_clear_grid_occupants()
	_disconnect_from_pathfinder()
	for p in _painted:
		placer.erase(p["cell"], p["altitude"])
	_painted.clear()
	# AFTER releasing the claim, so the neighbours no longer count this fence.
	_refresh_neighbours()
	queue_free()
	if pf != null:
		pf.notify_graph_changed()


## Identifies the fence in the unified occupant registry. Other systems query
## `tile_grid.occupants_of_kind(&"fence")` to find every fenced cell.
func occupant_kind() -> StringName:
	return &"fence"


## The point of the structure. TileGrid.is_walkable calls this per occupant, so
## the cell drops out of the pathfinding graph for as long as the fence stands —
## for the player and for anything else routed by Pathfinder.
func blocks_movement() -> bool:
	return true


func occupied_cells() -> Array[Vector2i]:
	return [cell]


func occupies_cell(c: Vector2i) -> bool:
	return c == cell


# ----------------------------------------------------------------------------
# Orientation
# ----------------------------------------------------------------------------

## The art variant a fence on `at` should show.
##
## The suffix names the axis the WIRE RUNS ALONG: the two posts sit at the
## midpoints of a pair of opposite diamond edges, so the wire is parallel to the
## direction of travel and a straight line of tiles joins up.
##
##   a neighbour on (0, ±1)  -> FENCE_NE
##   a neighbour on (±1, 0)  -> FENCE_NW
##   neighbours on BOTH      -> the axis carrying the OLDER one (see the header)
##   none                    -> FENCE_NE, an arbitrary but stable default; the
##                              first post of a new line has nothing to face and
##                              re-orients as soon as one goes down beside it
##
## `pending` is an optional `{Vector2i: any}` set of cells that are ABOUT to
## become fences, counted as if they already had but aged as the youngest of
## all. The placement ghost passes the whole run through it, so a previewed line
## shows the shape it will actually take instead of a row of unconnected posts —
## while an existing fence still wins any tie against it.
static func kind_at(at: Vector2i, grid: TileGrid, pending: Dictionary = {}) -> StringName:
	var ne := _oldest_on_axis(at, _NE_AXIS, grid, pending)
	var nw := _oldest_on_axis(at, _NW_AXIS, grid, pending)
	# <= so NE takes an exact tie: two pending neighbours, or the default when
	# both axes are empty. Deterministic either way, which is what matters.
	return TileSlots.FENCE_NE if ne <= nw else TileSlots.FENCE_NW


## build_index of the oldest fence on either side of `at` along `axis`, or
## _NO_FENCE when there is none.
static func _oldest_on_axis(
	at: Vector2i, axis: Array[Vector2i], grid: TileGrid, pending: Dictionary = {}
) -> int:
	var best: int = _NO_FENCE
	for dir: Vector2i in axis:
		var nb: Vector2i = at + dir
		if pending.has(nb):
			best = mini(best, _PENDING_AGE)
		if grid != null:
			var occ := grid.occupant_at(nb)
			if occ is Fence:
				best = mini(best, (occ as Fence).build_index)
	return best


## Repaint this fence's tile for its current neighbourhood. Cheap and
## idempotent — called on build, and again on every neighbour's build or
## despawn. False only when the paint itself failed (no Structures layer at this
## altitude, or the slot is missing from the atlas).
func refresh_art() -> bool:
	if _placer == null:
		return false
	var grid: TileGrid = _pathfinder.grid() if _pathfinder != null else null
	var want := kind_at(cell, grid)
	if want == _kind and not _painted.is_empty():
		return true
	if not _painted.is_empty():
		_placer.erase(cell, altitude)
		_painted.clear()
	if not _placer.paint(cell, want, altitude):
		_kind = &""
		return false
	_record(cell, altitude)
	_kind = want
	return true


## The variant currently painted, or &"" before build(). Public so tests can
## assert what a neighbourhood resolved to without reading the tilemap back.
func kind() -> StringName:
	return _kind


# Tell every adjacent fence to re-decide its orientation. Called on both sides
# of this fence's life: after it claims its cell, and after it releases it.
func _refresh_neighbours() -> void:
	var grid: TileGrid = _pathfinder.grid() if _pathfinder != null else null
	if grid == null:
		return
	for axis: Array[Vector2i] in [_NE_AXIS, _NW_AXIS]:
		for dir: Vector2i in axis:
			var occ := grid.occupant_at(cell + dir)
			if occ is Fence and occ != self:
				(occ as Fence).refresh_art()


# A pathfinder rebuild hands back a grid with no occupants, so the base class
# re-registers us — but our ART also depends on that registry, and every fence
# re-registers in an arbitrary order. Refresh after re-registering so a fence
# that read the grid before its neighbour got back onto it corrects itself.
func _on_graph_changed() -> void:
	super._on_graph_changed()
	refresh_art()


# ----------------------------------------------------------------------------
# Validation
# ----------------------------------------------------------------------------

## Pure validator for a RUN of fences from `origin` to `far`, against a TileGrid.
## `origin == far` is a legal one-cell run — that is how a single fence is
## placed and how a gap in a line gets plugged.
##
## Stricter than Bridge's in one way that matters: a bridge only constrains its
## two ENDPOINTS (the deck carries the span, over whatever is down there),
## whereas a fence rests on the ground for its whole length, so EVERY cell must
## be a solid, empty, level flat.
##
## `blocked_cells` is an optional `{Vector2i: any}` set — any cell of the run in
## it yields OCCUPIED. `player_cell` is checked against EVERY cell, endpoints
## included: a bridge may attach to the cell you stand on because it stays
## walkable, but a fence under you would wall you in on the spot.
static func validate(
	origin: Vector2i,
	far: Vector2i,
	grid: TileGrid,
	blocked_cells: Dictionary = {},
	max_cells: int = MAX_CELLS,
	player_cell: Vector2i = Pathfinder.NO_CELL,
) -> int:
	if grid == null:
		return Result.NOT_WALKABLE_ORIGIN
	if not grid.is_walkable(origin):
		return Result.NOT_WALKABLE_ORIGIN
	if not grid.is_walkable(far):
		return Result.NOT_WALKABLE_FAR

	var d := far - origin
	if d.x != 0 and d.y != 0:
		return Result.NOT_DIAGONAL
	var cells: int = absi(d.x) + absi(d.y) + 1
	if cells > max_cells:
		return Result.TOO_LONG

	var oi := grid.get_tile(origin)
	if oi == null:
		return Result.ALTITUDE_MISMATCH
	# Ramps have low != high and no single altitude to stand a post on.
	if oi.altitude_low != oi.altitude_high:
		return Result.ALTITUDE_MISMATCH
	var alt: int = oi.altitude_low

	var dir := _step_direction(origin, far)
	for i in range(0, cells):
		var c: Vector2i = origin + dir * i
		# Solid: a real tile, walkable terrain, flat, and level with the run.
		# is_walkable (not is_terrain_walkable) so an existing blocker on the
		# line is caught even when it never reached blocked_cells.
		if not grid.is_walkable(c):
			return Result.NOT_SOLID
		var ci := grid.get_tile(c)
		if ci == null or ci.altitude_low != ci.altitude_high:
			return Result.NOT_SOLID
		if ci.altitude_low != alt:
			return Result.ALTITUDE_MISMATCH
		if blocked_cells.has(c):
			return Result.OCCUPIED
		if c == player_cell:
			return Result.OCCUPIED

	return Result.OK


## Every cell a run from `origin` to `far` covers, in order. One entry when the
## two are the same cell. Empty only for a true diagonal, which has no axis.
static func plan_cells(origin: Vector2i, far: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if origin == far:
		out.append(origin)
		return out
	var dir := _step_direction(origin, far)
	if dir == Vector2i.ZERO:
		return out
	var steps: int = absi(far.x - origin.x) + absi(far.y - origin.y)
	for i in range(0, steps + 1):
		out.append(origin + dir * i)
	return out


# Returns one of Vector2i(±1, 0) or Vector2i(0, ±1) when from->to is a straight
# cardinal line; Vector2i.ZERO otherwise (same cell or a true diagonal).
static func _step_direction(from: Vector2i, to: Vector2i) -> Vector2i:
	var d := to - from
	if d == Vector2i.ZERO:
		return Vector2i.ZERO
	if d.x != 0 and d.y != 0:
		return Vector2i.ZERO
	return Vector2i(signi(d.x), signi(d.y))


## Closest valid far endpoint per cardinal direction, for the placement hints.
## The ORIGIN itself is always a valid target (a single fence) and is not
## returned — the hint layer already marks the origin.
static func find_candidates(
	origin: Vector2i,
	grid: TileGrid,
	max_scan: int = MAX_CELLS,
	blocked_cells: Dictionary = {},
	player_cell: Vector2i = Pathfinder.NO_CELL,
) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if grid == null:
		return out
	var dirs := [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	for dir: Vector2i in dirs:
		for step in range(1, max_scan):
			var candidate: Vector2i = origin + dir * step
			if validate(origin, candidate, grid, blocked_cells, MAX_CELLS, player_cell) == Result.OK:
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
		Result.TOO_LONG: return "TOO_LONG"
		Result.OCCUPIED: return "OCCUPIED"
		Result.NOT_SOLID: return "NOT_SOLID"
	return "UNKNOWN"
