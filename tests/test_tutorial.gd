extends GutTest

# Guards the FTUE (scripts/ui/tutorial_controller.gd) and the two run-opening
# rules it depends on: the day starts a bit after dawn, and the world lights no
# fires of its own on that first day.
#
# The failure these exist to catch is silent in all three cases. The tutorial
# advances off signals it looks up BY NAME at runtime, so renaming
# `path_dispatched` or `placement_paid` leaves a step that simply never
# completes — no error, just a hint strip that sits there forever. Likewise a
# step key missing from the CSV renders as "TUTORIAL_MOVE" on the panel.

const CSV_PATH: String = "res://assets/translations/paramo.csv"
const BASE_SCENE: String = "res://scenes/templates/gameplay_base.tscn"

# Step id -> (class that emits the completion signal, signal name). Mirrors
# TutorialController._connect_step_signal; if that match block changes, this
# table has to change with it, which is the point.
const STEP_SIGNALS: Dictionary = {
	&"move": ["res://scripts/systems/click_to_move_controller.gd", "path_dispatched"],
	&"journal": ["res://scripts/ui/field_journal.gd", "opened"],
	&"shop": ["res://scripts/systems/unlock_state.gd", "unlock_changed"],
	&"close_journal": ["res://scripts/ui/field_journal.gd", "closed"],
	&"build": ["res://scripts/systems/unlock_state.gd", "placement_paid"],
	&"build_endpoint": ["res://scripts/systems/unlock_state.gd", "placement_paid"],
	&"fire_douse": ["res://scripts/systems/fire_manager.gd", "tile_extinguished"],
}

## Steps that advance on something other than a named signal, and what instead.
## Kept as an explicit list rather than "everything not in STEP_SIGNALS" so that
## a step losing its signal entry fails here instead of being quietly reclassified.
const UNSIGNALLED_STEPS: Dictionary = {
	&"welcome": "narrative dwell",
	&"charge": "narrative dwell",
	&"roam": "a fixed _ROAM_SECONDS hold",
	&"fire_follow": "polled: the fire's cell entering the frame",
	&"closing": "narrative dwell",
}

# The build steps also hang off the placement controller: `build` leaves early
# when a traversal OPENS its second click, and `build_endpoint` rewinds when that
# placement closes without building. Same silent-failure risk as the table above.
const PLACEMENT_SIGNALS: Array[String] = ["placement_began", "placement_ended"]
const PLACEMENT_SCRIPT: String = "res://scripts/systems/traversal_placement_controller.gd"

var _csv_keys: Dictionary = {}


# The SHIPPED defaults, off a fresh instance of the script — not off the live
# SeasonManager autoload. Other suites (test_season_manager) write the autoload's
# exports and don't restore them, so reading it here makes this pass or fail on
# test order.
func _season_defaults() -> Node:
	var script: GDScript = load("res://scripts/systems/season_manager.gd")
	return autofree(script.new())


func before_all() -> void:
	var f := FileAccess.open(CSV_PATH, FileAccess.READ)
	assert_not_null(f, "%s must exist" % CSV_PATH)
	if f == null:
		return
	f.get_csv_line() # header
	while not f.eof_reached():
		var row := f.get_csv_line()
		if row.size() >= 3 and not row[0].is_empty():
			_csv_keys[row[0]] = row
	f.close()


# --- The step table ---------------------------------------------------------

func test_steps_teach_move_journal_shop_build_in_order() -> void:
	var ids: Array = []
	for step: Dictionary in TutorialController._STEPS:
		if not bool(step.get("narrative", false)):
			ids.append(step["id"])
	assert_eq(ids, [&"move", &"journal", &"shop", &"close_journal", &"build",
			&"build_endpoint", &"roam", &"fire_follow", &"fire_douse"],
			"FTUE order is load-bearing: the shop step can only be done from the "
			+ "journal the previous step opened, the build step can only be "
			+ "done with the tool the shop step bought, from a world the "
			+ "close step got back to — and the fire arc runs last because it is "
			+ "the only part that needs the player already able to walk away.")


