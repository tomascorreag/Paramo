class_name TutorialController
extends CanvasLayer

## The first-time-user experience: a hint strip that opens the run in the
## park's voice (two narrative lines), teaches the verbs of the game in the
## order the player needs them — walk, open the journal, buy a tool, close the
## journal, build it — then gets out of the way, lets a fire start where the
## player can't see it, and teaches the last verb by making them go and put it
## out. A third narrative line signs off.
##
## The fire arc is the one part of this that acts on the world rather than
## describing it. It is three steps: a QUIET one with no copy at all (the strip
## is gone and the player has the mountain), then a fire lit off-screen that the
## player follows the screen-edge aura to, then the douse. See the "the fire
## arc" constant block, and dev-notes/ftue.md.
##
## Built in code (the layout is data-driven off `_STEPS`, so it belongs in the
## code-built UI family alongside radial_menu.gd, not in a .tscn): a panel at
## bottom-center holding one wrapped line of copy, with a HOLD-TO-SKIP button
## in its own row below it, clear of the panel. Never pauses the game — the world
## keeps running underneath, which is the whole point of an FTUE that is supposed
## to feel smooth. It does gate the game's verbs (see TutorialGate): a verb the
## strip has not introduced yet does nothing, so the player cannot get ahead of
## the lesson or complete a step before being asked for it.
##
## The copy is the whole instruction, plus one glyph. An earlier version also drew
## a pulsing outline around the thing to click (the journal button, a target
## cell); it was removed as noise — the lines are short enough to be unambiguous,
## and a rectangle chasing the cursor competes with the world it is pointing into.
## What stayed is a MOUSE glyph leading the two steps that ask for a click, left
## or right button cut out of it (`_CLICK_ICONS`): left/right is the one thing in
## this FTUE that a player can get wrong while having read the line correctly,
## and it is the part a glyph carries better than a word in a second language.
##
## Advancing is signal-driven, never polled: each instruction step names the
## signal that proves the player did the thing. There is no "close enough"
## heuristic and no timer — a step ends when the game itself reports the action.
## The narrative steps are the one exception, because there is no action to
## report: they hold for a dwell computed from the length of the line, and any
## key or click ends them early.
##
## Layer TUTORIAL (150) sits ABOVE the journal, because two of its steps are read
## with the book open, and PROCESS_MODE_ALWAYS keeps the strip animating while
## the journal holds get_tree().paused — same trick as PauseMenu and FieldJournal.
##
## Runs on EVERY run (no persistence): this is a vertical slice that gets demoed
## from a cold boot repeatedly, and a first-run flag in user://settings.cfg would
## make the common case the untested one. The skip button on every panel is what
## makes that acceptable — and because it sits under the strip for the whole
## FTUE, and ending the FTUE cannot be undone, it is a HOLD rather
## than a click: a fill sweeps across it while the button is down and fires at
## the far edge, draining back if released. `pressed` is never connected.

const GROUP: StringName = &"tutorial"

const _FRAME_STYLEBOX: StyleBox = preload("res://resources/ui/styleboxes/frame_border.tres")

## Which mouse button a step's line asks for, by the step's `click` tag. The two
## glyphs are the same 16px mouse with a different button cut out of it, so left
## and right are told apart by SHAPE and not by a label — which is the point: the
## copy already says "click" or "right click" in words, in a language the player
## may be reading at speed, and the glyph is the part that survives skimming.
const _CLICK_ICONS: Dictionary = {
	&"left": preload("res://assets/sprites/UX/icons/click.tres"),
	&"right": preload("res://assets/sprites/UX/icons/rightclick.tres"),
}

## Air between the glyph and the copy it belongs to.
const _CLICK_GAP: int = 5

## Strip geometry, in logical pixels (the viewport is window/N — see
## DisplayManager — so 200 is a fixed fraction of nothing; it is simply a
## readable measure at 8px Tiny5). Height comes from the content, not from here:
## Spanish runs ~25% longer and the copy wraps, so a pinned height would clip it.
const _STRIP_WIDTH: float = 200.0
const _STRIP_MARGIN_BOTTOM: float = 8.0
## Clear air between the strip and the skip button under it.
const _SKIP_GAP: float = 5.0

const _FADE: float = 0.25
## Beat between "you did it" and the next line appearing. Long enough to read as
## a response to the action rather than as a jump cut.
const _ADVANCE_DELAY: float = 0.45

## No line leaves the screen before this many seconds, however fast the player
## satisfies it. Several steps can be completed by an action already in flight —
## a click mid-fade dispatches a path, the journal opens on a key held from the
## step before — and a line that appears and vanishes inside a few frames reads
## as a flicker rather than as instruction. Applies to the narrative's
## click-to-continue too, so a player mashing through the opening still sees
## every line.
const _MIN_ON_SCREEN: float = 2.5

## Narrative dwell = floor + per-character, clamped. Per-character rather than a
## flat number because Spanish runs ~25% longer than English and would otherwise
## be given the same time to read a longer line; this makes the two locales pace
## themselves. 20 chars/second is a slow-ish read, which is what a line you see
## once should get; the ceiling is there because three lines at the floor plus
## per-char is already ~20 s of prose before the player is asked to do anything,
## and that is the budget.
const _DWELL_FLOOR: float = 2.4
const _DWELL_PER_CHAR: float = 0.05
const _DWELL_CEILING: float = 8.0

