class_name ActionContext
extends RefCounted

# ============================================================================
# ActionContext
# ============================================================================
#
# Bundle of per-click data handed to every TileAction.is_available() and
# execute() call. Built once per right-click by TileInteractionController and
# discarded when the menu closes.
#
# Keep this minimal: `cell` + `tile` cover the availability checks the core
# actions need. The service refs let actions reach behavior on the
# controllers (begin_traversal, plant_frailejon, remove_traversal_at) and
# query the unified occupant registry through `pathfinder.grid()`. Cell-level
# state (what's at this cell) lives in CellData.occupant — actions don't need
# any of the legacy controller-side dicts to answer "is this cell free".
#
# ============================================================================


var cell: Vector2i
var tile: CellData
var player_cell: Vector2i
# The Player node — actions read player state (cell, held_item, …) to gate
# availability and act on execute.
var player: Player

# Set of cells reachable from the player's current cell, keyed by Vector2i
# (values are `true`). Injected by TileInteractionController from
# Pathfinder.reachable_from(); read by TileAction.is_offerable to decide whether
# a far tile's action can be reached. Defaults to {} (never null) so `.has()` is
# safe for callers/tests that don't populate it.
var reachable: Dictionary = {}

# --- Injected services (temporary — see header note) -----------------------

var tile_interaction: TileInteractionController
var traversal: TraversalPlacementController
var pathfinder: Pathfinder

# The scene's UnlockState ("unlocks" group), or null. Null means "everything
# unlocked and free" — bare test scenes don't carry the token economy.
var unlocks: Node = null

# The scene's FloraCodex ("flora_codex" group), or null. Null means "no discovery
# system", i.e. everything already known — same rule as `unlocks`. Injected
# rather than looked up because a TileAction is a RefCounted with no tree.
var flora_codex: Node = null


## True iff every service this game currently expects is wired. Actions can
## short-circuit `is_available` against this when they don't want to list every
## service ref by hand. Returns false rather than pushing warnings — the caller
## decides how loud to be.
func has_all_services() -> bool:
	return tile_interaction != null and traversal != null and pathfinder != null