func test_the_fire_arc_is_roam_then_follow_then_douse() -> void:
	# The order inside the arc is the whole lesson: the strip has to be GONE
	# before the fire starts, or the player learns that fires are announced; the
	# fire has to be found before it can be put out, or the aura teaches nothing.
	var ids: Array = []
	for step: Dictionary in TutorialController._STEPS:
		ids.append(step["id"])
	var roam: int = ids.find(&"roam")
	assert_gt(roam, ids.find(&"build_endpoint"),
			"the quiet beat must come after every taught verb — it is the FTUE "
			+ "letting go, and there is nothing left to let go of before that")
	assert_eq(ids[roam + 1], &"fire_follow")
	assert_eq(ids[roam + 2], &"fire_douse")
	assert_eq(ids[roam + 3], &"closing", "the sign-off closes the fire arc too")


func test_the_quiet_beat_shows_nothing_and_holds_long_enough_to_be_play() -> void:
	# A step with copy is the tutorial talking. This one's content is that it
	# isn't: an empty panel parked at the bottom of the screen would be worse
	# than no panel, so it must carry no key at all.
	for step: Dictionary in TutorialController._STEPS:
		if step["id"] != &"roam":
			continue
		assert_true(bool(step.get("quiet", false)),
				"the roam step must be marked quiet, or the strip stays up empty")
		assert_eq(String(step["key"]), "",
				"a quiet step must have no copy")
		assert_false(step.has("grants"),
				"every verb is taught by now; the quiet beat must not be the "
				+ "step that grants one, or the gate opens with nothing on screen")
	# Long enough that the player stops waiting for the next line and looks at
	# the world — which is the state the off-screen glow has to interrupt.
	assert_gte(TutorialController._ROAM_SECONDS, 6.0,
			"below this the strip reads as still talking")
	assert_lte(TutorialController._ROAM_SECONDS, 30.0,
			"above this a player who has stopped exploring is just waiting")


func test_the_scripted_fire_stays_inside_the_auras_reach() -> void:
	# The screen-edge aura is the ONLY thing that reports this fire — it is lit
	# off-screen on purpose. FireAuraOverlay contributes nothing past REACH, so a
	# fire placed beyond it leaves the player with a line telling them to follow
	# a glow that is not being drawn.
	assert_lt(TutorialController._FIRE_MAX_OFFSCREEN, FireAuraOverlay.REACH,
			"the fire must be lit inside the aura's reach, or nothing points at it")
	assert_lt(TutorialController._FIRE_TARGET_OFFSCREEN,
			TutorialController._FIRE_MAX_OFFSCREEN)
	assert_gt(TutorialController._FIRE_TARGET_OFFSCREEN,
			TutorialController._FIRE_MIN_OFFSCREEN,
			"the target has to sit inside the band the search accepts")
	# And genuinely off screen: the aura's rise term is still fading a fire in
	# at the edge, so a cell scored just outside would be visible AND unlit.
	assert_gt(TutorialController._FIRE_MIN_OFFSCREEN, 0.0,
			"a fire the player can already see is not an off-screen fire")


