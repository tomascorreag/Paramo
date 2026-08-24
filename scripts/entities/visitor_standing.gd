class_name VisitorStanding
extends RefCounted

# ============================================================================
# VisitorStanding
# ============================================================================
#
# The registry of cells visitors are going to STAND on, so no two of them end up
# on the same tile.
#
# ----------------------------------------------------------------------------
# Why a reservation and not a collision check
# ----------------------------------------------------------------------------
#
# The obvious implementation — notice on arrival that someone is already here
# and shuffle aside — needs the arriving visitor to rewrite the tail of a path
# it is halfway through, because a waypoint sits in the MIDDLE of a route and
# the queued steps after it all start from the cell it was going to stand on.
# Reserving instead moves the whole problem to route-BUILD time: a member picks
# a standing cell nobody else has claimed, and its route simply goes there. No
# path surgery, no arrival-time special case, and the answer is stable for the
# whole walk rather than depending on who happens to arrive first.
#
# ----------------------------------------------------------------------------
# What this deliberately does NOT do
# ----------------------------------------------------------------------------
#
# It governs where visitors STOP, not every cell they cross. Two visitors
# walking through each other still overlap for the moment they are both in
# transit. Making that impossible means reserving cells along a path, which
# turns two walkers meeting in a one-cell gap into a deadlock and needs a
# yield/repath protocol to break — a much larger change, and one whose failure
# mode (a frozen crowd) is worse than the artefact it removes.
#
# It is also NOT TileGrid.set_occupant. That registry decides WALKABILITY: a
# structure registered there blocks pathfinding for everyone. A resting visitor
# must stay walk-throughable — only its exact standing cell is spoken for — so
# these are different questions and deliberately different stores.
#
# ----------------------------------------------------------------------------
# On the static state
# ----------------------------------------------------------------------------
#
# Exclusion has to hold ACROSS parties, so the store cannot live on a party; and
# visitors are created without a spawner by tools and tests, so it cannot live
# on the spawner either. Hence static. Two things keep that safe: every read
# validates the claimant with is_instance_valid (so a freed visitor's claims
# evaporate rather than blocking a cell forever), and `clear()` exists for the
# hard resets — VisitorSpawner.despawn_all and test setup.
#
# ============================================================================

## cell -> the Visitor that intends to stand there. Entries whose claimant has
## been freed are treated as absent and cleaned up lazily on the next read.
static var _claims: Dictionary[Vector2i, Node] = {}


## Drop every claim. World teardown and test setup only — a targeted release is
## release_all_for.
static func clear() -> void:
	_claims.clear()


## True if `cell` is spoken for by someone other than `claimant`. A dead
## claimant's entry is swept here rather than in a separate pass, which is what
## makes a visitor freed mid-walk (queue_free, a regenerated world) unable to
## leave a cell permanently blocked.
static func is_taken(cell: Vector2i, claimant: Node = null) -> bool:
	if not _claims.has(cell):
		return false
	var holder: Node = _claims[cell]
	if holder == null or not is_instance_valid(holder):
		_claims.erase(cell)
		return false
	return holder != claimant


## A walkable, unclaimed cell within `radius` of `anchor`, claimed for
## `claimant` and returned. Rings outward one cell at a time when the disc is
## full, because a party of five around a radius-1 anchor has only 9 candidates
## and the fifth member must still get somewhere sensible.
##
## Within a ring the pick is RANDOM rather than nearest-first: this doubles as
## the per-member scatter that makes a party spread out around its waypoint, and
## always taking the closest free cell would pack members into a deterministic
## spiral. Candidates are gathered in a fixed x-then-y order so the draw stays
## reproducible from `stream` alone.
##
## Returns Pathfinder.NO_CELL when even the widened rings are full or unwalkable;
## callers fall back to the anchor and accept the overlap rather than not walking.
static func reserve_near(anchor: Vector2i, radius: int, pathfinder: Pathfinder,
		stream: RandomNumberGenerator, claimant: Node, max_widen: int = 2) -> Vector2i:
	if pathfinder == null:
		return Pathfinder.NO_CELL
	for extra in max_widen + 1:
		var r: int = maxi(radius, 0) + extra
		var free: Array[Vector2i] = []
		for dx in range(-r, r + 1):
			for dy in range(-r, r + 1):
				var cell := anchor + Vector2i(dx, dy)
				if not pathfinder.is_walkable(cell):
					continue
				if is_taken(cell, claimant):
					continue
				free.append(cell)
		if not free.is_empty():
			var pick: Vector2i = free[stream.randi_range(0, free.size() - 1)]
			_claims[pick] = claimant
			return pick
	return Pathfinder.NO_CELL


## Hand back every cell `claimant` holds. Called when a visitor re-routes (its
## old standing cells are no longer where it is going) and when it leaves the
## tree. Cheap enough to scan: claims number at most a few per live visitor.
static func release_all_for(claimant: Node) -> void:
	var doomed: Array[Vector2i] = []
	for cell: Vector2i in _claims:
		var holder: Node = _claims[cell]
		if holder == claimant or holder == null or not is_instance_valid(holder):
			doomed.append(cell)
	for cell: Vector2i in doomed:
		_claims.erase(cell)


## Live claim count. For tests and the preview tools — nothing in the game reads
## it, and it counts stale entries until something sweeps them.
static func claim_count() -> int:
	return _claims.size()
