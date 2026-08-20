class_name Player
extends GridWalker

# ============================================================================
# Player — click-to-move path follower
# ============================================================================
#
# Consumes paths from the Pathfinder (fed via ClickToMoveController) and walks
# them cell-by-cell along the four grid axes.
#
# THE STEP MATH LIVES IN GridWalker, not here. This class is what makes that
# walker a PLAYER: the follow camera and its opening pan, the lantern, the
# shadow's altitude cutoff, footstep audio, trampling, and the placement
# handshake with ProceduralWorld. Everything about how a character moves — step
# timing, the 4-facing x 6-frame cycle, ladder interpolation, the Y-sort and
# altitude bookkeeping — is inherited, and a fix to any of it belongs there and
# is inherited by Visitor too. (It used to exist in BOTH files, which is exactly
# the divergence this migration removed: the per-step world-position caching
# added for visitors did nothing for the player until it landed here.)
#
# The five hooks GridWalker exposes carry everything this class adds:
#   _on_step_started    footstep SFX, trampling, per-cell shadow roughness
#   _on_visual_lift     camera and lantern follow the FEET, not the sort point
#   _on_path_blocked    warn — a click-to-move path into a wall is a bug here,
#                       where for a visitor it is a fence going up mid-walk
#   _rewind_anim        also rewind the footfall counter
#   anim_frame()        the monotonic cycle index footfalls are counted from
#
# The node is a plain Node2D. It was a CharacterBody2D that never called
# move_and_slide and carried a CollisionShape2D nothing ever queried — there is
# no physics anywhere in this project.
#
# ============================================================================


# Frames of the walk cycle where a foot contacts the ground, authored in the
# sprite sheet. Footstep SFX fire on these, so the sound lands with the visible
# footfall instead of on a clock of its own. At WALK_FPS these two are evenly
# spaced (3 frames apart), giving a footfall every 0.375 s while walking.
const WALK_CONTACT_FRAMES: Array[int] = [2, 5]

@export var debug_logging: bool = false

@export_group("Lantern")
## Time of day [0..1] when lantern turns on (e.g., 0.75 = dusk).
@export var lantern_activate_time: float = 0.75
## Time of day [0..1] when lantern turns off (e.g., 0.28 = dawn).
@export var lantern_deactivate_time: float = 0.28
## Character sheet drawn while the lantern is lit (the campesino holding it).
## Must share the authored day sheet's layout — the swap keeps `frame`.
@export var night_sprite_texture: Texture2D
## Matching night silhouette for the ground shadow.
@export var night_shadow_texture: Texture2D

# --- Held item -------------------------------------------------------------
#
# The player holds at most one object, DERIVED from time of day rather than
# stored: the lantern at night, nothing during the day. There's no manual
# "equip" UI. _update_lantern reads this each frame to drive the light.

## Identifiers returned by held_item(). Empty = nothing in hand.
const ITEM_NONE: StringName = &""
const ITEM_LANTERN: StringName = &"lantern"

@onready var _camera: Camera2D = $Camera2D
@onready var _light: PlayerLightController = $PlayerLight
@onready var _footsteps: FootstepAudio = $FootstepAudio

# Running count of foot contacts the walk cycle has passed since the last idle.
# Compared each tick to fire footstep SFX; counting (rather than testing
# "is the current frame a contact frame?") means a frame hitch that skips past
# a contact still produces exactly one footfall, never zero and never a burst.
var _contacts_passed: int = 0

