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

# --- Injected services (temporary — see header note) -----------------------

var tile_interaction: TileInteractionController
var traversal: TraversalPlacementController
var pathfinder: Pathfinder


## True iff every service this game currently expects is wired. Actions can
## short-circuit `is_available` against this when they don't want to list every
## service ref by hand. Returns false rather than pushing warnings — the caller
## decides how loud to be.
func has_all_services() -> bool:
	return tile_interaction != null and traversal != null and pathfinder != null
