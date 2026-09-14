extends GutTest

# Hotkeys must go quiet while the pause menu is up.
#
# get_tree().paused does most of that for free — the SceneTree skips input on a
# node that can't process — but every node that has to stay alive under pause
# runs PROCESS_MODE_ALWAYS, and those keep hearing keys behind the modal. This
# suite pins both halves: the engine behaviour the rest of the game relies on,
# and the explicit PauseMenu.is_blocking() gate the ALWAYS nodes carry.

const PAUSE_SCENE: PackedScene = preload("res://scenes/ui/pause_menu.tscn")
const JOURNAL_SCENE: PackedScene = preload("res://scenes/ui/field_journal.tscn")

var _pause: PauseMenu


class InputCounter:
	extends Node

	var count: int = 0

	func _unhandled_input(_event: InputEvent) -> void:
		count += 1


func before_each() -> void:
	_pause = PAUSE_SCENE.instantiate()
	add_child_autofree(_pause)


func after_each() -> void:
	# The pause menu freezes the SceneTree, and GUT runs inside it.
	get_tree().paused = false


# Open the modal, then hand the tree straight back: `_blocking` is what the
# hotkey gate reads, and it does not depend on the tree staying frozen. Leaving
# it frozen across a test would stall the runner.
func _open_menu() -> void:
	_pause.open()
	get_tree().paused = false


func _action(name: StringName) -> InputEventAction:
	var ev := InputEventAction.new()
	ev.action = name
	ev.pressed = true
	return ev


# --- The gate itself -----------------------------------------------------------

func test_blocking_tracks_open_state() -> void:
	assert_false(PauseMenu.is_blocking(), "a closed menu blocks nothing")
	_open_menu()
	assert_true(PauseMenu.is_blocking())
	_pause.close()
	assert_false(PauseMenu.is_blocking())


func test_blocking_clears_when_the_menu_leaves_the_tree() -> void:
	# static var is per-PROCESS: a scene reload frees the modal without closing
	# it, and a stale `true` would deafen the next run's hotkeys forever.
	_open_menu()
	_pause.get_parent().remove_child(_pause)
	assert_false(PauseMenu.is_blocking())
	add_child(_pause)   # hand it back so autofree still owns it


# --- The engine assumption everything else leans on ----------------------------

func test_pausable_nodes_get_no_input_while_paused() -> void:
	var counter := InputCounter.new()
	add_child_autofree(counter)
	get_viewport().push_input(_action(&"toggle_journal"))
	assert_eq(counter.count, 1, "a pausable node hears input while the tree runs")

	get_tree().paused = true
	get_viewport().push_input(_action(&"toggle_journal"))
	get_tree().paused = false
	assert_eq(counter.count, 1, "...and hears nothing while it is paused")


func test_always_nodes_still_get_input_while_paused() -> void:
	# The other half of the same fact — and the reason the gate has to exist.
	var counter := InputCounter.new()
	counter.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child_autofree(counter)
	get_tree().paused = true
	get_viewport().push_input(_action(&"toggle_journal"))
	get_tree().paused = false
	assert_eq(counter.count, 1)


# --- The two gated hotkeys -----------------------------------------------------

func test_space_does_not_open_the_journal_behind_the_pause_menu() -> void:
	var journal: FieldJournal = JOURNAL_SCENE.instantiate()
	add_child_autofree(journal)
	var prev: SeasonManager.Phase = SeasonManager.phase
	SeasonManager.phase = SeasonManager.Phase.ACTIVE

	_open_menu()
	journal._input(_action(&"toggle_journal"))
	assert_false(journal.visible, "Space is the pause menu's while it is up")

	_pause.close()
	journal._input(_action(&"toggle_journal"))
	assert_true(journal.visible, "...and the journal's again once it is gone")
	journal.close()
	get_tree().paused = false
	SeasonManager.phase = prev


func test_keys_do_not_advance_an_ftue_line_behind_the_pause_menu() -> void:
	# Never added to the tree: _ready would build the whole strip UI. The
	# handler under test only reads _running / _step.
	var tut: TutorialController = autofree(TutorialController.new())
	tut._running = true
	tut._step = 0
	assert_true(tut._is_narrative(), "step 0 must be a narrative line for this test")

	var key := InputEventKey.new()
	key.keycode = KEY_ENTER
	key.pressed = true

	_open_menu()
	tut._unhandled_input(key)
	assert_eq(tut._step_progress, 0, "a keystroke aimed at the modal burns no line")

	_pause.close()
	tut._unhandled_input(key)
	assert_eq(tut._step_progress, 1, "...but it advances the line otherwise")