# Lerped shadow taper cutoff (screen px from entity cell center, positive in
# the taper direction). _push_shadow_cell_state computes a target from the
# pathfinder's altitude deltas; _tick_shadow_cutoff slides current toward target
# at iso step speed (cell_width / step_duration) so the shadow extends/retracts
# at roughly the same pace as the player walks. The "no clip" sentinel is
# pinned to the shadow's own max extent (+ 1 px) so the lerp range stays
# within visible territory — no point lerping through values past where the
# shape would draw anyway.
const _SHADOW_CUTOFF_CELL_W: float = 32.0
const _SHADOW_CUTOFF_HALF_W: float = 16.0
# "No clip" sentinel pinned just past the shadow's current visual extent
# (recomputed each tick from the live shadow_length, which DayNightController
# drives over the day cycle). Caching it once at _ready was wrong: when the
# day-night system grew the shadow past the cached extent, cutoff_x stayed
# below the actual shadow body and the shader cut off the tail even with
# no real altitude difference.
var _shadow_cutoff_current: float = 1000.0
var _shadow_cutoff_target: float = 1000.0
# The inputs the target above was computed from — see _tick_shadow_cutoff.
# NO_CELL rather than Vector2i.ZERO so the first tick always recomputes: (0, 0)
# is a real cell a map could start the player on.
var _shadow_cutoff_cell: Vector2i = Pathfinder.NO_CELL
var _shadow_cutoff_sign: int = 0

# Day sheets, read off the bound sprites in _ready rather than exported a second
# time: the scene already names them, and two @exports for the same art is two
# places to forget. `_lantern_art_lit` is the last state pushed, so the per-frame
# poll in _update_lantern only touches the textures on an actual edge.
var _day_sprite_texture: Texture2D
var _day_shadow_texture: Texture2D
var _lantern_art_lit: bool = false

var _time_manager: Node # TimeManager autoload
var _regrowth: Node # RegrowthManager, found lazily by group

# True once the player has been successfully placed at its starting cell.
# Guards _snap_to_starting_cell against running twice (e.g. a stray re-call),
# which would re-trigger the opening camera pan. A FAILED attempt (non-walkable
# grid) leaves this false so a later attempt can still succeed.
var _started: bool = false

# True when a world generator (ProceduralWorld) owns initial placement, set via
# defer_to_external_placement() before generation. Suppresses the player's own
# deferred self-placement so the generator's spawn pick is authoritative on
# procedural maps. See _maybe_self_place / snap_to_start.
var _external_placement: bool = false

# True while the opening camera pan is running. Suppresses the per-frame
# camera Y write in _on_visual_lift so the pan is fully decoupled from
# player movement (no tile-cross snaps mid-pan). Cleared by _finish_opening_pan.
var _camera_panning: bool = false

# Tracked every time _on_visual_lift runs (including during pan). Holds
# the local Y the camera would sit at if it were following normally —
# used by the pan _process loop to chase the player's current rest target.
var _camera_target_local_y: float = 0.0

# Opening pan integration state. Drives a sine ease-in/out toward a moving
# target (the player's current rest position) using a remaining-progress
# lerp factor. Falls back to lerp(camera, target, k) per frame.
var _pan_elapsed: float = 0.0
var _pan_duration: float = 0.0
var _pan_eased_prev: float = 0.0
# When the TitleIntro shows a "click to begin" gate, the camera is armed at the
# pan-start pose (_camera_panning true, suppressing the per-frame visual lift)
# but the pan CLOCK is held until the click releases it via start_opening_pan().
var _pan_running: bool = true

# Cell the opening pan CENTERS on at the start (the summit lake), pushed by
# ProceduralWorld before placement. -1 = no lake known → fall back to the old
# start-above-player pose. The pan then moves straight DOWN from this cell's X;
# the horizontal jump to the player is hidden by snap_camera_over_player() once
# the curtain is solid, so all visible camera motion is purely vertical.
var _opening_pan_start_cell: Vector2i = Vector2i(-1, -1)

# Camera target offset (added on top of lift). Positive Y shifts the framing
# downward, putting the player slightly above center and giving more headroom
# below.
const _CAMERA_TARGET_OFFSET_Y: float = -10.0


func _enter_tree() -> void:
	add_to_group(&"player")


func _exit_tree() -> void:
	free_shadow()


