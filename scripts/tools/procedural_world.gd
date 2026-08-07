@tool
class_name ProceduralWorld
extends Node

# Preloaded so the @tool script doesn't depend on the global class_name cache
# being refreshed (which lags new files until the editor reimports). The
# const is intentionally untyped so static method calls (`_OBJECT_PAINTER.paint`)
# resolve against the actual ObjectPainter class — a `: GDScript` annotation
# would constrain calls to base GDScript members and lose access to static
# methods declared in the script.
const _OBJECT_PAINTER = preload("res://scripts/systems/object_painter.gd")
# Preloaded for the same @tool class-cache reason as _OBJECT_PAINTER: the
# overlay is only spawned at runtime, but preloading keeps the reference stable
# regardless of editor reimport timing.
const _LOADING_OVERLAY = preload("res://scripts/ui/loading_overlay.gd")

# Minimum size (in cells) of a same-altitude grass plateau to qualify as a
# spawn target. Below this we fall back to the legacy "any flat ground" pick
# so degenerate seeds still produce a usable spawn.
const MIN_PLATEAU_SIZE: int = 8

# Async-startup chunking budget. The runtime path (regenerate_async) paints /
# spawns this many grid rows per frame, awaiting a frame between batches, so the
# main thread never freezes for the whole pass. A 48-row grid completes in
# ~8 frames per phase. Tune up for fewer frames (longer per-frame hitch) or down
# for smoother but longer loads.
const PAINT_ROWS_PER_FRAME: int = 6
const SPAWN_ROWS_PER_FRAME: int = 6
# Extra frames the world is allowed to draw beneath the loading overlay before
# it fades — long enough for WebGL to compile the water / post-process / rain
# shaders while still hidden, so the first visible frame doesn't stutter.
const SHADER_WARM_FRAMES: int = 3

# ============================================================================
# ProceduralWorld
# ============================================================================
#
# Editor-iterable orchestrator that runs TerrainGenerator + TerrainPainter
# against the layer stack of an inherited gameplay scene. Live in the scene
# tree alongside the World node; click the "Regenerate" button in the
# inspector to re-bake the map without leaving the editor.
#
# At runtime, generates in `_ready()` if `auto_generate_on_ready` is set.
#
# ============================================================================


## Emitted once the world is fully generated, painted, pathfound, populated, and
## the player is placed — i.e. the map is ready to play. A RunController listens
## here to kick off the season clock (start_run) only after the world exists.
## Fires at runtime from both regenerate() and regenerate_async(); harmless in
## the editor where nothing is connected.
signal generation_finished


@export_group("Generation")
## Resource preset driving the generator. Edit the .tres in the inspector
## to tune values, swap `.tres` files to change biome / map style. If null
## at runtime, defaults are used (see TerrainGenerationParams).
@export var generation_params: TerrainGenerationParams
## Per-instance overrides for the most commonly-tweaked fields. Set to a
## non-default value to override the resource without forking it. The
## sentinel for "use the resource value as-is" is shown in the comments.
##
## seed_override = -1  → use generation_params.seed
@export var seed_override: int = -1

@export_group("Wiring")
## Ground TileMapLayers indexed by altitude. Drag the layers in low-to-high.
## Their `metadata/altitude` is used to bind cells to the correct layer.
@export var ground_layers: Array[TileMapLayer] = []
## Paint-only TileMapLayers used by the south-cliff skirt pass. Each layer's
## `metadata/altitude` is read the same way as `ground_layers`. These layers
## MUST NOT be wired into Pathfinder.tile_map_layers or LayerConfigurator.layers
## — keeping them out is what makes the cliff non-walkable. Typical setup:
## CliffN2..CliffN8 at altitudes -2, -4, -6, -8.
@export var cliff_layers: Array[TileMapLayer] = []
## Optional Pathfinder to rebuild after painting. Wire it on the procedural
## scene template; gameplay relies on it for click-to-move.
@export var pathfinder: Pathfinder
## Optional Player to reposition onto a walkable cell after generation.
## Without this, the player's authored position can land on a non-walkable
## or empty cell since terrain shape is random per seed.
@export var player: Node2D
## Optional World Node2D that ObjectPainter parents procedurally-spawned
## objects (rocks, future signage) under. When null, ObjectPainter is
## skipped at runtime and procedural objects don't appear. Editor-time
## regenerate also skips ObjectPainter (would need a Pathfinder, which is
## a placeholder in @tool mode).
@export var world: Node2D