## How long the skip button has to be held down. Long enough that a stray click
## on a button parked in the middle of the screen cannot end the FTUE, short
## enough that a player who means it doesn't wonder whether it's broken.
const _SKIP_HOLD: float = 1.1
## Release drains the bar this many times faster than holding fills it: fast
## enough to read as "let go and it's off", slow enough to be seen happening.
const _SKIP_DECAY: float = 4.0

# --- The fire arc -----------------------------------------------------------
#
# After the build step the FTUE goes quiet, the player walks the mountain for a
# while, and then a fire starts somewhere they can't see. The screen-edge aura
# (FireAuraOverlay) is already in the game and already points at off-screen
# fires; this arc exists to make the player meet it once, deliberately, before
# a real fire does it for them.

## How long the strip stays gone before the fire starts. Long enough to stop
## reading as part of the tutorial's rhythm and start reading as play — the
## player has to have LOOKED AWAY from the bottom of the screen for the aura to
## be the thing that gets their attention back.
const _ROAM_SECONDS: float = 12.0

## Fuel the scripted fire is given, against FireDynamics' default of 1.0 (~10 s
## of burn). The player has to notice the glow, read the line, cross most of a
## screen and right-click — 10 s is not that, and a fire that burns out on the
## way teaches nothing. 30 is ~4 minutes at full intensity: not a timer the
## player can feel, which is the point.
const _FIRE_FUEL: float = 30.0

## Where the fire is lit, as a signed distance BEYOND the edge of the screen in
## screen-heights (the same metric FireAuraOverlay shapes its glow with, so
## these are directly comparable to its EDGE_HOLD/REACH).
##
## _TARGET is what the search aims at: far enough out that the fire itself is
## invisible and only the aura reports it, near enough that the aura is strong
## (the overlay's REACH is 0.9, past which a fire contributes nothing at all —
## a fire lit beyond it would leave the player with no indicator to follow).
## _MIN is the floor for "genuinely off screen"; _MAX keeps the walk sane.
const _FIRE_TARGET_OFFSCREEN: float = 0.35
const _FIRE_MIN_OFFSCREEN: float = 0.10
const _FIRE_MAX_OFFSCREEN: float = 0.60

## However the camera is framed, never light a fire within this many cells of
## the player. The screen metric above is the real test; this is the guard
## against a camera state that makes a neighbouring cell read as off-screen.
const _FIRE_MIN_CELLS: int = 4

## How far INSIDE the frame the fire has to come before the follow step counts
## as done. Not zero: a fire whose flame is half off the edge has been found in
## the sense that matters, and holding the line until it is dead centre asks the
## player to keep walking past the thing they were sent to.
const _FIRE_ONSCREEN_INSET: float = 0.12

# Ordered. `key` is a TRANSLATION KEY — it is assigned to Label.text verbatim so
# the line re-translates itself if the locale changes mid-step (see CLAUDE.md:
# a `tr()`-ed string would freeze that label in one language).
#
# A step with "narrative": true has no completion signal and teaches no verb; it
# is the park talking. They bracket the instructions rather than interleave with
# them — prose between two things you are being asked to do reads as an
# interruption, prose before the first and after the last reads as a frame.
#
# "grants" is the verb the step TEACHES, and the game does not accept that verb
# until this step is on screen (TutorialGate). The mask is cumulative over every
# step shown so far, so nothing that has been taught is ever taken away again —
# and the opening narrative, granting nothing, means the run starts with the
# player able to read and nothing else.
const _STEPS: Array[Dictionary] = [
	{"id": &"welcome", "key": "NARRATIVE_WELCOME", "narrative": true},
	{"id": &"charge", "key": "NARRATIVE_CHARGE", "narrative": true},
	# Two walks, not one. The first click is often a mis-click or a one-tile
	# nudge, and a player who has moved once has not yet learned that the
	# ground is a destination — the second one is where it becomes a verb.
	{
		"id": &"move", "key": "TUTORIAL_MOVE",
		"grants": TutorialGate.Action.MOVE, "repeat": 2, "click": &"left",
	},
	{"id": &"journal", "key": "TUTORIAL_JOURNAL", "grants": TutorialGate.Action.JOURNAL},
	{"id": &"shop", "key": "TUTORIAL_SHOP", "grants": TutorialGate.Action.SHOP},
	# The way out of the journal is the one thing here a player cannot discover
	# by looking: the book covers the screen and its close affordances (Space
	# again, Esc, a click on the scrim) are all invisible. Its own step.
	{"id": &"close_journal", "key": "TUTORIAL_CLOSE_JOURNAL"},
	# `key` is the fallback; the real line is picked per bought type by
	# _step_key (see _BUILD_KEYS).
	{
		"id": &"build", "key": "TUTORIAL_BUILD",
		"grants": TutorialGate.Action.BUILD, "click": &"right",
	},
	# A ladder, a bridge and a fence are all TWO clicks: the right click above
	# only opens the ring, and picking the tool from it starts a placement that
	# a second, LEFT click has to land. Nothing on screen says so — the ghost
	# and the x marks appear and the player is holding a half-built thing — so
	# the second click gets its own line. Skipped whole for a build that has no
	# second click (the frailejon is planted by the ring pick itself), which is
	# what "placement_only" means.
	{
		"id": &"build_endpoint", "key": "TUTORIAL_ENDPOINT",
		"placement_only": true, "click": &"left",
	},
	# A held beat with NOTHING on screen. The verbs are all taught by now, the
	# strip is gone, and the player has the mountain to themselves for
	# _ROAM_SECONDS. It is the only step with no copy, and that is its content:
	# an FTUE that never lets go teaches the player to wait for the next line
	# instead of to look at the world. It also buys the distance the next step
	# needs — the fire is lit where the player ISN'T, and where that is depends
	# on where they wandered.
	{"id": &"roam", "key": "", "quiet": true},
	# The fire is already burning when this line appears (lit on the way out of
	# `roam`, so the screen-edge aura is up before the copy explains it). Both
	# fire steps are "fire_only": if no cell could be lit, the whole arc is
	# stepped over rather than pointing at a fire that isn't there.
	{"id": &"fire_follow", "key": "TUTORIAL_FIRE_FOLLOW", "fire_only": true, "click": &"left"},
	{"id": &"fire_douse", "key": "TUTORIAL_FIRE_DOUSE", "fire_only": true, "click": &"right"},
	{"id": &"closing", "key": "NARRATIVE_CLOSING", "narrative": true},
]