func test_the_scripted_fire_outlasts_the_walk_and_does_not_spread() -> void:
	# Two concessions, both reachable only from FireManager.ignite's optional
	# arguments (see dev-notes/ftue.md), and both load-bearing for a step whose
	# completion is "the player right-clicked THAT fire".
	#
	# Fuel: a default tile burns out in roughly FUEL_DEFAULT / FUEL_BURN_PER_SEC
	# seconds at full intensity. The player has to notice the glow, read the
	# line and cross most of a screen; a fire that dies on the way leaves the
	# strip asking for a click on nothing.
	var default_life: float = FireDynamics.FUEL_DEFAULT / FireDynamics.FUEL_BURN_PER_SEC
	var tutorial_life: float = TutorialController._FIRE_FUEL / FireDynamics.FUEL_BURN_PER_SEC
	assert_gt(tutorial_life, default_life * 4.0,
			"the tutorial fire must outlast the walk over to it by a wide "
			+ "margin — %.0fs is what a normal tile gets" % default_life)
	# Spread: the containment flag has to be honoured where spread is rolled.
	var src := FileAccess.get_file_as_string("res://scripts/systems/fire_manager.gd")
	assert_false(src.is_empty(), "fire_manager.gd must be readable")
	assert_true(src.contains("entry.get(\"contained\", false)"),
			"a contained fire must be refused a spread roll, or the single fire "
			+ "the FTUE asks the player to douse is a front by the time they "
			+ "arrive")


func test_narrative_brackets_the_instructions() -> void:
	# Prose between two things the player is being asked to do reads as an
	# interruption; prose before the first and after the last reads as a frame.
	# Also guards the thing that would break silently: a narrative step has no
	# entry in _connect_step_signal, so one landing in the middle of the taught
	# sequence would still advance, but on a timer, mid-lesson.
	var flags: Array = []
	for step: Dictionary in TutorialController._STEPS:
		flags.append(bool(step.get("narrative", false)))
	var first_instruction: int = flags.find(false)
	var last_instruction: int = flags.rfind(false)
	assert_gt(first_instruction, 0, "the FTUE must open with narrative")
	assert_lt(last_instruction, flags.size() - 1, "the FTUE must close with narrative")
	for i: int in range(first_instruction, last_instruction + 1):
		assert_false(flags[i],
				"step %d is narrative but sits between two instruction steps"
				% i)


func test_narrative_steps_have_no_completion_signal() -> void:
	# The inverse of STEP_SIGNALS: narrative advances on a dwell timer, so a
	# narrative id appearing in the signal table means one of the two is wrong.
	for step: Dictionary in TutorialController._STEPS:
		if bool(step.get("narrative", false)):
			assert_false(STEP_SIGNALS.has(step["id"]),
					"narrative step '%s' must not claim a completion signal"
					% step["id"])


func test_walking_is_taught_over_two_moves() -> void:
	# One dispatched path can be a mis-click. The move step holds until the
	# player has walked twice, which is where the ground reads as a destination
	# rather than as something that happened.
	for step: Dictionary in TutorialController._STEPS:
		if step["id"] == &"move":
			assert_eq(int(step.get("repeat", 1)), 2,
					"the move step must wait for two walks")


func test_no_line_can_flicker_past() -> void:
	# Several steps can be satisfied by an action already in flight — a click
	# landing mid-fade, a key held over from the step before — and the narrative
	# can be clicked through. The floor is what stops a line appearing and
	# vanishing inside a few frames.
	assert_gte(TutorialController._MIN_ON_SCREEN, 0.75,
			"below this a line can be gone before it is read")
	# The floor now sits just ABOVE _DWELL_FLOOR, so the shortest narrative line
	# is paced by it rather than by its own reading time — a tenth of a second,
	# and deliberate. What must stay true is that it can't outlast a LONG line's
	# dwell, or it would be pacing the prose outright.
	assert_lte(TutorialController._MIN_ON_SCREEN, TutorialController._DWELL_CEILING,
			"the floor must not outlast the longest narrative dwell, or it "
			+ "would be the thing pacing the prose instead of the reading time")


func test_the_hover_reticle_is_hidden_until_walking_is_taught() -> void:
	# The in-world cursor says "this cell is a destination". Before the FTUE
	# grants MOVE it isn't one, so the reticle must not be drawn — the same
	# reason the click itself is refused.
	var src := FileAccess.get_file_as_string("res://scripts/systems/ux_overlay.gd")
	assert_false(src.is_empty(), "ux_overlay.gd must be readable")
	assert_true(src.contains("TutorialGate.allows(TutorialGate.Action.MOVE)"),
			"UXOverlay must stop tracking the hovered cell while the FTUE "
			+ "withholds MOVE")