@export_group("Runtime")
## When true, generates the map automatically on `_ready()` at game start.
@export var auto_generate_on_ready: bool = true
## When true, picks a fresh random seed at `_ready()` (before auto-generation),
## overwriting `seed_override` for this run so each launch produces a new map.
## Editor-time Regenerate is unaffected.
@export var randomize_seed_on_ready: bool = false
## Print a one-line "generated WxH, seed=N" summary on each regenerate.
## Default off; flip on when iterating on the generator.
@export var verbose_logs: bool = false
## When true, the runtime startup (regenerate_async) runs TerrainGenerator on a
## WorkerThreadPool task so the main thread keeps presenting frames (animated
## loading overlay) during generation. Requires the export template's thread
## support — enabled in the Web preset. Set false for a non-threaded build, where
## generation runs inline (a brief freeze behind the already-visible overlay).
## Editor-time Regenerate always runs synchronously regardless of this flag.
@export var use_threaded_generation: bool = true
## When true, the runtime startup shows the full-screen LoadingOverlay while it
## generates / paints / spawns, then fades it out. Disable to skip the overlay
## (e.g. when this scene is embedded inside another that owns its own loading UI).
@export var show_loading_overlay: bool = true
## Seconds the finished loading screen lingers (bar full) before fading out into
## whatever is behind it (the language gate on gameplay maps). Pure pacing: a
## fade that starts the instant the bar fills reads as an abrupt cut.
@export var overlay_linger: float = 1.0

@export_tool_button("Regenerate") var regenerate_action := regenerate
@export_tool_button("Clear") var clear_action := clear


# ----------------------------------------------------------------------------
# Lifecycle
# ----------------------------------------------------------------------------

func _enter_tree() -> void:
	if Engine.is_editor_hint():
		return
	# Discoverable by TitleIntro, which waits on generation_finished before
	# showing its language gate (so the boxes aren't drawn over the loading
	# overlay and clicks aren't accepted before the world exists).
	#
	# Joined in _enter_tree, NOT _ready: this node is ADDED in procedural_base,
	# so it sits after every inherited gameplay_base child in tree order and its
	# _ready runs after TitleIntro's. TitleIntro's group lookup then found
	# nothing and activated the gate over the loading screen. _enter_tree
	# propagates through the whole subtree before any _ready fires, so the
	# membership is visible no matter the ready order.
	add_to_group(&"procedural_world")


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if randomize_seed_on_ready:
		# randi() is non-negative (0..2^32-1 mod int range), so it satisfies
		# the `seed_override >= 0` sentinel in _resolve_params.
		seed_override = randi()
	if auto_generate_on_ready:
		# Claim placement authority BEFORE generating so the player's own
		# deferred self-placement stands down (it would otherwise snap to the
		# authored node position, which differs from the spawn cell we pick in
		# _place_player_on_walkable — leaving global_position and current_cell
		# describing two different cells). Set synchronously here so the flag is
		# live before the player's deferred self-place runs at idle, regardless
		# of sibling _ready order.
		if player != null and player.has_method(&"defer_to_external_placement"):
			player.call(&"defer_to_external_placement")
		# Fire-and-forget coroutine: spreads generation/paint/spawn across frames
		# (and offloads generation to a worker thread) so the browser tab stays
		# responsive on load instead of freezing through the whole pass. The
		# editor never reaches here (guarded above); the Regenerate button uses
		# the synchronous regenerate() path.
		regenerate_async()


# ----------------------------------------------------------------------------
# Public actions (wired to @export_tool_button)
# ----------------------------------------------------------------------------

