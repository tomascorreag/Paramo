extends GutTest

# Guards the token shop's state machine: one-time unlocks, per-placement
# charges with the build-failure refund, the run reset, and the lock gate that
# keeps a locked action OUT of the wheel entirely (contrast is_enabled, which
# only dims). Drives the real ResourceLedger (save/restore via reset).

const TOKENS: StringName = &"tokens"

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

func test_unlock_spends_ten_exactly_once() -> void:
	ResourceLedger.set_amount(TOKENS, 25.0)
	assert_true(_unlocks.try_unlock(&"bridge"))
	assert_true(_unlocks.is_unlocked(&"bridge"))
	assert_eq(ResourceLedger.get_amount(TOKENS), 15.0)
	assert_eq(ResourceLedger.source_total(TOKENS, &"unlock_bridge"), -10.0)

	assert_false(_unlocks.try_unlock(&"bridge"),
			"a second click on an owned entry must refuse WITHOUT spending")
	assert_eq(ResourceLedger.get_amount(TOKENS), 15.0)


func test_unlock_refuses_when_broke() -> void:
	ResourceLedger.set_amount(TOKENS, 9.0)
	assert_false(_unlocks.try_unlock(&"bridge"))
	assert_false(_unlocks.is_unlocked(&"bridge"))
	assert_eq(ResourceLedger.get_amount(TOKENS), 9.0)


func test_types_unlock_independently() -> void:
	ResourceLedger.set_amount(TOKENS, 10.0)
	assert_true(_unlocks.try_unlock(&"frailejon"))
	assert_false(_unlocks.is_unlocked(&"bridge"))
	assert_false(_unlocks.is_unlocked(&"ladder"))


# --- placement charge --------------------------------------------------------

func test_placement_charges_five_at_commit() -> void:
	ResourceLedger.set_amount(TOKENS, 7.0)
	assert_true(_unlocks.try_pay_placement(&"bridge"))
	assert_eq(ResourceLedger.get_amount(TOKENS), 2.0)
	assert_false(_unlocks.try_pay_placement(&"bridge"),
			"2 tokens cannot buy a 5-token placement")
	assert_eq(ResourceLedger.get_amount(TOKENS), 2.0)


func test_failed_build_refunds_under_the_same_source() -> void:
	# The tally the end screen reads must net to what was actually BUILT.
	ResourceLedger.set_amount(TOKENS, 5.0)
	assert_true(_unlocks.try_pay_placement(&"ladder"))
	_unlocks.refund_placement(&"ladder")
	assert_eq(ResourceLedger.get_amount(TOKENS), 5.0)
	assert_eq(ResourceLedger.source_total(TOKENS, &"place_ladder"), 0.0)


# --- run reset ---------------------------------------------------------------

func test_a_new_run_relocks_everything() -> void:
	ResourceLedger.set_amount(TOKENS, 10.0)
	_unlocks.try_unlock(&"bridge")
	_unlocks._on_season_started(0, null)
	assert_false(_unlocks.is_unlocked(&"bridge"),
			"season 0 starting again means a new run")


func test_mid_run_season_changes_keep_unlocks() -> void:
	ResourceLedger.set_amount(TOKENS, 10.0)
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

	ResourceLedger.set_amount(TOKENS, 10.0)
	_unlocks.try_unlock(&"bridge")
	assert_true(action.is_offerable(ctx), "unlocking makes it appear")


func test_unlocked_but_broke_is_offered_dimmed() -> void:
	ResourceLedger.set_amount(TOKENS, 10.0)
	_unlocks.try_unlock(&"bridge")
	var action := _GatedAction.new()
	var ctx := _ctx_with_unlocks()
	assert_true(action.is_offerable(ctx), "still in the wheel")
	assert_false(action.is_enabled(ctx), "0 tokens < 5: dimmed, not hidden")

	ResourceLedger.set_amount(TOKENS, 5.0)
	assert_true(action.is_enabled(ctx))


func test_no_unlock_state_means_unlocked_and_free() -> void:
	# Bare test scenes and tools carry no token economy; every pre-existing
	# bridge/ladder/frailejon test relies on this fallback.
	var action := _GatedAction.new()
	var ctx := _ctx_with_unlocks()
	ctx.unlocks = null
	assert_true(action.is_offerable(ctx))
	assert_true(action.is_enabled(ctx))
