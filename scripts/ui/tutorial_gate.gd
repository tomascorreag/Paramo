class_name TutorialGate
extends RefCounted

## Which of the game's verbs the player is currently allowed to use.
##
## The FTUE teaches four things — walk, open the journal, buy, build — and until
## it has taught one, that verb does nothing. A player who right-clicks a tile
## during the opening narrative and gets an action menu has been handed the game
## out of order; worse, they can complete a later step before its line is up and
## leave the strip asking for something already done.
##
## Default is OPEN. The gate only ever narrows because a live TutorialController
## narrowed it, and it reopens when that controller leaves the tree — including
## the skip path and a mid-FTUE scene change. A run with the FTUE disabled, the
## balance simulator, and every test that never instantiates the controller all
## see an unrestricted game.
##
## A static class rather than an autoload, following this project's UI core (see
## CLAUDE.md: no UIManager autoload). The cost of `static var` is that it is
## per-PROCESS, not per-scene — hence the reopen in `_exit_tree` rather than only
## on the tutorial finishing, and hence `release()` being the safe default state
## rather than a fully-closed one.

enum Action {
	MOVE,     ## click-to-move
	JOURNAL,  ## opening and closing the field journal
	SHOP,     ## buying an unlock on the journal's shop page
	BUILD,    ## the tile action menu, and so every placement behind it
}

const ALL: int = (1 << Action.MOVE) | (1 << Action.JOURNAL) \
		| (1 << Action.SHOP) | (1 << Action.BUILD)

static var _allowed: int = ALL


static func bit(action: Action) -> int:
	return 1 << int(action)


static func allows(action: Action) -> bool:
	return (_allowed & bit(action)) != 0


## The current mask. Exposed for tests and for a debug readout, not to be
## written through — use `restrict_to` / `release`.
static func allowed_mask() -> int:
	return _allowed


## Narrow to exactly `mask`. The tutorial recomputes the whole mask per step
## rather than adding bits, so a step re-shown (or a step list reordered) can't
## leave a verb granted by a step that is no longer on screen.
static func restrict_to(mask: int) -> void:
	_allowed = mask & ALL


## Back to an unrestricted game. Called when the FTUE ends by any route.
static func release() -> void:
	_allowed = ALL