func regenerate() -> void:
	if ground_layers.is_empty():
		push_error("ProceduralWorld: no ground_layers wired.")
		return
	var tile_set: TileSet = ground_layers[0].tile_set
	if tile_set == null:
		push_error("ProceduralWorld: ground_layers[0] has no TileSet.")
		return

	var params: TerrainGenerationParams = _resolve_params()
	var layers_by_altitude: Dictionary = _build_layer_map()
	_validate_layer_ceiling(params, layers_by_altitude)

	var grid: TerrainGrid = TerrainGenerator.generate(params)
	TerrainPainter.paint(grid, layers_by_altitude, tile_set, params)

	# Pathfinder is not an @tool script — calling its methods from the editor
	# (e.g. via the Regenerate button) errors out with "Attempt to call a
	# method on a placeholder instance". Skip rebuild during editor edits;
	# at runtime _ready() runs in non-editor mode and pathfinder is real.
	if pathfinder != null and not Engine.is_editor_hint():
		# Clip the walkable grid to the playable disc area so the south-cliff
		# skirt — painted at synthetic coords past the disc edge into the
		# same Ground TileMapLayers — doesn't expand pathfinder bounds.
		# Visuals are unaffected; only the walkability graph is bounded.
		pathfinder.bounds_clip = Rect2i(0, 0, params.width, params.height)
		pathfinder.rebuild()

		# Spawn procedurally-flagged objects (rocks). Must run AFTER rebuild
		# so the fresh TileGrid exists for occupant registration. Skipped in
		# editor mode (Pathfinder is a placeholder) and when `world` is
		# unwired (defensive — emits a single error).
		if world != null:
			_OBJECT_PAINTER.paint(grid, world, pathfinder, _object_rng(params))

	_place_player_on_walkable(grid)

	if verbose_logs:
		print(
			"ProceduralWorld: generated %dx%d, top altitude %d, seed %d."
			% [params.width, params.height, params.top_altitude, params.seed]
		)

	generation_finished.emit()


# Runtime equivalent of regenerate() that spreads the work across frames and
# offloads generation to a worker thread, behind a loading overlay. Same five
# steps (generate → paint → rebuild → spawn objects → place player), but:
#   - generation runs on WorkerThreadPool (main thread keeps presenting frames)
#   - painting and object spawning are chunked PAINT/SPAWN_ROWS_PER_FRAME rows
#     per frame
#   - the painted world draws a few frames beneath the overlay (shader pre-warm)
#     before the overlay fades, so the first visible frame doesn't stutter.
# Output is identical to regenerate() for the same resolved params/seed — the
# painters preserve iteration order across chunk boundaries.
func regenerate_async() -> void:
	if ground_layers.is_empty():
		push_error("ProceduralWorld: no ground_layers wired.")
		return
	var tile_set: TileSet = ground_layers[0].tile_set
	if tile_set == null:
		push_error("ProceduralWorld: ground_layers[0] has no TileSet.")
		return

	var overlay: Node = null
	if show_loading_overlay:
		overlay = _spawn_overlay()
		# Let the overlay render once before we start heavy work so the player
		# sees it immediately rather than a black/last frame.
		await get_tree().process_frame

	var params: TerrainGenerationParams = _resolve_params()
	var layers_by_altitude: Dictionary = _build_layer_map()
	_validate_layer_ceiling(params, layers_by_altitude)

	if overlay != null:
		overlay.set_status("LOADING_TERRAIN")
	var grid: TerrainGrid = await _generate_grid_async(params, overlay)
	if grid == null:
		push_error("ProceduralWorld: terrain generation returned null — aborting.")
		if overlay != null:
			overlay.queue_free()
		return

	# Paint the playable grid + south-cliff skirt, a few rows per frame.
	if overlay != null:
		overlay.set_status("LOADING_PAINTING")
	var paint_ctx: Dictionary = TerrainPainter.begin_paint(
		grid, layers_by_altitude, tile_set, params
	)
	if not paint_ctx.is_empty():
		while not TerrainPainter.paint_step(paint_ctx, PAINT_ROWS_PER_FRAME):
			if overlay != null:
				overlay.set_progress(0.30 + 0.40 * TerrainPainter.paint_progress(paint_ctx))
			await get_tree().process_frame

	# Rebuild pathfinding off the painted layers, then scatter objects (chunked).
	if pathfinder != null:
		pathfinder.bounds_clip = Rect2i(0, 0, params.width, params.height)
		pathfinder.rebuild()
		if world != null:
			if overlay != null:
				overlay.set_status("LOADING_PLANTING")
			var spawn_ctx: Dictionary = _OBJECT_PAINTER.begin_spawn(
					grid, world, pathfinder, _object_rng(params))
			if not spawn_ctx.is_empty():
				while not _OBJECT_PAINTER.spawn_step(spawn_ctx, SPAWN_ROWS_PER_FRAME):
					if overlay != null:
						overlay.set_progress(0.70 + 0.25 * _OBJECT_PAINTER.spawn_progress(spawn_ctx))
					await get_tree().process_frame

	_place_player_on_walkable(grid)
	if overlay != null:
		overlay.set_progress(1.0)

	if verbose_logs:
		print(
			"ProceduralWorld: generated %dx%d, top altitude %d, seed %d (async)."
			% [params.width, params.height, params.top_altitude, params.seed]
		)

	# Shader pre-warm: hold the overlay up while the just-painted world (water /
	# post-process / rain materials) draws hidden, so WebGL compiles those
	# shaders before the player can see the map. Then linger (pacing — see
	# overlay_linger), fade out and free.
	if overlay != null:
		for _i in SHADER_WARM_FRAMES:
			await get_tree().process_frame
		if overlay_linger > 0.0:
			await get_tree().create_timer(overlay_linger).timeout
		await overlay.fade_out()
		overlay.queue_free()

	generation_finished.emit()


