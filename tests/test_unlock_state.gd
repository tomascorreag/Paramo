extends GutTest

# Guards the token shop's state machine: one-time unlocks, per-placement
# charges with the build-failure refund, the run reset, and the lock gate that
# keeps a locked action OUT of the wheel entirely (contrast is_enabled, which
# only dims). Drives the real ResourceLedger (save/restore via reset).

const TOKENS: StringName = &"tokens"
const WATER: StringName = &"water"

var _unlocks: UnlockState


# Same stub shape as test_action_offerable.gd: is_walkable over a set.
class _StubPathfinder extends Pathfinder:
	var walkable: Dictionary = {}
	func is_walkable(cell: Vector2i) -> bool:
		return walkable.has(cell)


class _GatedAction extends TileAction:
	func _init() -> void:
		unlock_id = &"bridge"
	func _applies(_ctx: ActionContext) -> bool:
		return true


func before_each() -> void:
	ResourceLedger.reset()
	_unlocks = UnlockState.new()
	add_child_autofree(_unlocks)


func after_each() -> void:
	ResourceLedger.reset()


func _ctx_with_unlocks() -> ActionContext:
	var target := Vector2i(5, 5)
	var neighbour := Vector2i(5, 4)
	var pf := autofree(_StubPathfinder.new()) as _StubPathfinder
	pf.walkable[neighbour] = true
	var ctx := ActionContext.new()
	ctx.cell = target
	ctx.pathfinder = pf
	ctx.reachable = {neighbour: true}
	ctx.unlocks = _unlocks
	return ctx


# --- unlocking ---------------------------------------------------------------

func test_unlock_spends_twenty_exactly_once() -> void:
	ResourceLedger.set_amount(TOKENS, 25.0)
	assert_true(_unlocks.try_unlock(&"bridge"))
	assert_true(_unlocks.is_unlocked(&"bridge"))
	assert_eq(ResourceLedger.get_amount(TOKENS), 5.0)
	assert_eq(ResourceLedger.source_total(TOKENS, &"unlock_bridge"), -20.0)

	assert_false(_unlocks.try_unlock(&"bridge"),
			"a second click on an owned entry must refuse WITHOUT spending")
	assert_eq(ResourceLedger.get_amount(TOKENS), 5.0)


func test_unlock_refuses_when_broke() -> void:
	ResourceLedger.set_amount(TOKENS, 19.0)
	assert_false(_unlocks.try_unlock(&"bridge"))
	assert_false(_unlocks.is_unlocked(&"bridge"))
	assert_eq(ResourceLedger.get_amount(TOKENS), 19.0)


func test_types_unlock_independently() -> void:
	ResourceLedger.set_amount(TOKENS, 20.0)
	assert_true(_unlocks.try_unlock(&"frailejon"))
	assert_false(_unlocks.is_unlocked(&"bridge"))
	assert_false(_unlocks.is_unlocked(&"ladder"))


# --- placement charge --------------------------------------------------------

func test_placement_charges_one_token_per_tile_at_commit() -> void:
	ResourceLedger.set_amount(TOKENS, 2.0)
	assert_true(_unlocks.try_pay_placement(&"bridge"))
	assert_eq(ResourceLedger.get_amount(TOKENS), 1.0)
	assert_true(_unlocks.try_pay_placement(&"bridge"))
	assert_false(_unlocks.try_pay_placement(&"bridge"),
			"0 tokens cannot buy a tile")
	assert_eq(ResourceLedger.get_amount(TOKENS), 0.0)


func test_failed_build_refunds_under_the_same_source() -> void:
	# The tally the end screen reads must net to what was actually BUILT.
	ResourceLedger.set_amount(TOKENS, 5.0)
	assert_true(_unlocks.try_pay_placement(&"ladder"))
	_unlocks.refund_placement(&"ladder")
	assert_eq(ResourceLedger.get_amount(TOKENS), 5.0)
	assert_eq(ResourceLedger.source_total(TOKENS, &"place_ladder"), 0.0)


# --- planting spends water too -----------------------------------------------

func test_planting_spends_a_token_and_a_water() -> void:
	ResourceLedger.set_amount(TOKENS, 3.0)
	ResourceLedger.set_amount(WATER, 3.0)
	assert_true(_unlocks.try_pay_placement(&"frailejon"))
	assert_eq(ResourceLedger.get_amount(TOKENS), 2.0)
	assert_eq(ResourceLedger.get_amount(WATER), 2.0)
	# Both legs book under the SAME source, so the end screen reads one purchase.
	assert_eq(ResourceLedger.source_total(WATER, &"place_frailejon"), -1.0)