func _ready() -> void:
	# Before bind: bind writes the planted-foot frame, and the authored pose is
	# SE. GridWalker's own default is SW (a visitor walks in from the south).
	_facing = FACING_SE

	_pathfinder = get_tree().get_first_node_in_group(Pathfinder.GROUP_NAME) as Pathfinder
	if _pathfinder != null:
		# The shadow's altitude cutoff is derived from the CELLS AROUND the
		# player, so it goes stale when the world changes rather than when the
		# player does — a bridge or a ladder landing next to someone standing
		# still. Cheap to close, and without it the recompute-on-change rule in
		# _tick_shadow_cutoff would be right about its own inputs and wrong about
		# the world they describe.
		_pathfinder.graph_changed.connect(func() -> void:
			_shadow_cutoff_cell = Pathfinder.NO_CELL)

	# Bound even when there is no pathfinder: bind is what reparents the shadow
	# out of this node (so it y-sorts against tiles on its own) and reads the
	# authored sprite/shadow baselines, and none of that depends on a graph.
	# Before bind: bind REPARENTS the shadow out of this node, so `$Shadow` stops
	# resolving the moment it returns.
	_day_sprite_texture = ($Sprite2D as Sprite2D).texture
	_day_shadow_texture = ($Shadow as Sprite2D).texture

	bind(_pathfinder, $Sprite2D as Sprite2D, $Shadow as Sprite2D)

	var shadow_mat := get_shadow_material()
	if shadow_mat != null:
		var seed_no_clip := _shadow_no_clip()
		_shadow_cutoff_current = seed_no_clip
		_shadow_cutoff_target = seed_no_clip
		shadow_mat.set_shader_parameter(&"cutoff_x", seed_no_clip)
	_time_manager = get_node_or_null("/root/TimeManager")

	if _pathfinder == null:
		push_error("Player: no Pathfinder found in group '%s'." % Pathfinder.GROUP_NAME)
		return

	# Pathfinder joins its group in _enter_tree but builds the AStar graph in
	# _ready. Defer the starting-cell snap by one frame so the graph is ready
	# regardless of sibling _ready ordering.
	call_deferred("_maybe_self_place")


# ----------------------------------------------------------------------------
# Public API (called by ClickToMoveController, tests, or future systems)
# ----------------------------------------------------------------------------

func get_shadow_material() -> ShaderMaterial:
	return _shadow_material


func follow_path(cells: Array[Vector2i]) -> void:
	super(cells)
	# If not currently stepping, the next tick will begin one. If currently
	# stepping, that step finishes first (stay grid-aligned) and the new path is
	# consumed from the cell already committed to.
	if debug_logging:
		print("Player: follow_path with %d cells" % cells.size())


# ----------------------------------------------------------------------------
# Frame body
# ----------------------------------------------------------------------------

# Driven from _process (the RENDER clock), not _physics_process. Camera2D's
# position_smoothing runs on CAMERA2D_PROCESS_IDLE by default, i.e. once per
# rendered frame; stepping the player on the 60 Hz physics clock instead left
# the character the only thing on screen with a stale position between ticks,
# so the world scrolled smoothly while the sprite visibly stuttered against it.
# Nothing here needs a fixed timestep. If the camera's process_callback is ever
# switched to PHYSICS, this has to move back with it.
func _process(delta: float) -> void:
	_update_lantern()
	_tick_shadow_cutoff(delta)
	# Movement before the pan integrator below: it chases _camera_target_local_y,
	# which _on_visual_lift writes. Ticking movement after would aim the pan at
	# last frame's rest pose.
	tick_movement(delta)
	# Once per frame rather than from inside the step interpolation, which is
	# where it used to live. Same result — the cycle only advances while
	# stepping, and the count is monotonic — with one call site instead of two.
	_tick_footfalls(anim_frame())

	if not _camera_panning or not _pan_running:
		return
	_pan_elapsed += delta
	# Straight-down pan: ease only the camera's Y toward the player's rest Y.
	# X is left untouched — it starts at the lake's X and is snapped to the
	# player's X by snap_camera_over_player() while the curtain is solid, so the
	# horizontal correction is never visible. All seen motion stays vertical.
	var target_y: float = _camera_pan_target_world().y
	if _pan_elapsed >= _pan_duration:
		_camera.position.y = target_y
		_finish_opening_pan()
		return
	var t: float = _pan_elapsed / _pan_duration
	# Sine ease-in/out: -0.5 * (cos(PI*t) - 1) ∈ [0, 1].
	var eased: float = -0.5 * (cos(PI * t) - 1.0)
	# Remaining-progress lerp factor. Equivalent to a fixed sine curve when
	# the target is static, but tracks a moving target smoothly because k
	# applies to the *current* gap, not a stale start point.
	var k: float = (eased - _pan_eased_prev) / maxf(1.0 - _pan_eased_prev, 0.0001)
	_camera.position.y = lerpf(_camera.position.y, target_y, k)
	_pan_eased_prev = eased