# Generates the grid, optionally on a worker thread. Threaded path: dispatch
# TerrainGenerator.generate (pure compute — no scene/global access, safe
# off-thread) to WorkerThreadPool and poll completion while yielding frames, so
# the overlay stays animated. Falls back to inline generation when threading is
# disabled or the task produced no result.
func _generate_grid_async(
	params: TerrainGenerationParams, overlay: Node
) -> TerrainGrid:
	# Gate the worker-thread path on actual runtime thread capability, not just
	# the inspector flag: a single-threaded web export (no SharedArrayBuffer) has
	# no WorkerThreadPool workers, so add_task() would never complete and the
	# poll loop below would hang the loading screen forever. OS.has_feature(
	# "threads") is true in the current threaded build (behaviour unchanged) and
	# false in a single-threaded export, where we fall through to inline gen.
	if not (use_threaded_generation and OS.has_feature("threads")):
		return TerrainGenerator.generate(params)

	var holder: Array = []
	var task_id: int = WorkerThreadPool.add_task(
		func() -> void: holder.append(TerrainGenerator.generate(params)),
		true, "terrain_generate"
	)
	while not WorkerThreadPool.is_task_completed(task_id):
		if overlay != null:
			# No measurable sub-progress from a single generate() call — drift
			# the bar toward the end of the generation band so it isn't frozen.
			overlay.pulse_toward(0.28)
		await get_tree().process_frame
	# Reap the handle (returns immediately; the task is already complete).
	WorkerThreadPool.wait_for_task_completion(task_id)

	if holder.is_empty():
		push_warning(
			"ProceduralWorld: threaded generation produced no grid; "
			+ "falling back to inline generation."
		)
		return TerrainGenerator.generate(params)
	return holder[0]


func _spawn_overlay() -> Node:
	var overlay: Node = _LOADING_OVERLAY.new()
	add_child(overlay)
	return overlay