func test_skip_needs_a_deliberate_hold() -> void:
	# The FTUE's skip is irreversible and its button sits over the middle of the
	# screen for the whole tutorial. A click-length press must not reach the
	# threshold; the hold has to be long enough to be a decision.
	assert_gte(TutorialController._SKIP_HOLD, 0.75,
			"a hold shorter than this is an accidental skip waiting to happen")
	assert_lte(TutorialController._SKIP_HOLD, 2.0,
			"a hold longer than this reads as a broken button")
	assert_gt(TutorialController._SKIP_DECAY, 1.0,
			"releasing must drain the bar faster than holding fills it, or a "
			+ "series of stabs at the button accumulates into a skip")


# --- The gate ---------------------------------------------------------------
#
# TutorialGate is a STATIC, so it outlives any one scene and any one test. Every
# test here restores it, and the default it restores to is "everything allowed" —
# a leaked restriction would show up as unrelated suites losing the ability to
# click, buy or build.

func test_the_gate_is_open_by_default() -> void:
	# A run with the FTUE disabled, the balance simulator and every test that
	# never instantiates the controller all go through here.
	for action: int in TutorialGate.Action.values():
		assert_true(TutorialGate.allows(action),
				"action %d must be allowed when nothing has restricted the gate"
				% action)


func test_each_verb_is_blocked_until_the_step_that_teaches_it() -> void:
	# Walks the step list the way a player does, asserting the mask at each one.
	# The property is "cumulative and in step order": a verb is refused before
	# its step, allowed from it, and never taken away again.
	var expected: Dictionary = {
		&"welcome": [],
		&"charge": [],
		&"move": [TutorialGate.Action.MOVE],
		&"journal": [TutorialGate.Action.MOVE, TutorialGate.Action.JOURNAL],
		&"shop": [TutorialGate.Action.MOVE, TutorialGate.Action.JOURNAL,
				TutorialGate.Action.SHOP],
		&"close_journal": [TutorialGate.Action.MOVE, TutorialGate.Action.JOURNAL,
				TutorialGate.Action.SHOP],
		&"build": TutorialGate.Action.values(),
		&"build_endpoint": TutorialGate.Action.values(),
		# The fire arc teaches an action the gate has no bit for: dousing goes
		# through the tile action menu, which BUILD already opened two steps
		# earlier. Nothing to withhold, so nothing here narrows.
		&"roam": TutorialGate.Action.values(),
		&"fire_follow": TutorialGate.Action.values(),
		&"fire_douse": TutorialGate.Action.values(),
		&"closing": TutorialGate.Action.values(),
	}
	var seen: int = 0
	for i: int in TutorialController._STEPS.size():
		var id: StringName = TutorialController._STEPS[i]["id"]
		assert_true(expected.has(id), "step '%s' has no expected mask here" % id)
		if not expected.has(id):
			continue
		seen += 1
		var mask: int = 0
		for action: int in expected[id]:
			mask |= TutorialGate.bit(action)
		TutorialGate.restrict_to(_mask_through(i))
		for action: int in TutorialGate.Action.values():
			assert_eq(TutorialGate.allows(action), (mask & TutorialGate.bit(action)) != 0,
					"at step '%s', action %d is on the wrong side of the gate"
					% [id, action])
	assert_eq(seen, TutorialController._STEPS.size())
	TutorialGate.release()


## The same accumulation TutorialController._granted_mask does, computed here
## from the step table so the two can disagree.
func _mask_through(step: int) -> int:
	var mask: int = 0
	for i: int in step + 1:
		if TutorialController._STEPS[i].has("grants"):
			mask |= TutorialGate.bit(TutorialController._STEPS[i]["grants"])
	return mask