func test_a_dry_reserve_refuses_the_plant_without_taking_the_token() -> void:
	# The failure this guards: charging tokens, then discovering the water is
	# gone and leaving the player poorer with nothing planted.
	ResourceLedger.set_amount(TOKENS, 10.0)
	ResourceLedger.set_amount(WATER, 0.0)
	assert_false(_unlocks.try_pay_placement(&"frailejon"))
	assert_eq(ResourceLedger.get_amount(TOKENS), 10.0)
	assert_false(_unlocks.can_afford_placement(&"frailejon"),
			"tokens alone must not read as affordable for a plant")
	assert_true(_unlocks.can_afford_placement(&"fence"),
			"a fence costs no water, so a dry reserve does not block it")


func test_only_listed_types_cost_water() -> void:
	ResourceLedger.set_amount(TOKENS, 10.0)
	ResourceLedger.set_amount(WATER, 10.0)
	assert_true(_unlocks.try_pay_placements(&"bridge", 4))
	assert_eq(ResourceLedger.get_amount(WATER), 10.0)
	assert_eq(_unlocks.water_cost(&"bridge", 4), 0.0)
	assert_eq(_unlocks.water_cost(&"frailejon", 4), 4.0)


func test_refunding_a_plant_returns_both_currencies() -> void:
	ResourceLedger.set_amount(TOKENS, 5.0)
	ResourceLedger.set_amount(WATER, 5.0)
	assert_true(_unlocks.try_pay_placements(&"frailejon", 3))
	_unlocks.refund_placements(&"frailejon", 3)
	assert_eq(ResourceLedger.get_amount(TOKENS), 5.0)
	assert_eq(ResourceLedger.get_amount(WATER), 5.0)
	assert_eq(ResourceLedger.source_total(WATER, &"place_frailejon"), 0.0)


func test_water_clamps_the_affordable_tiles_before_tokens_do() -> void:
	ResourceLedger.set_amount(TOKENS, 10.0)
	ResourceLedger.set_amount(WATER, 2.0)
	assert_eq(_unlocks.max_affordable_tiles(10, &"frailejon"), 2)
	assert_eq(_unlocks.max_affordable_tiles(10, &"fence"), 10,
			"water must not clamp a type that does not spend it")


# --- per-tile charge (fence) -------------------------------------------------

func test_a_run_is_charged_one_token_per_tile() -> void:
	ResourceLedger.set_amount(TOKENS, 10.0)
	assert_true(_unlocks.try_pay_placements(&"fence", 6))
	assert_eq(ResourceLedger.get_amount(TOKENS), 4.0)
	# ONE ledger entry, not six.
	assert_eq(ResourceLedger.source_total(TOKENS, &"place_fence"), -6.0)


func test_a_run_is_all_or_nothing() -> void:
	# Half a wall is worse than no wall — the whole run has to be affordable.
	ResourceLedger.set_amount(TOKENS, 3.0)
	assert_false(_unlocks.try_pay_placements(&"fence", 6))
	assert_eq(ResourceLedger.get_amount(TOKENS), 3.0)


func test_per_tile_refund_uses_the_per_tile_rate() -> void:
	# Refunding a 4-tile run as one placement would burn 3 tokens.
	ResourceLedger.set_amount(TOKENS, 10.0)
	assert_true(_unlocks.try_pay_placements(&"fence", 4))
	_unlocks.refund_placements(&"fence", 4)
	assert_eq(ResourceLedger.get_amount(TOKENS), 10.0)
	assert_eq(ResourceLedger.source_total(TOKENS, &"place_fence"), 0.0)


func test_max_affordable_tiles_clamps_to_the_balance() -> void:
	ResourceLedger.set_amount(TOKENS, 3.0)
	assert_eq(_unlocks.max_affordable_tiles(10), 3,
			"the preview must stop where the money stops")
	assert_eq(_unlocks.max_affordable_tiles(2), 2,
			"a run inside the budget is never shortened")