# Validates the layer ceiling: cells generated above the tallest layer's
# altitude have no place to be painted and silently disappear (the painter logs
# a per-cell warning, but by then the map is already half-rendered). Surface
# this up-front so the author sees a single clear message instead of N painter
# warnings. Shared by regenerate() and regenerate_async().
func _validate_layer_ceiling(
	params: TerrainGenerationParams, layers_by_altitude: Dictionary
) -> void:
	var max_layer_alt: int = -1
	for alt in layers_by_altitude.keys():
		if int(alt) > max_layer_alt:
			max_layer_alt = int(alt)
	if max_layer_alt >= 0 and params.top_altitude > max_layer_alt:
		push_warning(
			"ProceduralWorld: top_altitude=%d exceeds tallest TileMapLayer altitude=%d. "
			% [params.top_altitude, max_layer_alt]
			+ "Cells above %d will not be painted. " % max_layer_alt
			+ "Add Ground layers up to altitude %d, or lower top_altitude to %d."
			% [params.top_altitude, max_layer_alt]
		)


# Builds the effective TerrainGenerationParams for this regenerate call.
# Resource is deep-duplicated (subresources=true) before override application
# so we never mutate the shared `.tres` — including the inner
# `Array[TerrainBiomeBand]`, whose elements are sub-resources. A shallow
# duplicate would leave the bands shared with the .tres and any future code
# that mutates a band (e.g. weight tweak per pass) would silently mutate the
# saved asset. If no resource is assigned, falls back to default values
# (defined on TerrainGenerationParams) and warns.
# Object placement draws from a seed-derived stream so rock layouts are part
# of the seed's identity (a "favorite seed" bake reproduces its rocks, and
# the balance simulator sees the same layouts as the game).
func _object_rng(params: TerrainGenerationParams) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = params.seed ^ ObjectPainter.OBJECT_SEED_XOR
	return rng


func _resolve_params() -> TerrainGenerationParams:
	var p: TerrainGenerationParams
	if generation_params != null:
		p = generation_params.duplicate(true) as TerrainGenerationParams
	else:
		push_warning(
			"ProceduralWorld: no generation_params assigned — using defaults. "
			+ "Assign a .tres under res://resources/terrain/ to tune."
		)
		p = TerrainGenerationParams.new()
	if seed_override >= 0:
		p.seed = seed_override
	p.top_altitude = _ensure_even(p.top_altitude)
	return p


func clear() -> void:
	for l in ground_layers:
		if l != null:
			l.clear()
	for l in cliff_layers:
		if l != null:
			l.clear()


# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

func _build_layer_map() -> Dictionary:
	var out: Dictionary = {}
	# Ground layers AND cliff layers feed the painter's `layers_by_altitude`
	# dict. Pathfinder/LayerConfigurator only see ground_layers; the cliff
	# subset is paint-only by virtue of being absent from those wirings.
	for l in ground_layers:
		_register_layer(out, l)
	for l in cliff_layers:
		_register_layer(out, l)
	return out


func _register_layer(out: Dictionary, l: TileMapLayer) -> void:
	if l == null:
		return
	if not l.has_meta("altitude"):
		push_warning(
			"ProceduralWorld: layer '%s' has no metadata/altitude — skipping in layer map."
			% l.name
		)
		return
	var alt: int = int(l.get_meta("altitude"))
	if out.has(alt):
		push_warning(
			"ProceduralWorld: two layers claim altitude %d ('%s' and '%s'); the second wins."
			% [alt, (out[alt] as TileMapLayer).name, l.name]
		)
	out[alt] = l


func _ensure_even(v: int) -> int:
	return v if v % 2 == 0 else v - 1


# Finds a walkable cell — preferring low-altitude FLAT/FULL_CUBE GROUND tiles
# near the map centroid — and snaps the player onto it. Reads the abstract
# grid directly so it works in both editor and runtime (Pathfinder is not
# @tool and its methods are placeholders during editor edits).
# Centroid cell of the summit lake — still water (WATER kind with no river flow,
# i.e. river_width == 0). Returns (-1, -1) when the map has no lake, so the
# opening camera pan falls back to its default start pose. The river/waterfalls
# are excluded so the centroid sits in the lake body, not dragged south.
func _compute_lake_center(grid: TerrainGrid) -> Vector2i:
	var sx: int = 0
	var sy: int = 0
	var n: int = 0
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind == TerrainCell.Kind.WATER and c.river_width == 0:
				sx += x
				sy += y
				n += 1
	if n == 0:
		return Vector2i(-1, -1)
	return Vector2i(sx / n, sy / n)