## Build-step copy per unlocked type. A ladder and a fence are told apart by
## nothing the player has seen yet, and "right click a tile" teaches neither —
## so the line names what the thing is FOR and where it goes. Types absent here
## fall back to the step's own generic `key`.
const _BUILD_KEYS: Dictionary = {
	&"ladder": "TUTORIAL_BUILD_LADDER",
	&"bridge": "TUTORIAL_BUILD_BRIDGE",
	&"fence": "TUTORIAL_BUILD_FENCE",
	&"frailejon": "TUTORIAL_BUILD_FRAILEJON",
	&"espeletia_barclayana": "TUTORIAL_BUILD_ESPELETIA_BARCLAYANA",
	&"espeletia_hartwegiana": "TUTORIAL_BUILD_ESPELETIA_HARTWEGIANA",
	&"hypericum": "TUTORIAL_BUILD_HYPERICUM",
	&"arcytophyllum": "TUTORIAL_BUILD_ARCYTOPHYLLUM",
}

## Second-click copy per type, on the same fallback rule as _BUILD_KEYS. Each
## says what the x marks MEAN for that structure, which is the part the marks
## themselves can't: the ladder's are landings on top of the ledge, the bridge's
## are the far bank, the fence's are the end of the run.
const _ENDPOINT_KEYS: Dictionary = {
	&"ladder": "TUTORIAL_ENDPOINT_LADDER",
	&"bridge": "TUTORIAL_ENDPOINT_BRIDGE",
	&"fence": "TUTORIAL_ENDPOINT_FENCE",
}

## Turn the whole FTUE off for a build (or a test scene) without deleting the node.
@export var enabled: bool = true

var _step: int = -1
var _running: bool = false
var _finished: bool = false
var _advancing: bool = false
## Seconds the current line has been up. Ticked in _process, which is
## PROCESS_MODE_ALWAYS, so it keeps running while the journal holds the tree
## paused — two steps are read inside that pause.
var _step_elapsed: float = 0.0
## How many times the current step's completion has fired, against its "repeat".
var _step_progress: int = 0
## Completed, but held back by _MIN_ON_SCREEN. The step's signal is already
## disconnected at this point; only the hand-off is waiting.
var _completion_pending: bool = false

var _strip: Control
var _label: Label
## The mouse glyph leading the copy, shown only on steps that ask for a click.
var _click_glyph: TextureRect
var _skip_button: Button
## The sweep that fills the skip button while it is held.
var _skip_fill: NinePatchRect
var _skip_held: bool = false
var _skip_hold: float = 0.0

## What the shop step bought, so the build step can name it. Empty until then.
var _bought_type: StringName = &""

## The cell the scripted fire was lit on, or NO_CELL for "there isn't one" —
## which is both the state before the roam step ends AND the state after a
## failed search, and is what makes the two fire steps skip themselves.
var _fire_cell: Vector2i = Pathfinder.NO_CELL

# Scene peers, resolved by group once the run is live.
var _click_to_move: Node
var _journal: Node
var _unlocks: Node
var _traversal: Node
var _pathfinder: Node
var _player: Node


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = UILayers.TUTORIAL
	add_to_group(GROUP)
	if not enabled:
		set_process(false)
		return
	_build_ui()
	_strip.modulate.a = 0.0
	_skip_button.modulate.a = 0.0
	visible = false


# Two gates before the first line shows: the opening cinematic must be gone
# (TitleIntro hides the HUD for its duration and frees itself at the end, so its
# group emptying is the honest "the player has the world now" signal), and the
# run must actually be ACTIVE — RunController holds start_run() until the
# language gate is answered.
func _process(delta: float) -> void:
	if _finished:
		return
	if not _running:
		if get_tree().get_nodes_in_group(&"title_intro").is_empty() \
				and SeasonManager.phase == SeasonManager.Phase.ACTIVE:
			_begin()
		return
	if not _advancing:
		_step_elapsed += delta
		if _completion_pending and _step_elapsed >= _MIN_ON_SCREEN:
			_completion_pending = false
			_advance()
		_tick_fire_follow()
	_tick_skip_hold(delta)


## The follow step is the FTUE's ONE polled completion, and the exception proves
## the rule the rest of the table follows: "the fire is on screen now" is not an
## event any system in this game emits — it is a relationship between a camera
## that moves continuously and a cell that doesn't. There is nothing to connect
## to, so it is read, once a frame, off the same canvas transform
## FireAuraOverlay projects its fires with.
##
## It also covers the fire going out from under the step (rain, or a douse the
## player somehow landed early): the arc is dropped rather than left asking the
## player to walk to a fire that isn't burning.
func _tick_fire_follow() -> void:
	if _current_id() != &"fire_follow" or _fire_cell == Pathfinder.NO_CELL:
		return
	if not FireManager.is_burning(_fire_cell):
		_fire_cell = Pathfinder.NO_CELL
		_complete_step()
		return
	if _fire_is_on_screen():
		_complete_step()