# ----------------------------------------------------------------------------
# GridWalker hooks
# ----------------------------------------------------------------------------

## A step onto `cell` began. `current_cell` is already `cell` — GridWalker
## commits the logical cell at step START so a re-path mid-step plans from the
## cell being committed to, which is what _push_shadow_cell_state wants.
func _on_step_started(cell: Vector2i, kind: int) -> void:
	# Footstep SFX. Keyed on the DESTINATION cell — the surface being stepped
	# onto. FootstepAudio runs its own free-running footfall clock (a pace is
	# shorter than a tile), so this only refreshes the surface/interval; the
	# rhythm is not restarted per cell.
	if _footsteps != null:
		_footsteps.step_started(_pathfinder, cell, kind)
	# The player wears the ground too, at player_trample_fraction of a visitor's
	# rate. Keyed on the DESTINATION cell, like the footstep above and like
	# Visitor._on_step_started, so all traffic damages the same cell of a step.
	_trample(cell)
	_push_shadow_cell_state()


## A queued path ran into a wall. Warned here and not in GridWalker because the
## two subclasses mean different things by it: for a Visitor it is the player
## fencing its route, which is expected and handled by a re-path; for the
## player it means ClickToMoveController handed over a path the graph no longer
## supports, which is a bug worth seeing.
func _on_path_blocked(cell: Vector2i) -> void:
	push_warning("Player: path step into non-walkable cell %s; aborting path." % cell)


## The camera and the lantern follow the player's FEET, so both ride the same
## lift that undoes altitude and the sort offset on the sprite.
func _on_visual_lift(lift: float) -> void:
	# Always cache the local target Y so the opening-pan _process loop can
	# read an up-to-date rest position even while we're not writing to the
	# camera (pan owns the camera transform during top_level mode).
	_camera_target_local_y = lift + _CAMERA_TARGET_OFFSET_Y
	if not _camera_panning:
		_camera.position.y = _camera_target_local_y
	_light.position.y = _base_sprite_offset_y + lift


## Going idle rewinds the walk cycle, and the footfall counter is part of that
## cycle: without this the next walk's first contact frame would be compared
## against the last walk's total and produce no footfall at all.
func _rewind_anim() -> void:
	super()
	_contacts_passed = 0


# ----------------------------------------------------------------------------
# Trampling
# ----------------------------------------------------------------------------

# Feet wear the grass, at a tenth of a visitor's rate (RegrowthManager owns the
# ratio). Mirrors Visitor._trample, including the LITERAL group name: naming
# RegrowthManager here would make regrowth_manager.gd a compile-time dependency
# of player.gd, and it references three autoloads — which do not exist when a
# `--script` tool loads a gameplay scene, silently unbinding this script.
func _trample(cell: Vector2i) -> void:
	if _regrowth == null or not is_instance_valid(_regrowth):
		_regrowth = get_tree().get_first_node_in_group(&"regrowth")
		if _regrowth == null:
			return
	_regrowth.call(&"trample_by_player", cell)