func _place_player_on_walkable(grid: TerrainGrid) -> void:
	if player == null:
		return
	var cell: Vector2i = _find_starting_cell(grid)
	if cell.x < 0:
		push_warning("ProceduralWorld: no walkable cell found; leaving player at authored position.")
		return
	var world_pos: Vector2 = _cell_to_world(cell)
	# Set the ground-level (altitude-0) world position; the Player script owns
	# the altitude lift, sort-Y offset, and current_cell.
	player.global_position = world_pos
	# Drive the player's placement against the cell we just moved it to. The
	# generator is the sole placement authority on procedural maps (the player's
	# own deferred self-placement is suppressed via defer_to_external_placement
	# in _ready), so this establishes current_cell, altitude lift, sort-Y, and
	# the opening camera pan. DEFERRED so it runs after Player._ready regardless
	# of sibling _ready order (the synchronous regenerate() path can reach here
	# before the player has initialized). Editor-guarded: the non-@tool Player
	# has no runtime state during an editor Regenerate.
	if not Engine.is_editor_hint():
		# Aim the opening camera pan at the summit lake (straight-down pan start).
		# Must be set BEFORE the deferred snap_to_start, which reads it. Computed
		# here because the lake↔river distinction (river_width) only survives in
		# the abstract grid, not the painted runtime tiles.
		if player.has_method(&"set_opening_pan_start_cell"):
			player.call(&"set_opening_pan_start_cell", _compute_lake_center(grid))
		if player.has_method(&"snap_to_start"):
			player.call_deferred(&"snap_to_start")


# Preferred spawn: the interior of the largest contiguous same-altitude grass
# plateau (FLAT/FULL_CUBE GROUND, biome == GRASS, no blocking object). Falls
# back to the legacy "any flat ground" pick when no plateau meets
# MIN_PLATEAU_SIZE — keeps degenerate seeds (rocky / dry) playable.
func _find_starting_cell(grid: TerrainGrid) -> Vector2i:
	var plateau: Dictionary = _find_largest_grass_plateau(grid)
	if not plateau.is_empty():
		return _pick_interior_cell(grid, plateau["cells"], plateau["altitude"])
	return _find_starting_cell_fallback(grid)


# Legacy scoring loop kept verbatim as a safety net: lowest-altitude
# FLAT/FULL_CUBE GROUND with a walkable face neighbor (or, failing that, an
# isolated flat cell with a warning). Slopes are excluded because the player
# anchor looks odd half-way up a tapered tile.
func _find_starting_cell_fallback(grid: TerrainGrid) -> Vector2i:
	var center := Vector2(grid.width * 0.5, grid.height * 0.5)
	var best := Vector2i(-1, -1)
	var best_alt: int = 0x7FFFFFFF
	var best_dist_sq: float = INF
	var fallback := Vector2i(-1, -1)
	var fallback_alt: int = 0x7FFFFFFF
	var fallback_dist_sq: float = INF
	for y in grid.height:
		for x in grid.width:
			var c: TerrainCell = grid.at(x, y)
			if c.kind != TerrainCell.Kind.GROUND:
				continue
			if c.ground_shape != TerrainCell.GroundShape.FULL_CUBE \
					and c.ground_shape != TerrainCell.GroundShape.FLAT:
				continue
			if c.object_kind != &"":
				continue
			var cell := Vector2i(x, y)
			var d := Vector2(x, y) - center
			var dist_sq: float = d.x * d.x + d.y * d.y
			if c.altitude < fallback_alt \
					or (c.altitude == fallback_alt and dist_sq < fallback_dist_sq):
				fallback = cell
				fallback_alt = c.altitude
				fallback_dist_sq = dist_sq
			if not _has_walkable_neighbor(grid, cell, c.altitude):
				continue
			if c.altitude < best_alt \
					or (c.altitude == best_alt and dist_sq < best_dist_sq):
				best = cell
				best_alt = c.altitude
				best_dist_sq = dist_sq
	if best.x < 0 and fallback.x >= 0:
		push_warning(
			"ProceduralWorld: no walkable cell with a walkable neighbor; "
			+ "falling back to isolated cell %s (player may be stuck)." % fallback
		)
		return fallback
	return best