# --- Lifecycle --------------------------------------------------------------

func _begin() -> void:
	_running = true
	visible = true
	_resolve_peers()
	_show_step(0)


func _show_step(index: int) -> void:
	if _finished:
		return
	_step = index
	if _step >= _STEPS.size():
		_finish()
		return
	# A step that doesn't apply is stepped over, not shown empty. Looped rather
	# than recursed only so a table of nothing-but-inapplicable steps ends the
	# FTUE instead of the stack.
	while _step < _STEPS.size() and not _step_applies():
		_step += 1
	if _step >= _STEPS.size():
		_finish()
		return
	_advancing = false
	_step_elapsed = 0.0
	_step_progress = 0
	_completion_pending = false
	TutorialGate.restrict_to(_granted_mask())
	_label.text = _step_key()
	_apply_click_glyph()
	_connect_step_signal()
	# A quiet step fades the strip AWAY and leaves it away — it has no copy, and
	# an empty panel sitting at the bottom of the screen is worse than no panel.
	# The skip button goes with it: it is the tutorial's control, and for these
	# seconds there is no tutorial on screen to end.
	_fade_strip_to(0.0 if _is_quiet() else 1.0)
	if _is_narrative():
		_start_dwell()
	elif _is_quiet():
		_arm_step_timer(_ROAM_SECONDS)


## The mouse button the current step asks for, or `&""` for the steps that ask
## for a key (the journal is Space) or for nothing at all (the narrative).
func click_tag() -> StringName:
	if _step < 0 or _step >= _STEPS.size():
		return &""
	return _STEPS[_step].get("click", &"")


func _apply_click_glyph() -> void:
	if _click_glyph == null:
		return
	var tag := click_tag()
	_click_glyph.visible = _CLICK_ICONS.has(tag)
	if _click_glyph.visible:
		var tex: Texture2D = _CLICK_ICONS[tag]
		_click_glyph.texture = tex
		# make_icon_sized pinned the minimum to the texture it was BUILT with, and
		# this node outlives that texture — a glyph authored at another size would
		# otherwise be squeezed into the first one's box.
		_click_glyph.custom_minimum_size = tex.get_size()


## Everything granted by the current step and every step before it. Recomputed
## rather than accumulated, so the mask is a pure function of where the FTUE is.
func _granted_mask() -> int:
	var mask: int = 0
	for i: int in mini(_step + 1, _STEPS.size()):
		if _STEPS[i].has("grants"):
			mask |= TutorialGate.bit(_STEPS[i]["grants"])
	return mask


## Whether the current step has anything to say right now. Two steps can answer
## no. The second-click step exists for the traversals, and asking a player who
## just planted a frailejon to "click one of the x marks" would point at nothing
## — read off the placement controller's live state rather than off
## `_bought_type`, because what decides whether a second click is coming is
## whether a placement is actually open. The two fire steps answer no when no
## fire could be lit at all: a generator that dealt no reachable grass in range,
## or a player boxed in by rock and water.
##
## Deliberately NOT "and the fire is still burning" — a step's applicability is
## decided once, when it is shown, and a fire that goes out later is handled
## where it happens (_tick_fire_follow for the follow step, the douse step's own
## signals for the douse). Folding a live world query in here would also make
## the step unrenderable by preview_tutorial_strip.gd, which has no fire.
func _step_applies() -> bool:
	var step: Dictionary = _STEPS[_step]
	if bool(step.get("placement_only", false)):
		return _traversal != null and bool(_traversal.call(&"is_placing"))
	if bool(step.get("fire_only", false)):
		return _fire_cell != Pathfinder.NO_CELL
	return true


func _is_narrative() -> bool:
	return _step >= 0 and _step < _STEPS.size() \
			and bool(_STEPS[_step].get("narrative", false))


## A step with no copy, whose content is the absence of the strip.
func _is_quiet() -> bool:
	return _step >= 0 and _step < _STEPS.size() \
			and bool(_STEPS[_step].get("quiet", false))


## The id of the step on screen, or `&""` outside the table.
func _current_id() -> StringName:
	if _step < 0 or _step >= _STEPS.size():
		return &""
	return _STEPS[_step]["id"]


## A narrative line has no action to wait on, so it waits on the clock instead —
## reading time for the TRANSLATED line, so the longer Spanish gets longer. The
## timer is bound to the step that started it: it outlives that step if the
## player clicks through early, and would otherwise complete whatever step is up
## when it lands.
func _start_dwell() -> void:
	var line: String = tr(_label.text)
	_arm_step_timer(clampf(
			_DWELL_FLOOR + line.length() * _DWELL_PER_CHAR,
			_DWELL_FLOOR, _DWELL_CEILING))


## Complete the step that is up in `seconds`, unless something else completes it
## first. Bound to the step INDEX, so a timer that outlives its step (the player
## clicked a narrative line through) can't complete whatever is up when it lands.
## Shared by the narrative's reading dwell and the roam step's fixed hold.
func _arm_step_timer(seconds: float) -> void:
	var timer := get_tree().create_timer(seconds, true)
	timer.timeout.connect(_on_dwell_elapsed.bind(_step))


