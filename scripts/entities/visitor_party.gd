class_name VisitorParty
extends RefCounted

# ============================================================================
# VisitorParty
# ============================================================================
#
# The regrouping barrier for one group of visitors: a member that reaches
# waypoint N stands there until every other member has reached waypoint N too,
# then they all move on.
#
# ----------------------------------------------------------------------------
# Why it exists
# ----------------------------------------------------------------------------
#
# It is the ONLY mechanism that can cancel the SPAWN STAGGER. Members enter
# group_member_stagger_seconds apart on the same trail at near-identical pace,
# so the last one in is permanently ~3-4 cells behind the first and nothing
# else ever recovers that — not pace, not the pauses, which only add spread.
# A party that visibly waits for its slowest member is also a thing the player
# can watch happen, which no amount of knob-tuning buys.
#
# ----------------------------------------------------------------------------
# Why a member never blocks on this
# ----------------------------------------------------------------------------
#
# A barrier that waits for everyone strands the party the moment one member
# stops participating, and members drop out constantly: sent home at closing,
# fading out on a rebuilt world, relocated by nearest_reachable after the player
# fences a route, or falling back to a direct path that has no waypoints to
# arrive at. The result would be visitors standing still forever, in view.
#
# So there are TWO independent guarantees, and the second is the load-bearing
# one:
#   1. `member_left` shrinks the party, which releases anyone still waiting on
#      the departed member. This is the tidy path and covers every case the code
#      knows about.
#   2. Each waiting member carries its OWN timeout (Visitor.regroup_timeout_
#      seconds) and leaves when it expires regardless of this object's opinion.
#      That is what makes a deadlock impossible rather than merely unlikely —
#      it holds even for a drop-out route nobody thought of.
#
# ============================================================================


## Members still walking the party's route. Shrinks as they drop out; a release
## is decided against this, never against the size the party started at.
var size: int = 0

## waypoint index -> how many members have reached it.
var _arrived: Dictionary[int, int] = {}

## waypoint index -> released. Latched, so a member that arrives AFTER the
## release (it timed out at an earlier waypoint and fell behind) does not
# re-block on a barrier the rest of the party has already passed.
var _released: Dictionary[int, bool] = {}


func _init(member_count: int = 0) -> void:
	size = maxi(member_count, 0)


## One member reached waypoint `index` and is now waiting there.
func arrive(index: int) -> void:
	_arrived[index] = int(_arrived.get(index, 0)) + 1
	_settle(index)


## `count` more members will walk this route. The spawner calls this per member
## as it actually spawns, rather than declaring the party size up front: a
## member that fails to spawn would otherwise be counted forever and every
## barrier would fall through to the timeout.
func member_joined() -> void:
	size += 1


## A member is no longer walking the party's route — despawned, sent home,
## re-routed onto its own line, or never got a wandering path at all. Releases
## any barrier that was only waiting on it.
func member_left() -> void:
	size = maxi(size - 1, 0)
	for index: int in _arrived:
		_settle(index)


func is_released(index: int) -> bool:
	return bool(_released.get(index, false))


## A barrier opens when everyone still in the party has reached it. `size <= 0`
## opens it too: an empty party has nobody left to wait for, and a member that
# somehow outlives the count must not be trapped.
func _settle(index: int) -> void:
	if _released.has(index):
		return
	if size <= 0 or int(_arrived.get(index, 0)) >= size:
		_released[index] = true


## How many members have reached `index`. Tests and debugging only.
func arrived_at(index: int) -> int:
	return int(_arrived.get(index, 0))