# 4-connected BFS over face neighbors. A "plateau cell" is GROUND + FLAT/FULL_CUBE
# + GRASS + no object; an edge between two cells requires equal altitude (so a
# component never spans tiers). Returns the largest qualifying component as
# `{cells: PackedInt32Array, altitude: int}` (cells encoded `y*width + x`), or
# `{}` if no component reaches MIN_PLATEAU_SIZE. Tiebreaks larger components
# first, then lower altitude, then closer to map center.
func _find_largest_grass_plateau(grid: TerrainGrid) -> Dictionary:
	var w: int = grid.width
	var h: int = grid.height
	var visited := PackedByteArray()
	visited.resize(w * h)
	var dirs: Array[Vector2i] = [
		TerrainCell.DIR_NE,
		TerrainCell.DIR_NW,
		TerrainCell.DIR_SE,
		TerrainCell.DIR_SW,
	]
	var center := Vector2(w * 0.5, h * 0.5)
	var best_cells := PackedInt32Array()
	var best_size: int = 0
	var best_alt: int = 0x7FFFFFFF
	var best_dist_sq: float = INF
	var frontier := PackedInt32Array()
	for y in h:
		for x in w:
			var idx: int = y * w + x
			if visited[idx] != 0:
				continue
			var seed_cell: TerrainCell = grid.at(x, y)
			if not _is_plateau_cell(seed_cell):
				continue
			var alt: int = seed_cell.altitude
			# Flood fill this component, gated on equal-altitude edges.
			frontier.clear()
			frontier.append(idx)
			visited[idx] = 1
			var component := PackedInt32Array()
			component.append(idx)
			var sum_x: int = x
			var sum_y: int = y
			var head: int = 0
			while head < frontier.size():
				var cur: int = frontier[head]
				head += 1
				var cx: int = cur % w
				var cy: int = cur / w
				for d in dirs:
					var nx: int = cx + d.x
					var ny: int = cy + d.y
					if nx < 0 or ny < 0 or nx >= w or ny >= h:
						continue
					var nidx: int = ny * w + nx
					if visited[nidx] != 0:
						continue
					var nc: TerrainCell = grid.at(nx, ny)
					if nc.altitude != alt:
						continue
					if not _is_plateau_cell(nc):
						continue
					visited[nidx] = 1
					frontier.append(nidx)
					component.append(nidx)
					sum_x += nx
					sum_y += ny
			var size: int = component.size()
			if size < MIN_PLATEAU_SIZE:
				continue
			var centroid := Vector2(float(sum_x) / size, float(sum_y) / size)
			var dv := centroid - center
			var dist_sq: float = dv.x * dv.x + dv.y * dv.y
			var take: bool = false
			if size > best_size:
				take = true
			elif size == best_size:
				if alt < best_alt:
					take = true
				elif alt == best_alt and dist_sq < best_dist_sq:
					take = true
			if take:
				best_cells = component
				best_size = size
				best_alt = alt
				best_dist_sq = dist_sq
	if best_size == 0:
		return {}
	return {"cells": best_cells, "altitude": best_alt}