func _on_dwell_elapsed(index: int) -> void:
	if _step == index:
		_complete_step()


## Any key or click ends a narrative line early. Deliberately does NOT consume
## the event: the FTUE never takes input away from the game, and the click that
## skips the last narrative line is also the click that starts the walk the next
## step is about to ask for.
##
## _unhandled_input, not _input, so a press on the skip button (a Control, which
## eats GUI input before this stage) doesn't also advance the line. The cost is
## an ORDER dependency: unhandled input propagates bottom-up, and
## ClickToMoveController DOES consume the click — so `Tutorial` has to sit after
## it in gameplay_base.tscn to see one at all. `test_tutorial.gd` asserts that.
func _unhandled_input(event: InputEvent) -> void:
	if not _running or not _is_narrative():
		return
	# ANY key advances a line, and this layer is PROCESS_MODE_ALWAYS — so without
	# this, every keystroke aimed at the pause menu would also burn an FTUE line
	# the player never read. The journal's pause is a different case and stays
	# live: two steps are read inside it.
	if PauseMenu.is_blocking():
		return
	var pressed: bool = (event is InputEventKey and event.is_pressed() and not event.is_echo()) \
			or (event is InputEventMouseButton and event.is_pressed())
	if pressed:
		_complete_step()


## The translation key for the current step. Only the build step varies: it
## names the type the shop step bought, falling back to the generic line if the
## player somehow reached it having bought something unlisted.
func _step_key() -> String:
	var step: Dictionary = _STEPS[_step]
	if step["id"] == &"build" and _BUILD_KEYS.has(_bought_type):
		return String(_BUILD_KEYS[_bought_type])
	if step["id"] == &"build_endpoint" and _ENDPOINT_KEYS.has(_bought_type):
		return String(_ENDPOINT_KEYS[_bought_type])
	return String(step["key"])


## Called from the step's completion signal (or its dwell timer). Two things can
## still hold the line on screen: a "repeat" count not yet reached, and the
## _MIN_ON_SCREEN floor. The signal is disconnected as soon as the count IS
## reached, so a second click / a second purchase during the wait or the hand-off
## beat can't double-advance.
func _complete_step() -> void:
	if _advancing or _completion_pending or not _running:
		return
	_step_progress += 1
	if _step_progress < int(_STEPS[_step].get("repeat", 1)):
		return
	_disconnect_step_signal()
	if _step_elapsed < _MIN_ON_SCREEN:
		_completion_pending = true
		return
	_advance()


## The hand-off: fade this line out, and bring the next one up after a beat.
func _advance() -> void:
	_advancing = true
	_fade_strip_to(0.0)
	# Light the fire on the way OUT of the roam step rather than on the way into
	# the step that talks about it: the aura then comes up during the hand-off
	# beat, so the glow is already on the edge of the screen when the line
	# explaining it appears. The other order has the player reading about a fire
	# that starts a moment later, which reads as the tutorial causing it.
	if _current_id() == &"roam":
		_light_the_fire()
	var next: int = _step + 1
	# process_always so the beat still elapses when the step that just completed
	# left the tree paused (opening the journal does exactly that).
	var timer := get_tree().create_timer(_ADVANCE_DELAY + _FADE, true)
	timer.timeout.connect(_show_step.bind(next))


func _finish() -> void:
	_finished = true
	_running = false
	_disconnect_step_signal()
	TutorialGate.release()
	set_process(false)
	# Free rather than hide: nothing here has a second act, and a live
	# PROCESS_MODE_ALWAYS Control that redraws every frame is not free.
	queue_free()


## The gate is a static, so it outlives this node. Reopening it here rather than
## only in _finish covers every other way the controller can leave: a scene
## change mid-FTUE, a restart from the pause menu, a preview tool tearing the
## strip down between states. None of those should leave the next run unable to
## walk.
func _exit_tree() -> void:
	TutorialGate.release()


## The skip button, and the public way for anything else to end the FTUE.
func skip() -> void:
	if _finished:
		return
	_finish()


# --- Step completion wiring -------------------------------------------------
#
# One signal per step, each one the game's own report that the action happened —
# no polling, no proximity guessing.

func _connect_step_signal() -> void:
	match _STEPS[_step]["id"]:
		&"move":
			if _click_to_move != null:
				_click_to_move.connect(&"path_dispatched", _on_moved)
		&"journal":
			if _journal != null:
				_journal.connect(&"opened", _complete_step)
		&"shop":
			if _unlocks != null:
				_unlocks.connect(&"unlock_changed", _on_unlocked)
		&"close_journal":
			if _journal != null:
				_journal.connect(&"closed", _complete_step)
		&"build":
			# Two exits, whichever comes first. A traversal leaves this step by
			# OPENING its second click (nothing is paid for yet); a frailejon
			# never opens one and leaves by being paid for. _complete_step
			# disconnects both, so the loser can't fire into the next step.
			if _unlocks != null:
				_unlocks.connect(&"placement_paid", _on_placed)
			if _traversal != null:
				_traversal.connect(&"placement_began", _on_placement_began)
		&"build_endpoint":
			if _unlocks != null:
				_unlocks.connect(&"placement_paid", _on_placed)
			# Escape or a right-click drops the placement without building. The
			# line asking for the second click has to come down with it, so the
			# step rewinds to the one that opens the ring rather than waiting on
			# a click the player can no longer make.
			if _traversal != null:
				_traversal.connect(&"placement_ended", _on_placement_ended)
		&"fire_douse":
			# Two exits again, and only one of them is the lesson. `extinguished`
			# is the player's bucket (and rain, which is the same outcome from the
			# player's side: the fire is out and the line must come down).
			# `tile_burned` is the fire finishing its tile — it cannot happen
			# inside four minutes at _FIRE_FUEL, but a step whose only exit is an
			# action on an object that can cease to exist is a strip that hangs.
			FireManager.tile_extinguished.connect(_on_fire_gone)
			FireManager.tile_burned.connect(_on_fire_burned)
			# The fire can also have gone out during the hand-off beat, in the
			# gap between the follow step's last poll and this connection —
			# rain, at the wrong second. Deferred so the step is fully shown
			# before it completes (and so _MIN_ON_SCREEN still applies), and
			# harmless outside a live run, where _complete_step returns on
			# `_running`.
			if not FireManager.is_burning(_fire_cell):
				call_deferred(&"_complete_step")


