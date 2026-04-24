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
# actions need. The service refs are a temporary convenience so the initial
# port of plant/build/remove actions can still reach the controller-owned
# registries (_planted dict, traversal registry). Once occupancy moves into
# CellData or a dedicated occupancy service, the service refs can be dropped.
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