# ----------------------------------------------------------------------------
# Footstep audio
# ----------------------------------------------------------------------------

# Fire a footstep for every foot contact the walk cycle has passed since the
# last call. `abs_frame` is the cycle-absolute frame index (not wrapped), so
# _contacts_passed is monotonic while walking and a plain > comparison is enough
# — no edge-detection state to get wrong at cycle wrap or on a repeated call
# with the same frame.
func _tick_footfalls(abs_frame: int) -> void:
	if _footsteps == null:
		return
	var total := _contacts_total(abs_frame, walk_frames_per_dir)
	if total <= _contacts_passed:
		return
	_contacts_passed = total
	_footsteps.footfall()


# Number of foot contacts at or before `abs_frame`. Counts whole cycles, then
# the contacts reached within the partial cycle. Reads WALK_CONTACT_FRAMES
# rather than assuming the contacts are evenly spaced, so re-authoring the
# sheet's contact frames is a one-line change with no other edits.
#
# `frames_per_dir` is passed rather than read off the instance so this stays
# STATIC and unit-testable without a Player (which needs its scene children).
static func _contacts_total(abs_frame: int, frames_per_dir: int) -> int:
	if abs_frame < 0 or frames_per_dir <= 0:
		return 0
	var total: int = (abs_frame / frames_per_dir) * WALK_CONTACT_FRAMES.size()
	var within: int = abs_frame % frames_per_dir
	for c: int in WALK_CONTACT_FRAMES:
		if c <= within:
			total += 1
	return total


# ----------------------------------------------------------------------------
# Shadow altitude cutoff
# ----------------------------------------------------------------------------

func _push_shadow_cell_state() -> void:
	# Push per-cell roughness on cell-change. The cutoff target is recomputed
	# every tick in _tick_shadow_cutoff, so it doesn't belong here — leaving
	# it out keeps it from going stale when shadow_length drifts mid-cell.
	if _pathfinder == null or _shadow_material == null:
		return
	_shadow_material.set_shader_parameter(&"roughness", _pathfinder.roughness_at(current_cell))


# First mismatching neighbor in (deltas.x, deltas.y, deltas.z) sets the cutoff
# at its near edge. 0.25 threshold tolerates float noise on half-integer
# altitudes; sentinel deltas (empty / non-walkable, e.g. 99.0) also trip it.
func _cutoff_from_deltas(deltas: Vector3) -> float:
	if absf(deltas.x) > 0.25:
		return _SHADOW_CUTOFF_HALF_W
	if absf(deltas.y) > 0.25:
		return _SHADOW_CUTOFF_HALF_W + _SHADOW_CUTOFF_CELL_W
	if absf(deltas.z) > 0.25:
		return _SHADOW_CUTOFF_HALF_W + 2.0 * _SHADOW_CUTOFF_CELL_W
	return _shadow_no_clip()


# Pixel extent the shadow currently reaches along its taper. Read live from
# the shader uniform every call because DayNightController drives
# shadow_length over the day cycle — caching at _ready would let cutoff_x
# fall behind as the shadow grows past the cached value.
func _shadow_no_clip() -> float:
	if _shadow_material == null:
		return 1000.0
	var slen_v: Variant = _shadow_material.get_shader_parameter(&"shadow_length")
	var capw_v: Variant = _shadow_material.get_shader_parameter(&"cap_width")
	var slen: float = absf(float(slen_v)) if slen_v != null else 0.0
	var capw: float = float(capw_v) if capw_v != null else 0.0
	return slen + capw + 1.0