func _disconnect_step_signal() -> void:
	if _step < 0 or _step >= _STEPS.size():
		return
	match _STEPS[_step]["id"]:
		&"move":
			if _click_to_move != null and _click_to_move.is_connected(
					&"path_dispatched", _on_moved):
				_click_to_move.disconnect(&"path_dispatched", _on_moved)
		&"journal":
			if _journal != null and _journal.is_connected(&"opened", _complete_step):
				_journal.disconnect(&"opened", _complete_step)
		&"shop":
			if _unlocks != null and _unlocks.is_connected(&"unlock_changed", _on_unlocked):
				_unlocks.disconnect(&"unlock_changed", _on_unlocked)
		&"close_journal":
			if _journal != null and _journal.is_connected(&"closed", _complete_step):
				_journal.disconnect(&"closed", _complete_step)
		&"build":
			if _unlocks != null and _unlocks.is_connected(&"placement_paid", _on_placed):
				_unlocks.disconnect(&"placement_paid", _on_placed)
			if _traversal != null and _traversal.is_connected(
					&"placement_began", _on_placement_began):
				_traversal.disconnect(&"placement_began", _on_placement_began)
		&"build_endpoint":
			if _unlocks != null and _unlocks.is_connected(&"placement_paid", _on_placed):
				_unlocks.disconnect(&"placement_paid", _on_placed)
			if _traversal != null and _traversal.is_connected(
					&"placement_ended", _on_placement_ended):
				_traversal.disconnect(&"placement_ended", _on_placement_ended)
		&"fire_douse":
			if FireManager.tile_extinguished.is_connected(_on_fire_gone):
				FireManager.tile_extinguished.disconnect(_on_fire_gone)
			if FireManager.tile_burned.is_connected(_on_fire_burned):
				FireManager.tile_burned.disconnect(_on_fire_burned)


func _on_moved(_cells: Array) -> void:
	_complete_step()


func _on_placement_began(_kind: StringName) -> void:
	_complete_step()


## The placement closed. On `built` this step has already been completed by
## `placement_paid` (which fires first, inside the same click) and this
## connection is gone; reaching here means it was abandoned, so the FTUE goes
## back to the line that opens the ring.
func _on_placement_ended(_kind: StringName, built: bool) -> void:
	if built or _advancing or _completion_pending or not _running:
		return
	_disconnect_step_signal()
	_show_step(_step - 1)


func _on_unlocked(type: StringName) -> void:
	_bought_type = type
	_complete_step()


func _on_placed(_type: StringName, _count: int) -> void:
	_complete_step()


## Any fire went out, not only the scripted one — a player who found a second
## fire and doused that instead has learned the verb the step is teaching, and
## refusing to advance because they aimed at the wrong flame would be pedantry.
func _on_fire_gone(_cell: Vector2i) -> void:
	_complete_step()


func _on_fire_burned(cell: Vector2i, _coord: Vector2i, _layer: TileMapLayer) -> void:
	# Only the scripted fire finishing counts: any OTHER tile burning out is a
	# fire the player hasn't been asked about.
	if cell == _fire_cell:
		_complete_step()


# --- The fire arc -----------------------------------------------------------

## Start the scripted fire, or leave `_fire_cell` at NO_CELL and let both fire
## steps skip themselves. Contained (it never spreads) and over-fuelled (it
## outlasts the walk) — see FireManager.ignite for why those two concessions
## exist and why nothing else can reach them.
func _light_the_fire() -> void:
	_fire_cell = _pick_fire_cell()
	if _fire_cell == Pathfinder.NO_CELL:
		return
	if not FireManager.ignite(_fire_cell, true, _FIRE_FUEL):
		# can_ignite passed during the search and the ignition still didn't take
		# (no grass source on the tileset, a null CellData). Treat it as no fire.
		_fire_cell = Pathfinder.NO_CELL