func test_max_affordable_tiles_floors_a_partial_tile() -> void:
	# 3.5 tokens buys three whole fences, not three and a half.
	ResourceLedger.set_amount(TOKENS, 3.5)
	assert_eq(_unlocks.max_affordable_tiles(10), 3)


func test_broke_affords_no_tiles() -> void:
	ResourceLedger.set_amount(TOKENS, 0.0)
	assert_eq(_unlocks.max_affordable_tiles(10), 0)


# --- the preview clamp that reads it ----------------------------------------
#
# TraversalPlacementController._affordable_fence_cells is the consumer of
# max_affordable_tiles, and it only touches _origin_cell / Fence.plan_cells /
# the "unlocks" group — no grid, no pathfinder — so it can be driven here
# against the real UnlockState added to the tree by before_each.

func _controller() -> TraversalPlacementController:
	var c := TraversalPlacementController.new()
	add_child_autofree(c)
	c._origin_cell = Vector2i(0, 0)
	return c


func test_the_preview_run_stops_where_the_money_stops() -> void:
	ResourceLedger.set_amount(TOKENS, 3.0)
	var cells := _controller()._affordable_fence_cells(Vector2i(0, 9))
	assert_eq(cells.size(), 3)
	assert_eq(cells[0], Vector2i(0, 0), "the run still starts at the origin")
	assert_eq(cells[2], Vector2i(0, 2), "and stops at the last cell paid for")


func test_an_affordable_run_is_not_shortened() -> void:
	ResourceLedger.set_amount(TOKENS, 50.0)
	assert_eq(_controller()._affordable_fence_cells(Vector2i(0, 4)).size(), 5)


func test_broke_shows_no_ghost_at_all() -> void:
	ResourceLedger.set_amount(TOKENS, 0.0)
	assert_true(_controller()._affordable_fence_cells(Vector2i(0, 4)).is_empty())


func test_a_diagonal_has_no_run_to_clamp() -> void:
	ResourceLedger.set_amount(TOKENS, 50.0)
	assert_true(_controller()._affordable_fence_cells(Vector2i(3, 3)).is_empty())


# --- run reset ---------------------------------------------------------------

func test_a_new_run_relocks_everything() -> void:
	ResourceLedger.set_amount(TOKENS, 20.0)
	_unlocks.try_unlock(&"bridge")
	_unlocks._on_season_started(0, null)
	assert_false(_unlocks.is_unlocked(&"bridge"),
			"season 0 starting again means a new run")


func test_mid_run_season_changes_keep_unlocks() -> void:
	ResourceLedger.set_amount(TOKENS, 20.0)
	_unlocks.try_unlock(&"bridge")
	_unlocks._on_season_started(1, null)
	assert_true(_unlocks.is_unlocked(&"bridge"),
			"a purchase must survive the season boundary")


# --- the wheel gate ----------------------------------------------------------

func test_locked_action_is_not_offered_at_all() -> void:
	# The shop page is where a locked verb is discovered; the wheel would only
	# read as a broken button. Contrast affordability, which DIMS (is_enabled).
	var action := _GatedAction.new()
	var ctx := _ctx_with_unlocks()
	assert_false(action.is_offerable(ctx))

	ResourceLedger.set_amount(TOKENS, 20.0)
	_unlocks.try_unlock(&"bridge")
	assert_true(action.is_offerable(ctx), "unlocking makes it appear")


func test_unlocked_but_broke_is_offered_dimmed() -> void:
	# The unlock takes the whole balance, so the player owns a verb they cannot
	# yet lay a single tile of.
	ResourceLedger.set_amount(TOKENS, 20.0)
	_unlocks.try_unlock(&"bridge")
	var action := _GatedAction.new()
	var ctx := _ctx_with_unlocks()
	assert_true(action.is_offerable(ctx), "still in the wheel")
	assert_false(action.is_enabled(ctx), "0 tokens < 1 tile: dimmed, not hidden")

	ResourceLedger.set_amount(TOKENS, 1.0)
	assert_true(action.is_enabled(ctx), "one tile's worth is enough to start")


func test_no_unlock_state_means_unlocked_and_free() -> void:
	# Bare test scenes and tools carry no token economy; every pre-existing
	# bridge/ladder/frailejon test relies on this fallback.
	var action := _GatedAction.new()
	var ctx := _ctx_with_unlocks()
	ctx.unlocks = null
	assert_true(action.is_offerable(ctx))
	assert_true(action.is_enabled(ctx))