func test_every_taught_verb_is_actually_gated_somewhere() -> void:
	# A verb the FTUE grants but nothing checks is a gate that does nothing. The
	# check is textual because the call sites are spread across four scripts and
	# two of them are input handlers there is no cheap way to drive here.
	const CALL_SITES: Dictionary = {
		TutorialGate.Action.MOVE: "res://scripts/systems/click_to_move_controller.gd",
		TutorialGate.Action.JOURNAL: "res://scripts/ui/field_journal.gd",
		TutorialGate.Action.SHOP: "res://scripts/ui/journal_shop_input.gd",
		TutorialGate.Action.BUILD: "res://scripts/systems/tile_interaction_controller.gd",
	}
	for step: Dictionary in TutorialController._STEPS:
		if not step.has("grants"):
			continue
		var action: int = step["grants"]
		assert_true(CALL_SITES.has(action),
				"step '%s' grants an action with no known call site" % step["id"])
		if not CALL_SITES.has(action):
			continue
		var path: String = CALL_SITES[action]
		var src := FileAccess.get_file_as_string(path)
		assert_false(src.is_empty(), "%s must be readable" % path)
		var needle := "TutorialGate.allows(TutorialGate.Action.%s)" \
				% TutorialGate.Action.keys()[action]
		assert_true(src.contains(needle),
				"%s must refuse the action while the FTUE withholds it (%s)"
				% [path.get_file(), needle])


func test_tutorial_sees_the_click_before_click_to_move_eats_it() -> void:
	# A click ends a narrative line early, via _unhandled_input — which
	# propagates BOTTOM-UP and stops at the first node that consumes.
	# ClickToMoveController consumes it (set_input_as_handled), so the Tutorial
	# node has to come after it in the scene for the click to reach the FTUE at
	# all. Reordering them costs click-to-advance, silently: the line still
	# advances, but only when its dwell runs out.
	var state := (load(BASE_SCENE) as PackedScene).get_state()
	var tutorial: int = -1
	var click_to_move: int = -1
	for i: int in state.get_node_count():
		match state.get_node_name(i):
			"Tutorial":
				tutorial = i
			"ClickToMoveController":
				click_to_move = i
	assert_gt(tutorial, -1, "gameplay_base must carry a Tutorial node")
	assert_gt(click_to_move, -1, "gameplay_base must carry a ClickToMoveController")
	assert_gt(tutorial, click_to_move,
			"Tutorial must sit after ClickToMoveController, or the click that "
			+ "skips a narrative line is consumed before the FTUE sees it")


func test_every_step_signal_still_exists() -> void:
	for id: StringName in STEP_SIGNALS:
		var entry: Array = STEP_SIGNALS[id]
		var script: GDScript = load(entry[0])
		assert_not_null(script, "%s must load" % entry[0])
		if script == null:
			continue
		var names: Array = []
		for s: Dictionary in script.get_script_signal_list():
			names.append(String(s["name"]))
		assert_true(names.has(entry[1]),
				"step '%s' advances off %s.%s, which no longer exists"
				% [id, entry[0].get_file(), entry[1]])


func test_every_step_is_accounted_for_by_one_of_the_two_tables() -> void:
	# The failure this catches is the FTUE's signature one: a step that advances
	# on nothing at all. It is silent — the strip simply sits there forever — and
	# a new step is exactly how it gets introduced.
	for step: Dictionary in TutorialController._STEPS:
		var id: StringName = step["id"]
		assert_true(STEP_SIGNALS.has(id) or UNSIGNALLED_STEPS.has(id),
				"step '%s' names neither a completion signal nor a reason it " % id
				+ "needs none — if it advances on something new, say so in "
				+ "UNSIGNALLED_STEPS")
		assert_false(STEP_SIGNALS.has(id) and UNSIGNALLED_STEPS.has(id),
				"step '%s' is in both tables" % id)