## Where to light it: a cell the player can WALK to, that will BURN, and that is
## off the edge of the screen but still inside the reach of the screen-edge aura
## — because the aura is the only thing that will tell the player it exists.
##
## Reachability comes from the pathfinder's own flood fill, so the answer can
## never be a fire across a ravine; burnability from FireManager.can_ignite, so
## it can never be water, rock or dirt. What is left is ranked on ONE number:
## how far beyond the edge of the screen the cell sits, against
## _FIRE_TARGET_OFFSCREEN.
##
## The fallback is deliberate rather than an accident of the ranking: if nothing
## sits in the off-screen band (a wide window, a player standing at the edge of
## the mountain), take the FARTHEST burnable cell there is instead. That is the
## widest search this can do, and it still walks the player somewhere; if even
## that finds nothing, the arc is skipped whole and the FTUE closes as it did
## before it existed.
func _pick_fire_cell() -> Vector2i:
	if _pathfinder == null or not is_instance_valid(_pathfinder) \
			or _player == null or not is_instance_valid(_player):
		return Pathfinder.NO_CELL
	var anchor: Vector2i = _player.get(&"current_cell")
	# reachable_from hands back its own cached dictionary — read, never mutate.
	var reachable: Dictionary = _pathfinder.call(&"reachable_from", anchor)

	var best: Vector2i = Pathfinder.NO_CELL
	var best_error: float = INF
	var fallback: Vector2i = Pathfinder.NO_CELL
	var fallback_sd: float = -INF

	for cell: Vector2i in reachable:
		if maxi(absi(cell.x - anchor.x), absi(cell.y - anchor.y)) < _FIRE_MIN_CELLS:
			continue
		if not FireManager.can_ignite(cell):
			continue
		var sd: float = _cell_offscreen_distance(cell)
		if sd > fallback_sd:
			fallback_sd = sd
			fallback = cell
		if sd < _FIRE_MIN_OFFSCREEN or sd > _FIRE_MAX_OFFSCREEN:
			continue
		var error: float = absf(sd - _FIRE_TARGET_OFFSCREEN)
		if error < best_error:
			best_error = error
			best = cell
	return best if best != Pathfinder.NO_CELL else fallback


## Is the fire far enough inside the frame to count as found?
func _fire_is_on_screen() -> bool:
	if _fire_cell == Pathfinder.NO_CELL:
		return false
	var uv: Vector2 = _cell_screen_uv(_fire_cell)
	return uv.x > _FIRE_ONSCREEN_INSET and uv.x < 1.0 - _FIRE_ONSCREEN_INSET \
			and uv.y > _FIRE_ONSCREEN_INSET and uv.y < 1.0 - _FIRE_ONSCREEN_INSET


## How far `cell` sits BEYOND the edge of the screen, in screen-heights:
## positive outside (euclidean, so corners are handled), negative inside
## (distance to the nearest edge). The same signed distance FireAuraOverlay
## shapes its glow with, computed the same way, so a cell scored here at 0.35
## is a cell the aura will light at 0.35 of its falloff.
func _cell_offscreen_distance(cell: Vector2i) -> float:
	var uv: Vector2 = _cell_screen_uv(cell)
	var dx: float = maxf(maxf(-uv.x, uv.x - 1.0), 0.0)
	var dy: float = maxf(maxf(-uv.y, uv.y - 1.0), 0.0)
	var outside: float = sqrt(dx * dx + dy * dy)
	if outside > 0.0:
		return outside
	return -minf(minf(uv.x, 1.0 - uv.x), minf(uv.y, 1.0 - uv.y))


## A cell's position in normalized screen space: 0..1 on screen, outside it off.
## Built from the viewport's canvas transform rather than from a camera node, so
## it is correct whichever camera is current (the free-camera debug mode swaps
## it). The altitude lift is the same one UXOverlay.cell_visual_center applies —
## without it a fire on a high ledge is scored against the ground under it,
## which on this projection is up to half a screen away.
func _cell_screen_uv(cell: Vector2i) -> Vector2:
	var world: Vector2 = _pathfinder.call(&"cell_to_world", cell)
	world.y -= float(_pathfinder.call(&"altitude_center", cell)) * Pathfinder.HALF_STEP_PX
	var vp := get_viewport()
	var size: Vector2 = vp.get_visible_rect().size
	if size.x <= 0.0 or size.y <= 0.0:
		return Vector2(0.5, 0.5)
	return (vp.get_canvas_transform() * world) / size


# --- UI construction --------------------------------------------------------

