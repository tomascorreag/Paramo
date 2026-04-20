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