func test_the_douse_step_advances_on_the_fire_actually_going_out() -> void:
	# The player's bucket, rain and a burnout all end the same way from the
	# strip's side, and only ONE of them is a signal the douse action emits —
	# ActionExtinguishFire calls FireManager.extinguish, which is the private
	# _extinguish every other route also funnels through. That is what makes a
	# single signal on the manager the honest place to listen.
	var src := FileAccess.get_file_as_string(
			"res://scripts/systems/actions/action_extinguish_fire.gd")
	assert_false(src.is_empty(), "action_extinguish_fire.gd must be readable")
	assert_true(src.contains("FireManager.extinguish("),
			"the douse action no longer goes through FireManager.extinguish, so "
			+ "the FTUE's fire step will never see it")
	var mgr := FileAccess.get_file_as_string("res://scripts/systems/fire_manager.gd")
	assert_true(mgr.contains("tile_extinguished.emit("),
			"FireManager must report an extinguish, or the step hangs")


func test_the_placement_signals_still_exist() -> void:
	var script: GDScript = load(PLACEMENT_SCRIPT)
	assert_not_null(script, "%s must load" % PLACEMENT_SCRIPT)
	if script == null:
		return
	var names: Array = []
	for s: Dictionary in script.get_script_signal_list():
		names.append(String(s["name"]))
	for signal_name: String in PLACEMENT_SIGNALS:
		assert_true(names.has(signal_name),
				"the build steps hang off TraversalPlacementController.%s, which "
				% signal_name + "no longer exists")


func test_the_second_click_gets_its_own_line_per_traversal() -> void:
	# A ladder, a bridge and a fence are each TWO clicks, and the second one is
	# the half nothing on screen explains. Every type that opens a placement
	# needs a line naming what its x marks mean; the frailejon has no second
	# click and must NOT have one, or the step would be shown pointing at
	# nothing.
	for type: StringName in [&"ladder", &"bridge", &"fence"]:
		assert_true(TutorialController._ENDPOINT_KEYS.has(type),
				"'%s' is placed with a second click but has no line for it" % type)
	assert_false(TutorialController._ENDPOINT_KEYS.has(&"frailejon"),
			"the frailejon is planted by the ring pick itself — no second click")
	# And the step is only ever shown mid-placement.
	for step: Dictionary in TutorialController._STEPS:
		if step["id"] == &"build_endpoint":
			assert_true(bool(step.get("placement_only", false)),
					"the second-click step must be skipped when no placement is open")


func test_only_the_click_steps_carry_a_mouse_glyph() -> void:
	# The glyph exists to disambiguate LEFT from RIGHT, which is the one thing a
	# player can get wrong having read the line correctly. Steps asking for a key
	# (Space) or for nothing (the narrative) must not carry one — a mouse over
	# "press space" teaches the wrong input.
	var expected: Dictionary = {
		&"move": &"left",
		&"build": &"right",
		&"build_endpoint": &"left",
		# The fire arc is the FTUE's second left-then-right pair: walk to it,
		# then open the ring on it.
		&"fire_follow": &"left",
		&"fire_douse": &"right",
	}
	for step: Dictionary in TutorialController._STEPS:
		var id: StringName = step["id"]
		var tag: StringName = step.get("click", &"")
		assert_eq(tag, expected.get(id, &""), "step '%s' click glyph" % id)
		if tag != &"":
			assert_true(TutorialController._CLICK_ICONS.has(tag),
					"step '%s' names a glyph that does not exist" % id)


func test_the_build_step_asks_for_the_button_the_game_listens_on() -> void:
	# The build line is the FTUE's only right-click, and every per-type variant of
	# it says "right click" in both locales. A glyph disagreeing with the copy is
	# worse than no glyph.
	for step: Dictionary in TutorialController._STEPS:
		if step["id"] != &"build":
			continue
		assert_eq(step.get("click", &""), &"right")
		for type: StringName in TutorialController._BUILD_KEYS:
			var key: String = TutorialController._BUILD_KEYS[type]
			for col: int in [1, 2]:
				var line: String = String(_csv_keys[key][col]).to_lower()
				assert_true(line.contains("right click") or line.contains("clic derecho"),
						"%s (col %d) does not ask for a right click" % [key, col])