# Inside the chosen component, prefer a fully-interior cell (4 in-component
# face neighbors). Tiebreak by smaller squared distance to the component
# centroid, so the player lands near the middle of the patch rather than its
# edge.
func _pick_interior_cell(grid: TerrainGrid, cells: PackedInt32Array, altitude: int) -> Vector2i:
	var w: int = grid.width
	var member := {}
	var sum_x: int = 0
	var sum_y: int = 0
	for idx in cells:
		member[idx] = true
		sum_x += idx % w
		sum_y += idx / w
	var n: int = cells.size()
	var centroid := Vector2(float(sum_x) / n, float(sum_y) / n)
	var dirs: Array[Vector2i] = [
		TerrainCell.DIR_NE,
		TerrainCell.DIR_NW,
		TerrainCell.DIR_SE,
		TerrainCell.DIR_SW,
	]
	var best := Vector2i(-1, -1)
	var best_neighbors: int = -1
	var best_dist_sq: float = INF
	for idx in cells:
		var x: int = idx % w
		var y: int = idx / w
		var neighbors: int = 0
		for d in dirs:
			var nidx: int = (y + d.y) * w + (x + d.x)
			if member.has(nidx):
				neighbors += 1
		var dv := Vector2(x, y) - centroid
		var dist_sq: float = dv.x * dv.x + dv.y * dv.y
		var take: bool = false
		if neighbors > best_neighbors:
			take = true
		elif neighbors == best_neighbors and dist_sq < best_dist_sq:
			take = true
		if take:
			best = Vector2i(x, y)
			best_neighbors = neighbors
			best_dist_sq = dist_sq
	return best


func _is_plateau_cell(c: TerrainCell) -> bool:
	if c.kind != TerrainCell.Kind.GROUND:
		return false
	if c.biome != TerrainCell.Biome.GRASS:
		return false
	if c.ground_shape != TerrainCell.GroundShape.FULL_CUBE \
			and c.ground_shape != TerrainCell.GroundShape.FLAT:
		return false
	if c.object_kind != &"":
		return false
	return true


# A face neighbor is "walkable" if it's GROUND at the same altitude and
# either flat or full-cube (so the player can step laterally), or if it's
# a slope connecting this cell to its high end (alt+2). This is a coarse
# proxy for the Pathfinder's walkability rules — sufficient to reject
# truly isolated 1x1 islands, but doesn't substitute for a runtime path
# check from the player anchor.
func _has_walkable_neighbor(grid: TerrainGrid, cell: Vector2i, alt: int) -> bool:
	var dirs: Array[Vector2i] = [
		TerrainCell.DIR_NE,
		TerrainCell.DIR_NW,
		TerrainCell.DIR_SE,
		TerrainCell.DIR_SW,
	]
	for d in dirs:
		var n: Vector2i = cell + d
		var nc: TerrainCell = grid.at_or_null(n.x, n.y)
		if nc == null or nc.kind != TerrainCell.Kind.GROUND:
			continue
		# Same-altitude flat / full cube → walk laterally.
		if nc.altitude == alt and (
				nc.ground_shape == TerrainCell.GroundShape.FULL_CUBE
				or nc.ground_shape == TerrainCell.GroundShape.FLAT):
			return true
		# Slope on the same tier rising AWAY from us (so the slope's low
		# end touches us) is walkable up. Slope altitude = LOW end.
		if nc.altitude == alt and _slope_rises_in(nc.ground_shape, -d):
			return true
		# Slope at one tier below rising TOWARD us (so its high end sits at
		# our altitude) is walkable down.
		if nc.altitude == alt - 2 and _slope_rises_in(nc.ground_shape, d):
			return true
	return false


# True iff the slope's rise direction matches `dir`. Returns false for
# non-slope shapes.
func _slope_rises_in(shape: int, dir: Vector2i) -> bool:
	match shape:
		TerrainCell.GroundShape.SLOPE_NE: return dir == TerrainCell.DIR_NE
		TerrainCell.GroundShape.SLOPE_NW: return dir == TerrainCell.DIR_NW
		TerrainCell.GroundShape.SLOPE_SE: return dir == TerrainCell.DIR_SE
		TerrainCell.GroundShape.SLOPE_SW: return dir == TerrainCell.DIR_SW
	return false


# Editor-safe cell→world conversion. Mirrors Pathfinder.cell_to_world: uses
# the first wired ground layer's `map_to_local` and strips its altitude lift
# so the result is in the altitude-0 frame. Avoids calling Pathfinder
# (placeholder in editor; not @tool).
func _cell_to_world(cell: Vector2i) -> Vector2:
	for layer in ground_layers:
		if layer == null:
			continue
		var p: Vector2 = layer.to_global(layer.map_to_local(cell))
		p.y -= layer.position.y
		return p
	return Vector2.ZERO