# Slide _shadow_cutoff_current toward _shadow_cutoff_target at iso step speed
# and push the result. Called every frame from _process so the shadow
# extends/retracts at the same pace as the player walks.
func _tick_shadow_cutoff(delta: float) -> void:
	if _shadow_material == null:
		return
	# The TARGET is recomputed only when one of its two inputs actually moves.
	#
	# It used to be recomputed every frame, justified by shadow_length being
	# animated by DayNightController — but only the SIGN of shadow_length is
	# read here, and that flips twice a day. The other input is current_cell,
	# which changes once per step (~0.6 s). So a value that can change about
	# twice a second was being rebuilt sixty times a second, and it is not
	# cheap: shadow_altitude_deltas scans all 17 TileMapLayers for the topmost
	# painted tile at up to 4 cells along the shadow direction — ~68 layer
	# queries. MEASURED at 171.9 us per call, which was the ENTIRE per-frame
	# cost of the Player node and the single largest script cost in the game.
	#
	# Compared against cached inputs rather than driven from a step hook, so it
	# cannot miss an edge that some other code path moves the player through
	# (a teleport, snap_to_start, a world regeneration).
	var slen_v: Variant = _shadow_material.get_shader_parameter(&"shadow_length")
	var dir_sign: int = 1
	if (typeof(slen_v) == TYPE_FLOAT or typeof(slen_v) == TYPE_INT) and float(slen_v) < 0.0:
		dir_sign = -1
	if _pathfinder != null \
			and (current_cell != _shadow_cutoff_cell or dir_sign != _shadow_cutoff_sign):
		_shadow_cutoff_cell = current_cell
		_shadow_cutoff_sign = dir_sign
		var deltas: Vector3 = _pathfinder.shadow_altitude_deltas(current_cell, dir_sign)
		_shadow_cutoff_target = _cutoff_from_deltas(deltas)
	# Match player iso step speed: one cell-width per step_duration.
	var speed_px_per_sec: float = _SHADOW_CUTOFF_CELL_W / maxf(_step_duration_effective, 0.001)
	if _shadow_cutoff_target > _shadow_cutoff_current:
		# Extending: move outward at step speed.
		_shadow_cutoff_current = minf(
			_shadow_cutoff_target, _shadow_cutoff_current + speed_px_per_sec * delta
		)
	else:
		# Retracting: move inward at step speed.
		_shadow_cutoff_current = maxf(
			_shadow_cutoff_target, _shadow_cutoff_current - speed_px_per_sec * delta
		)
	# Avoid noise: when within 0.5 px of target, snap to target.
	if absf(_shadow_cutoff_current - _shadow_cutoff_target) < 0.5:
		_shadow_cutoff_current = _shadow_cutoff_target
	_shadow_material.set_shader_parameter(&"cutoff_x", _shadow_cutoff_current)


# ----------------------------------------------------------------------------
# Lantern
# ----------------------------------------------------------------------------

# Pure night-window test. activate > deactivate means the active window wraps
# past midnight (e.g. dusk 0.75 → dawn 0.28). Static so it can be unit-tested
# without a Player instance (see tests/test_lantern_logic.gd).
static func is_night(t: float, activate: float, deactivate: float) -> bool:
	if activate > deactivate:
		return t >= activate or t < deactivate
	return t >= activate and t < deactivate


## The object currently in the player's hand (derived; see the held-item note).
## The lantern at night, nothing by day.
func held_item() -> StringName:
	var night := false
	if _time_manager != null:
		night = is_night(_time_manager.time_of_day, lantern_activate_time, lantern_deactivate_time)
	return ITEM_LANTERN if night else ITEM_NONE


# The lantern is lit iff it's the currently held item — i.e. it's night.
func _update_lantern() -> void:
	if held_item() == ITEM_LANTERN:
		_light.activate()
	else:
		_light.deactivate()
	# Keyed on the LIGHT, not on held_item(): activate/deactivate fade over
	# transition_duration, and `enabled` spans exactly that fade. Swapping off
	# held_item() instead would pull the lantern out of the character's hand at
	# dawn while its glow was still fading — a light with no source for a second.
	_apply_lantern_art(_light.is_lit())