func _build_ui() -> void:
	# Layout is containers all the way down, deliberately: the strip's HEIGHT is
	# whatever the wrapped copy needs, and that changes with the locale (Spanish
	# runs ~25% longer and wraps to a second line). Pinning the rect and
	# computing the height by hand is the documented way this project has
	# clipped copy before; a PanelContainer sized by its content cannot.
	var screen := MarginContainer.new()
	screen.name = "StripAnchor"
	screen.set_anchors_preset(Control.PRESET_FULL_RECT)
	# IGNORE on every wrapper — these cover the whole screen, and a STOP here
	# would swallow the click-to-move input across the entire window.
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.add_theme_constant_override(&"margin_bottom", int(_STRIP_MARGIN_BOTTOM))
	add_child(screen)

	var column := VBoxContainer.new()
	column.name = "Column"
	column.alignment = BoxContainer.ALIGNMENT_END
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The gap between the strip and the skip button below it. They are separate
	# objects — one is the tutorial talking, the other is a control that ends it —
	# and touching edges would read as one widget.
	column.add_theme_constant_override(&"separation", int(_SKIP_GAP))
	screen.add_child(column)

	_strip = PanelContainer.new()
	_strip.name = "Strip"
	_strip.custom_minimum_size = Vector2(_STRIP_WIDTH, 0)
	_strip.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	column.add_child(_strip)

	# The two-node fill + frame pattern: PanelContainer's own `panel` stylebox
	# from the global theme is the solid fill, and this see-through outline
	# overlays it. PanelContainer stretches every child to the content rect, so
	# the frame tracks the strip's size for free.
	var frame := Panel.new()
	frame.name = "Frame"
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	frame.add_theme_stylebox_override(&"panel", _FRAME_STYLEBOX)
	_strip.add_child(frame)

	var content := MarginContainer.new()
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side: String in ["left", "right"]:
		content.add_theme_constant_override(StringName("margin_" + side), 6)
	for side: String in ["top", "bottom"]:
		content.add_theme_constant_override(StringName("margin_" + side), 5)
	_strip.add_child(content)

	# A row, not a bare Label, so the mouse glyph sits BESIDE the copy and the copy
	# still wraps in what is left. Leading the line rather than trailing it: the
	# glyph is what the instruction is about, and it has to be seen before the
	# sentence is read, not after.
	var row := HBoxContainer.new()
	row.name = "Row"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override(&"separation", _CLICK_GAP)
	content.add_child(row)

	# One node reused across steps, its texture swapped per step — a strip that
	# rebuilt its children per line would relayout the panel mid-fade.
	_click_glyph = PixelUI.make_icon_sized(_CLICK_ICONS[&"left"])
	_click_glyph.name = "ClickGlyph"
	_click_glyph.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_click_glyph.visible = false
	row.add_child(_click_glyph)

	_label = Label.new()
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# The label takes the row's slack, so the copy wraps against the strip's width
	# minus the glyph rather than pushing the glyph off the panel.
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_label)
	# The glyphs are white masks (the UX atlas convention), so they take the
	# copy's own colour from the theme — one font_color edit moves both.
	_click_glyph.self_modulate = _label.get_theme_color(&"font_color", &"Label")

	# The skip button is the column's second row, under the strip and clear of
	# it. Inside the PANEL it drove the panel's width and added a row of height
	# to every step; as a sibling BELOW the panel it does neither — the strip
	# keeps its 200px minimum and shrinks to centre, so a button wider or
	# narrower than the copy cannot resize it.
	_skip_button = Button.new()
	_skip_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_skip_button.name = "Skip"
	_skip_button.text = "UI_SKIP_TUTORIAL"
	_skip_button.focus_mode = Control.FOCUS_NONE
	# Held, not pressed: `pressed` is not wired at all, so there is no single
	# click anywhere in this UI that can end the FTUE. button_down starts the
	# fill, and anything that ends the press — releasing, or dragging off the
	# button — drains it.
	_skip_button.button_down.connect(_on_skip_down)
	_skip_button.button_up.connect(_on_skip_up)
	_skip_button.mouse_exited.connect(_on_skip_up)
	column.add_child(_skip_button)

	# The fill is a CHILD of the button, so it draws after the button's own
	# background AND after its text — hence the alpha, which lets the label stay
	# readable under the sweep. Sized per frame in _update_skip_fill.
	_skip_fill = PixelUI.make_solid_ninepatch(Palette.with_alpha(Palette.ACCENT, 0.45))
	_skip_fill.name = "SkipFill"
	_skip_fill.visible = false
	_skip_button.add_child(_skip_fill)


## TWEEN_PAUSE_PROCESS keeps the fade running while the journal holds the tree
## paused — the journal step ends inside that pause.
func _fade_strip_to(target: float) -> void:
	var t := create_tween()
	t.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	t.set_parallel(true)
	t.tween_property(_strip, "modulate:a", target, _FADE)
	# The button is the strip's SIBLING, not its child, so it doesn't inherit the
	# panel's modulate and needs the same fade driven at it.
	t.tween_property(_skip_button, "modulate:a", target, _FADE)


# --- Hold to skip -----------------------------------------------------------

func _on_skip_down() -> void:
	_skip_held = true


func _on_skip_up() -> void:
	_skip_held = false


## Fills while held, drains when not, fires at full. Driven from _process rather
## than from a tween so that letting go mid-hold resumes from where the bar
## actually is instead of restarting an animation.
func _tick_skip_hold(delta: float) -> void:
	if _skip_button == null:
		return
	if _skip_held:
		_skip_hold = minf(_skip_hold + delta, _SKIP_HOLD)
	elif _skip_hold > 0.0:
		_skip_hold = maxf(_skip_hold - delta * _SKIP_DECAY, 0.0)
	_update_skip_fill()
	if _skip_held and _skip_hold >= _SKIP_HOLD:
		skip()


func _update_skip_fill() -> void:
	if _skip_fill == null:
		return
	var ratio: float = _skip_hold / _SKIP_HOLD
	_skip_fill.visible = ratio > 0.0
	if not _skip_fill.visible:
		return
	# round(), not a fractional width: the fill is a 9-sliced pixel sprite and a
	# half-texel edge on it resamples into a blurred column. The bar therefore
	# advances in whole pixels, which at this size is ~60 steps.
	_skip_fill.size = Vector2(roundf(_skip_button.size.x * ratio), _skip_button.size.y)


# --- Peers ------------------------------------------------------------------

func _resolve_peers() -> void:
	var tree := get_tree()
	_click_to_move = tree.get_first_node_in_group(ClickToMoveController.GROUP_NAME)
	_journal = tree.get_first_node_in_group(&"journal")
	_unlocks = tree.get_first_node_in_group(UnlockState.GROUP)
	_traversal = tree.get_first_node_in_group(TraversalPlacementController.GROUP_NAME)
	# The fire arc's two: where the player is standing, and what a cell's world
	# position and altitude are. Resolved here with the rest even though they are
	# not needed until the roam step ends — one lookup point is easier to keep
	# honest than two, and both nodes exist for the whole run.
	_pathfinder = tree.get_first_node_in_group(Pathfinder.GROUP_NAME)
	_player = tree.get_first_node_in_group(&"player")