func test_the_endpoint_step_asks_for_the_button_the_game_commits_on() -> void:
	# The second click of a traversal placement is the FTUE's one place where the
	# button FLIPS mid-action: the right click that opened the ring is answered
	# with a LEFT click on the endpoint. Read off the controller rather than
	# asserted as a constant, because a glyph that disagrees with the code teaches
	# a click the game will ignore — and a right click there CANCELS, so a wrong
	# glyph doesn't merely do nothing, it throws the placement away.
	var src := FileAccess.get_file_as_string(PLACEMENT_SCRIPT)
	assert_false(src.is_empty(), "%s must be readable" % PLACEMENT_SCRIPT)
	assert_true(src.contains("mb.button_index != MOUSE_BUTTON_LEFT"),
			"the endpoint commit is no longer a left click; the FTUE glyph says "
			+ "it is")
	assert_true(src.contains("mb.button_index == MOUSE_BUTTON_RIGHT"),
			"a right click on the endpoint no longer cancels")
	for step: Dictionary in TutorialController._STEPS:
		if step["id"] == &"build_endpoint":
			assert_eq(step.get("click", &""), &"left")
	# And the copy agrees: every endpoint line asks for a plain click, never a
	# right one.
	for type: StringName in TutorialController._ENDPOINT_KEYS:
		var key: String = TutorialController._ENDPOINT_KEYS[type]
		for col: int in [1, 2]:
			var line: String = String(_csv_keys[key][col]).to_lower()
			assert_false(line.contains("right click") or line.contains("clic derecho"),
					"%s (col %d) asks for a right click on a left-click step"
					% [key, col])


func test_every_step_key_is_translated() -> void:
	var keys: Array = ["UI_SKIP_TUTORIAL"]
	for step: Dictionary in TutorialController._STEPS:
		# A quiet step has no copy by design — its own test asserts that.
		if not String(step["key"]).is_empty():
			keys.append(String(step["key"]))
	# The build step swaps in a per-type line; those keys never appear in
	# _STEPS, so the localization scan of scripts/ui is their only other cover.
	for type: StringName in TutorialController._BUILD_KEYS:
		keys.append(String(TutorialController._BUILD_KEYS[type]))
	for type: StringName in TutorialController._ENDPOINT_KEYS:
		keys.append(String(TutorialController._ENDPOINT_KEYS[type]))
	for key: String in keys:
		assert_true(_csv_keys.has(key), "%s missing from paramo.csv" % key)
		if not _csv_keys.has(key):
			continue
		var row: Array = _csv_keys[key]
		for col: int in [1, 2]:
			assert_false(String(row[col]).strip_edges().is_empty(),
					"%s has an empty column %d" % [key, col])
			# Lowercase UI copy, in every language (CLAUDE.md's copy convention).
			# NARRATIVE_* is exempt: the convention covers chrome, and in-world
			# narrative copy is explicitly out of its scope — these are sentences
			# in the park's voice, not labels.
			if key.begins_with("NARRATIVE_"):
				continue
			assert_eq(String(row[col]), String(row[col]).to_lower(),
					"%s column %d must be lowercase" % [key, col])


# --- The opening day --------------------------------------------------------