# Swap the character + shadow sheets between the day and lantern-lit variants.
# The night sheets share the day sheets' frame layout, so `frame`, `hframes` and
# the facing row all survive untouched — only the pixels change.
func _apply_lantern_art(lit: bool) -> void:
	if lit == _lantern_art_lit:
		return
	_lantern_art_lit = lit
	if _sprite != null:
		var sprite_tex := night_sprite_texture if lit else _day_sprite_texture
		if sprite_tex != null:
			_sprite.texture = sprite_tex
	if is_instance_valid(_shadow):
		var shadow_tex := night_shadow_texture if lit else _day_shadow_texture
		if shadow_tex != null:
			_shadow.texture = shadow_tex


# ----------------------------------------------------------------------------
# Startup positioning
# ----------------------------------------------------------------------------

# Called by ProceduralWorld AFTER it has positioned the player on its chosen
# spawn cell. The generator is the sole placement authority on procedural maps
# (it picks a grass-plateau center, not the authored node position), so this is
# what establishes current_cell, the altitude lift, the sort-Y, and the opening
# camera pan against the cell the generator actually moved the player to.
#
# Without this — or if the player's own self-placement (see _maybe_self_place)
# were allowed to win — global_position and current_cell would describe two
# DIFFERENT cells: the visual sits at the spawn while the logic thinks it's at
# the authored cell, giving a wrong altitude lift (renders behind tiles) and
# pathing from the wrong cell (can't move).
func snap_to_start() -> void:
	_snap_to_starting_cell()


## Point the opening camera pan's START at a grid cell (the summit lake). Called
## by the world generator (ProceduralWorld) before snap_to_start. The camera
## centers here and then pans straight down to the player.
func set_opening_pan_start_cell(cell: Vector2i) -> void:
	_opening_pan_start_cell = cell


# Deferred from _ready as the FALLBACK placement for non-procedural maps (test
# scenes, handcrafted levels) where the player's authored position is its spawn
# and no generator will call snap_to_start. On procedural maps ProceduralWorld
# calls defer_to_external_placement() before generating, which suppresses this
# so the generator's spawn pick is the only placement. The flag is read here at
# DEFERRED (idle) time, so it doesn't matter whether Player._ready or
# ProceduralWorld._ready ran first — the generator's claim always lands before
# this executes.
func _maybe_self_place() -> void:
	if _external_placement:
		return
	_snap_to_starting_cell()


## Claim placement authority. ProceduralWorld calls this before generating so
## the player's deferred self-placement stands down and waits for snap_to_start.
func defer_to_external_placement() -> void:
	_external_placement = true


