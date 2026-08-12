# Tiles and fences

`...` = `"../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" --path .`
Both tools need a rendering context — **do NOT pass `--headless`.**

## Where a tile's art lands — `scripts/tools/measure_tile_ink.gd`

Every 1x2 tile in `base_tileset.tres` (32x32 art on a 32x16 cell) carries a
`texture_origin`, and that number alone decides whether a structure stands on the
ground, floats over it, or sinks into it. There is nothing to check it against in
the tileset editor (no ground under the tile) and nothing in a gameplay
screenshot either (a neighbouring tile drawing over the structure changes its
apparent extent). So this renders **one tile alone** on an empty TileMapLayer in a
transparent SubViewport and reports the inked box in texels from the cell centre.

```bash
... --script res://scripts/tools/measure_tile_ink.gd
... --script res://scripts/tools/measure_tile_ink.gd -- --kinds FLAT,WALL_NE --source 0
```

Read the numbers against the diamond: 32x16, spanning x −16..+16 and y −8..+8
from the cell centre, apexes at (0, ±8) and (±16, 0), **edge midpoints at y = ±4**.
Measured reference values on source 1:

| kind | y range | note |
|---|---|---|
| `FLAT` | −8 .. +14 | top face fills the diamond, 6px of lip below |
| `HALF_STAIR_NE` | −16 .. +6 | |
| `FENCE_NE/NW` | −24 .. +4 | posts based on the two edge midpoints |

- **`texture_origin` positive y moves the art UP** (Godot subtracts it from the
  draw position). Getting that sign backwards is the likely first mistake.
- Do **not** try to measure this in a gameplay scene. It was tried: the same
  fence tile read 11 texels shorter at one `y_sort_origin` than at another,
  purely from what drew over it, and an off-by-16 authoring error read as
  plausible.

## Fences — `scripts/tools/preview_fence.gd`

Lays one fence run per axis on the handcrafted tileset test map, crosses the
first with a later one, and saves a still of each — so it can be judged in
context: do consecutive tiles join into one wire, did the two axes pick different
art, did the junction keep the older line, does anything sort through it. Also
prints how many cells actually block movement, the one part of the barrier the
unit tests cannot reach (they never put a fence on a live grid).

It strips the atmosphere first (title screen, night modulate, per-altitude fog,
rain, post-process, the idling Player); the two controllers are **freed** rather
than hidden because they re-apply their tint every frame.

```bash
... --script res://scripts/tools/preview_fence.gd -- --out /tmp/fence
... --script res://scripts/tools/preview_fence.gd -- --out /tmp/fence --len 8 --scene res://scenes/maps/level1.tscn
```

### Notes that save re-discovery

- **One fence = one cell.** A run lays N independent `Fence` nodes, not one
  object spanning N cells, which is what lets the trash action take out exactly
  the tile pointed at. Placement is two clicks: the second click on the **origin**
  cell plants a single fence; on any other cell it lays the line between them.
  Every cell is charged (1 token per tile) in **one** transaction
  (`UnlockState.try_pay_placements`) so a run cannot half-build.
- **Being too poor truncates the fence, it does not reject it**: the ghost stops
  at the last affordable cell and the click builds exactly that
  (`TraversalPlacementController._affordable_fence_cells` is used by both the
  preview and the commit — they must never disagree). Bridges and ladders instead
  go **red**, because a walkway that stops in the gap is not a cheaper bridge and
  a ladder has one fixed footprint.
- The `FENCE_NE`/`FENCE_NW` suffix names the axis the **wire runs along**, not a
  face it blocks. The posts sit at the midpoints of a pair of opposite diamond
  edges, so the wire is parallel to travel and a straight run joins up. Both
  signs of an axis take the same tile.
- **Orientation is derived, not authored** (`Fence.kind_at`): it comes from which
  neighbours are fences, so it is a property of the neighbourhood and changes
  under a fence when one is built or removed beside it. Every add and remove must
  refresh the neighbours (`refresh_art`, `_refresh_neighbours`).
- A cell with fences on **both** axes cannot show both — there is no corner piece,
  and layering the two whole-cell variants has no correct answer (their
  southernmost posts tie at y=+4, so screen depth cannot order them). Tie-break is
  **build order** via `build_index`: the axis carrying the older neighbour wins.
  That one rule also buys what a "locked axis" flag would, and unlike a lock it
  self-corrects, turning to face what is left when the winner is removed. A proper
  16-piece neighbour-mask set (lone post, 4 ends, 2 straights, 4 L-bends, 4 Ts,
  cross) would remove both compromises — that is 14 pieces of art that don't exist.
- `Fence` is a `Traversal` even though it *removes* movement: the whole two-click
  placement pipeline (preview ghost, candidate hints, occupant registry, trash
  removal) is keyed on that base class. The barrier is one overridden method,
  `blocks_movement() -> true`, which `TileGrid.is_walkable` duck-types per
  occupant. **No pathfinding code knows fences exist.**
- Because the barrier is only an occupant claim, build/despawn call
  `Pathfinder.notify_graph_changed()` rather than `rebuild()` — nothing was
  re-ingested. But the **signal** still has to fire: it is what drops the cached
  reachability set the action menu and UXOverlay read. Rebuilding per cell would
  be O(grid) × 20 on a long run.
- `FENCE_*` must be in `tile_grid._DECORATIVE` alongside `LADDER_*`. Without it,
  ingest falls through to "not in `_SHAPES`" and marks the **floor** blocked,
  which looks identical in game and is not: `resolve_click` and the remove action
  both go through `is_terrain_walkable`, so a blocked floor makes the fence
  un-right-clickable and therefore permanent.
- Validation is stricter than Bridge's on purpose. A bridge constrains only its
  two **endpoints** (the deck carries the span); a fence rests on the ground for
  its whole length, so **every** cell must be a solid, empty, level flat. Also
  unlike Bridge, the player's cell is rejected **anywhere** in the run, not just
  in the interior — a bridge may attach to the cell you stand on because it stays
  walkable; a fence would wall you in on the spot.
- When standing fences in a **test**, remember `TileGrid.set_occupant` silently
  refuses a cell with no painted terrain, returning false rather than warning.
  Fences that never registered look exactly like no fences at all, so the
  default-axis and NE-axis cases pass either way — `test_fence.gd` asserts the
  registration for that reason.