func test_run_starts_after_dawn() -> void:
	# TitleIntro cuts the clock to day_time_of_day once the curtain is up; that
	# value IS the moment the run starts, and RunController's start_run (which
	# resets to midnight) has already happened by then.
	var scene: PackedScene = load(BASE_SCENE)
	assert_not_null(scene)
	var state := scene.get_state()
	var t: float = -1.0
	for i: int in state.get_node_count():
		if state.get_node_name(i) != "TitleIntro":
			continue
		for p: int in state.get_node_property_count(i):
			if state.get_node_property_name(i, p) == "day_time_of_day":
				t = float(state.get_node_property_value(i, p))
	assert_gt(t, 0.0, "gameplay_base must author TitleIntro.day_time_of_day")
	# TimeManager's dawn window is [0.22, 0.30). Start inside it, late.
	assert_between(t, 0.26, 0.32,
			"the run must open a bit after dawn, not at mid-morning")


func test_no_spontaneous_fire_on_the_opening_day() -> void:
	var restore_day: int = TimeManager.day_count
	var restore_first: int = FireManager.first_ignition_day
	FireManager.first_ignition_day = 1

	TimeManager.day_count = 0
	assert_false(FireManager.spontaneous_ignition_allowed(),
			"the world must not light its own fires on day 0")
	TimeManager.day_count = 1
	assert_true(FireManager.spontaneous_ignition_allowed(),
			"fires must resume once the first day is over")

	TimeManager.day_count = restore_day
	FireManager.first_ignition_day = restore_first


func test_opening_balance_covers_the_cheapest_unlock_and_a_build() -> void:
	# The last FTUE step is "build the tool you just bought". It is only
	# completable if the run opens with SOME unlock price plus at least one
	# tile — the cheapest one, since that is the affordable choice.
	var unlocks := UnlockState.new()
	autofree(unlocks)
	var cheapest: float = INF
	for type: StringName in unlocks.unlock_costs:
		cheapest = minf(cheapest, unlocks.unlock_costs[type])
	assert_gte(float(_season_defaults().starting_tokens),
			cheapest + unlocks.placement_cost_per_tile,
			"starting_tokens must cover the cheapest unlock and at least one "
			+ "placed tile, or the tutorial's build step cannot be finished "
			+ "on day one")


func test_frailejon_is_affordable_at_spawn() -> void:
	# Ladders need an altitude step and bridges need a gap; the frailejon is the
	# only build with no terrain precondition, so it is the FTUE's guaranteed
	# path through the build step whatever the generator dealt. It costs water
	# as well as tokens.
	var unlocks := UnlockState.new()
	autofree(unlocks)
	var due: float = unlocks.unlock_cost_for(&"frailejon") \
			+ unlocks.placement_cost_per_tile
	var season := _season_defaults()
	assert_gte(float(season.starting_tokens), due,
			"a run must open able to buy AND plant one frailejon")
	assert_gte(float(season.starting_water),
			unlocks.water_cost(&"frailejon", 1),
			"planting also spends water from the same opening reserve")


func test_every_buyable_type_has_its_own_build_line() -> void:
	# A type sold in the journal but missing from _BUILD_KEYS falls back to the
	# generic "right click a tile" line, which teaches nothing about what the
	# player just bought — the whole point of the per-type copy.
	var journal: CanvasLayer = autofree(
			load("res://scenes/ui/field_journal.tscn").instantiate())
	for node: Node in journal.find_children("*", "JournalKnownSet", true, false):
		for id_str: String in (node as JournalKnownSet).entry_ids:
			assert_true(TutorialController._BUILD_KEYS.has(StringName(id_str)),
					"'%s' is on sale but has no build-step line" % id_str)


func test_unlock_prices_are_ordered_cheapest_verb_first() -> void:
	var unlocks := UnlockState.new()
	autofree(unlocks)
	assert_eq(unlocks.unlock_cost_for(&"ladder"), 10.0)
	assert_eq(unlocks.unlock_cost_for(&"bridge"), 20.0)
	assert_eq(unlocks.unlock_cost_for(&"fence"), 30.0)
	assert_eq(unlocks.unlock_cost_for(&"nonexistent_type"), unlocks.unlock_cost,
			"an unpriced type must fall back, not cost zero")