func _snap_to_starting_cell() -> void:
	# Guard re-entrancy: once placed, ignore further calls so the camera pan
	# isn't set up twice.
	if _started:
		return
	if _pathfinder == null:
		return

	var start := _pathfinder.world_to_cell(global_position)
	if not _pathfinder.is_walkable(start):
		# Don't set _started — the grid may simply not be painted yet (async
		# startup). Leaving it false lets the ProceduralWorld-driven retry place
		# the player once the terrain exists.
		push_warning(
			"Player: starting position %s resolves to non-walkable cell %s. "
			% [global_position, start]
			+"Move the player node in the editor to a walkable cell."
		)
		return

	_started = true
	place_at(start)
	_push_shadow_cell_state()
	# Initial snap: skip the lerp on first frame so the shadow starts in its
	# correct extent rather than retracting in from "no clip".
	_shadow_cutoff_current = _shadow_cutoff_target

	# Opening camera pan: fully detached from player movement (top_level so
	# the parent transform is ignored). The pan target is recomputed every
	# frame in _process so the camera converges on wherever the player
	# currently is — if they walk during the pan, the landing point follows.
	#
	# Pan parameters live on TitleIntro so designers tune them alongside the
	# intro timing. The lookup relies on Godot's deferred ordering: TitleIntro
	# adds itself to the group in _ready (sync) before any deferred free, and
	# this method is itself deferred from Player._ready, so the group entry is
	# always live when we read it. If TitleIntro is absent (test scenes), we
	# skip the pan entirely rather than guess a duration that drifts from the
	# intro's actual length.
	var intro := get_tree().get_first_node_in_group(&"title_intro") as TitleIntro
	if intro == null:
		_camera_panning = false
	else:
		var rest_world := _camera_pan_target_world()
		# Pan START pose: centered on the summit lake when the generator told us
		# where it is, else the old pose just above the player. From here the pan
		# only ever moves straight DOWN (X is held; the horizontal correction to
		# the player is hidden later by snap_camera_over_player()).
		var start_world: Vector2
		if _opening_pan_start_cell.x >= 0:
			start_world = _cell_camera_world(_opening_pan_start_cell)
		else:
			start_world = Vector2(rest_world.x, rest_world.y - intro.pan_offset_px)
		_camera_panning = true
		_pan_elapsed = 0.0
		_pan_duration = intro.get_pan_duration()
		_pan_eased_prev = 0.0
		_camera.position_smoothing_enabled = false
		_camera.top_level = true
		_camera.position = start_world
		# Hold the pan clock while the click-to-begin gate is up; TitleIntro
		# releases it via start_opening_pan() on the first click.
		_pan_running = not intro.is_awaiting_click()

	if debug_logging:
		print("Player: snapped to cell %s at altitude %s" % [current_cell, current_altitude()])


# ----------------------------------------------------------------------------
# Opening camera pan
# ----------------------------------------------------------------------------

# Player's current rest position in world space. Used as the pan's moving
# target — if the player walks during the pan, the camera homes in on them
# wherever they end up. Y uses the cached local target (which already
# includes y_visual_diff compensation) so mid-step tile snaps don't bleed
# through.
func _camera_pan_target_world() -> Vector2:
	return Vector2(global_position.x, global_position.y + _camera_target_local_y)


# World position to center the camera on a cell, including its altitude lift
# (cell_to_world returns the altitude-0 origin; the visual surface sits
# alt*HALF_STEP_PX higher on screen). Used to aim the opening pan at the lake.
func _cell_camera_world(cell: Vector2i) -> Vector2:
	var w := _pathfinder.cell_to_world(cell)
	w.y -= _pathfinder.altitude_center(cell) * Pathfinder.HALF_STEP_PX
	return w


# Snap the camera's X directly over the player. Called by TitleIntro the instant
# the curtain is fully opaque, hiding the lake→player horizontal jump. The pan
# keeps easing Y down afterward, so all visible motion stays vertical.
func snap_camera_over_player() -> void:
	if not _camera_panning:
		return
	_camera.position.x = _camera_pan_target_world().x


# Release the opening pan clock. Called by TitleIntro when the player clicks
# through the "click to begin" gate so the pan begins exactly as the cinematic
# starts. No-op when there's no gate (the pan was already running).
func start_opening_pan() -> void:
	_pan_running = true


# Snap the opening pan to its endpoint and hand the camera back to player
# follow. Called by TitleIntro when the player skips the title card so the
# pan doesn't keep drifting after the curtain clears. No-op if the pan is
# not active (already finished or never started).
func finish_opening_pan_now() -> void:
	if not _camera_panning:
		return
	_camera.position = _camera_pan_target_world()
	_finish_opening_pan()


# Hand the camera back to the player-follow path after the opening pan.
# Order matters: re-enable smoothing and call reset_smoothing() while the
# camera is still at its world-space pan endpoint so the smoothed view is
# seeded there. Then drop top_level and write the correct local target.
func _finish_opening_pan() -> void:
	_camera.position_smoothing_enabled = true
	_camera.reset_smoothing()
	_camera.top_level = false
	_camera.position = Vector2(0.0, _camera_target_local_y)
	_camera_panning = false
