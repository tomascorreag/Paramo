# Terrain tools

In the command blocks below, `...` stands for
`"../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" --path .`

## Regression sweep — `scripts/tools/verify_terrain_invariants.gd`

Runs every named scenario × N seeds and asserts a battery of grid invariants
(river reaches south, branch-merge altitude consistency, waterfall fields,
altitude even/in-range, lake connectedness, shore mask, grid dimensions).
Exit 0 on full pass, 1 on any failure. **Run after touching anything under
`scripts/systems/terrain_*.gd` or `scripts/data/terrain_*.gd`.**

```bash
"../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" --path . --headless --script res://scripts/tools/verify_terrain_invariants.gd
# heavier sweep, full per-failure detail
... --script res://scripts/tools/verify_terrain_invariants.gd -- --seeds 50 --verbose
# single scenario
... --script res://scripts/tools/verify_terrain_invariants.gd -- --scenario branch_heavy
```

### Extending it

Two edit points at the top of the file:

- **`SCENARIOS`** — `{"name": ..., "overrides": {<param>: <value>}}`. Each entry
  stacks `overrides` onto `TerrainGenerationParams` defaults and runs `--seeds`
  seeds. Add one when a new map preset or stress mode appears. Keys must match
  `TerrainGenerationParams` field names.
- **`CHECKS`** — `{"name": ..., "fn": _check_*}`, where `fn` is a static
  `func(grid: TerrainGrid, params: TerrainGenerationParams) -> Array[String]`
  returning failure messages (empty = pass). Keep checks pure: read the grid,
  return strings, don't mutate.

Lightweight subset (predates the harness — just checks the river reaches south):

```bash
... --headless --script res://scripts/tools/verify_river_reaches_south.gd -- 200
```

## Inspect one cell — `scripts/tools/dump_cells_around.gd`

Regenerates the level1 scenario at a seed and prints three views of cell (x, y):
a NxN window grid (kind letter + altitude, target bracketed); a cell focus
(target + 4 face neighbours with full per-kind state — waterfall rise/drop/basin
plus the secondary `rise_b`/`drop_b` fields used by concave-corner falls; water
flow + shore mask for WATER); and every WATERFALL in the grid, corner falls
flagged `[CORNER]`.

Use it to confirm what the **generator** produced before suspecting the painter.

```bash
... --headless --script res://scripts/tools/dump_cells_around.gd -- 17 23        # x y [seed=22] [window=4]
... --headless --script res://scripts/tools/dump_cells_around.gd -- 17 23 22 8
```

Seed 22 / (17,23) is a useful fixture: a river/lakeshore cell exercising WATER
neighbours and multi-altitude windows. `LEVEL1_OVERRIDES` at the top of the file
mirrors `verify_terrain_invariants.gd`'s "level1" entry — **keep both in sync**
when level1 retunes. For another scenario, copy that scenario's overrides dict
over `LEVEL1_OVERRIDES`.

## Smoke test — `scripts/tools/smoke_test_terrain.gd`

End-to-end `TerrainGenerator` at a hardcoded 48x48 preset; prints timing, kind
and altitude histograms, waterfall drop-height distribution. No painting, no
scene mutation. Sanity-check before running the full invariant harness.

```bash
... --headless --script res://scripts/tools/smoke_test_terrain.gd
... --headless --script res://scripts/tools/smoke_test_terrain.gd -- 99
```

## Bake a procedural scene — `scripts/tools/generate_terrain_cli.gd`

Loads an inherited procedural map scene, runs `ProceduralWorld.regenerate`, saves
the scene with tiles baked in. For capturing a favourite seed or reproducible
build output. Optional second arg overrides `seed_override`.

```bash
... --headless --script res://scripts/tools/generate_terrain_cli.gd -- res://scenes/maps/procedural_test.tscn
... --headless --script res://scripts/tools/generate_terrain_cli.gd -- res://scenes/maps/procedural_test.tscn 12345
```

## Copy tile atlas setup — `scripts/tools/copy_atlas_setup.gd`

Copies tile definitions (size, `texture_origin`, `y_sort_origin`, custom data)
from one `TileSetAtlasSource` to others. Assumes the target spritesheets share
the same sprite layout.

```bash
# source 0 -> all others
... --headless --script res://scripts/tools/copy_atlas_setup.gd -- res://resources/tiles/base_tileset.tres
# source 0 -> specific targets
... --headless --script res://scripts/tools/copy_atlas_setup.gd -- res://resources/tiles/base_tileset.tres 0 2,3
```

## Regeneration is not re-entrant

`ProceduralWorld._ready` calls `regenerate_async()`, a coroutine that paints
across many frames, and **there is no guard against a second generation starting
while it runs**. Two interleaved generations produce a different tile count from
the same pinned seed — which reads exactly like "seed_override is not honoured"
and is nothing of the kind. Any caller that regenerates on demand must wait for
`generation_finished` first. Worth an `if _generating: return` if this comes up
again.

Related trap: a settled pathfinder graph does **not** mean the map is painted.
`TerrainPainter` lays tiles across frames, so waiting for the `TileGrid` instance
to stop changing can sample a world whose `CellData` points at layers with no
tile under them — which reads as "there is no grass on this map" (fire refusing
to ignite, trample doing nothing). Wait for `ProceduralWorld.generation_finished`.

## Dump a scene's painted tiles — `scripts/tools/dump_scene_tiles.gd`

Instantiates a scene without running it and lists every painted tile on every
`TileMapLayer`, grouped by layer, with the tile's `tile_kind` custom data. The
counterpart to `dump_cells_around.gd`: that one shows what the **generator**
decided, this one shows what actually landed on the **layers**, which is the
only way to tell a generation bug from a painting bug.

```bash
... --headless --script res://scripts/tools/dump_scene_tiles.gd -- res://scenes/tools/tileset_test.tscn
```

## Dump the routing graph — `scripts/tools/dump_pathfinder.gd`

Builds the `Pathfinder` graph over a scene and prints reachability for key cells
plus every edge around the Ground1→Ground2 ramp row (`exit`/`enter` altitudes
and `can_transition`), then a handful of concrete paths. Use it when a cell is
unreachable and you need to see **which edge** refused, rather than that a route
failed.

```bash
... --headless --script res://scripts/tools/dump_pathfinder.gd -- res://scenes/tools/tileset_test.tscn
```

Defaults to `tileset_test.tscn` when given no argument. The ramp-row cells it
reports are hardcoded to that scene's geometry, so on another map read the
reachability and path sections and ignore the edge table.
