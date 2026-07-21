class_name TitleIntro
extends CanvasLayer

# ============================================================================
# TitleIntro — opening title card overlay
# ============================================================================
#
# Plays a short cinematic on session start:
#   1. Curtain (color_a) fades in with title shown static on frame 0.
#   2. Brief static hold so the player registers the title.
#   3. Curtain snaps to color_b (warm flash).
#   4. Title plays through 24 animated frames once.
#   5. After reaching the last frame, loops only the tail (frames 16..23)
#      indefinitely until fade-out begins. The animation keeps ticking
#      through the fade-out so it stays "alive".
#   6. Curtain + title fade out together, revealing the gameplay scene
#      that has been silently rendering underneath the whole time.
#
# Designed to coexist with the player's opening camera pan (player.gd,
# OPENING_PAN_DURATION). The intro does NOT touch the camera or pan; it
# just paints over the screen briefly. The pan keeps running underneath
# and is still in motion long after the title clears.
#
# Skippable: a key / joypad press fast-forwards to a quick fade-out and frees
# the node. Mouse clicks are swallowed but do NOT skip.
# Skipping also snaps the opening camera pan to its endpoint (via
# Player.finish_opening_pan_now) so the camera doesn't keep drifting after
# the curtain clears.
#
# Sits on a high CanvasLayer (layer = 200) so it draws above the post-process
# layer (layer = 100). Otherwise vignette/tint would bleed into the title.
#
# Frame swapping uses a single AtlasTexture whose `region` is mutated each
# tick. Cheaper than swapping textures and keeps the existing TextureRect
# layout (EXPAND_IGNORE_SIZE + KEEP_ASPECT_CENTERED) intact.
#
# Unity bridge:
# - CanvasLayer ≈ Screen-space Overlay Canvas with a sort order.
# - Tween is retained-mode: create_tween() -> chain -> run. set_parallel(true)
#   makes subsequent tweens run concurrently (like Task.WhenAll).
# - `await tween.finished` ≈ `yield return tween` in legacy Unity coroutines.
# - AtlasTexture ≈ a Sprite atlas sub-rect; mutating .region is like changing
#   uvRect on a RawImage in uGUI.
#
# ============================================================================


## Set false on debug/test scenes to skip the intro entirely.
@export var play_intro: bool = true

## If true (and play_intro), the intro does NOT auto-run. Instead a frozen
## navy "click to begin" screen is shown and the cinematic + music + fullscreen
## are all triggered by the first click / key press. Set false to restore the
## old auto-running intro (e.g. on debug scenes that want no gate).
@export var wait_for_click: bool = true

## Curtain color shown during the initial reveal + static hold. Cold paramo
## pre-dawn navy.
@export var color_a: Color = Color(0.04, 0.09, 0.18, 1.0)

## Curtain color flashed to right before the animation plays. Warm dusk
## terracotta — high-contrast against color_a so the flash reads as an event,
## not a tint shift. Evokes first sunlight cracking the ridge.
@export var color_b: Color = Color(0.85, 0.42, 0.28, 1.0)

## Animated title spritesheet. 24 horizontal frames at 256x64 each
## (6144x64 total). Frame 0 is the static title shown during the initial hold.
@export var animated_texture: Texture2D

## Number of frames in the spritesheet.
@export var frame_count: int = 24

## Pixel size of a single frame.
@export var frame_size: Vector2i = Vector2i(256, 64)

## After the one-shot 0..frame_count-1 play, looping continues from this
## frame to the last frame inclusive. Default 16 → tail-loop the last 8.
@export var loop_start_frame: int = 16

## How long to hold on frame 0 with color_a curtain before the flash.
@export var static_hold: float = 0.7

## Duration of the curtain color_a → color_b transition. Short = feels like
## a hard cut / event; longer = mood crossfade. 0.05 = effectively a snap.
@export var flash_duration: float = 0.05

## Animation playback rate for the one-shot 0..23 sweep AND the tail loop.
@export var anim_fps: float = 14.0

@export_group("Camera Pan")
## Vertical offset (pixels) the camera starts above the player at pan start.
## Player.gd reads this via the "title_intro" group at scene start.
@export var pan_offset_px: float = 120.0
## Extra pan time AFTER the intro finishes. The total pan duration is
## (full intro duration) + this value, so the camera keeps drifting after
## the title clears. Set to 0 to land exactly when the fade-out ends.
@export var pan_additional_duration: float = 4.0

@export_group("Intro")
## Delay before the intro starts. The panning gameplay scene is visible
## during this window (curtain alpha = 0). Use to let the player register
## the world before the title overlay appears.
@export var start_delay: float = 1.5

## If true, sets TimeManager.time_of_day to night_time_of_day at intro start
## and to day_time_of_day once the curtain has fully faded in.
@export var control_time_of_day: bool = true

## Time-of-day (normalized 0..1) set at intro start. 0.0 = midnight.
@export_range(0.0, 1.0, 0.001) var night_time_of_day: float = 0.0

## Time-of-day (normalized 0..1) set after the curtain has fully faded in.
## 10:00 = 10/24 ≈ 0.4167.
@export_range(0.0, 1.0, 0.001) var day_time_of_day: float = 0.41667

## Curtain alpha ramp-in duration.
@export var curtain_fade_in: float = 2.0
## Title alpha ramp-in duration (runs in parallel with curtain fade-in).
@export var title_fade_in: float = 1.5
## Delay before the title fade-in begins, so it reads as one reveal with the curtain.
@export var title_fade_in_delay: float = 0.5
## Hold AFTER the one-shot animation completes; tail loop runs through this
## window before fade-out begins.
@export var hold_duration: float = 2.5
## Curtain + title fade-out duration at the end of the intro.
@export var fade_out_duration: float = 4.5
## Skip-fade duration when the player presses any input. Fast but not instant.
@export var skip_fade_duration: float = 0.15

@export_group("Click Prompt")
## Alpha the "click to begin" prompt settles to when the mouse is far away.
@export_range(0.0, 1.0, 0.01) var prompt_min_alpha: float = 0.08
## Alpha the prompt reaches when the mouse is on top of it.
@export_range(0.0, 1.0, 0.01) var prompt_max_alpha: float = 1.0
## Distance from the prompt at which intensity bottoms out at prompt_min_alpha.
## Measured in the project's base-resolution units (stretch=canvas_items over a
## 480x270 viewport), NOT physical pixels — so this spans the on-screen space
## regardless of window size. Center-to-corner is ~275, so ~200 uses the full
## intensity range across the visible screen.
@export var prompt_falloff_px: float = 200.0
## Exponential smoothing rate for the intensity ramp (higher = snappier follow).
@export var prompt_track_speed: float = 10.0


## Sum of every sequence stage in _run_intro. Player reads this (plus
## pan_additional_duration) as the total opening camera pan duration.
##
## Each stage exposes a paired _stage_*_duration() so this sum cannot drift
## from the actual sequence body — adding a stage means adding both the body
## and its duration helper, and the total updates here automatically.
func get_total_intro_duration() -> float:
	return (
		_stage_preroll_duration()
		+ _stage_reveal_duration()
		+ _stage_static_hold_duration()
		+ _stage_flash_duration()
		+ _stage_animation_hold_duration()
		+ _stage_fade_out_duration()
	)


## Total opening camera pan duration. Player.gd reads this via the
## "title_intro" group.
func get_pan_duration() -> float:
	return get_total_intro_duration() + pan_additional_duration


@onready var _curtain: ColorRect = $Curtain
@onready var _title: TextureRect = $Title
@onready var _click_label: Label = $ClickToBegin

# True while the frozen "click to begin" gate is showing and waiting for the
# first input. Read by Player (is_awaiting_click) to hold the opening pan clock.
var _awaiting_click: bool = false
# True between _ready and gate activation: the world is still generating behind
# the loading overlay, so the prompt is hidden and all input is swallowed (no
# begin yet). Cleared by _activate_gate on ProceduralWorld.generation_finished.
var _gate_pending: bool = false
# True while the click prompt is tracking the mouse (from gate activation until
# the first click). Drives per-frame proximity intensity in _process.
var _tracking_prompt: bool = false
# TimeManager.paused snapshot taken when the gate freezes time-of-day, restored
# when the click starts the cinematic.
var _was_time_paused: bool = false

var _atlas: AtlasTexture
var _current_frame: int = 0
var _frame_accumulator: float = 0.0
var _animating: bool = false
var _looping_tail: bool = false

var _active_tween: Tween
var _skipped: bool = false
var _running: bool = false
var _time_manager: Node

# Nodes whose process_mode we flip to DISABLED for the duration of the intro
# and restore on finish/skip. Any hover-poll or per-frame UX driver belongs
# here; per-event input is already swallowed by _input().
var _gated_nodes: Array[Node] = []
var _gated_visible: Dictionary = {}
var _gated_process_mode: Dictionary = {}

# Bumped every time a skip is requested. Each `await` in _run_intro captures
# the token at entry and bails if the token has changed when it wakes.
# Necessary because Tween.kill() does NOT emit `finished` (godot#84615) and
# SceneTreeTimer.timeout fires regardless of any node state — without a token
# guard, parked coroutines can wake on a freed node and re-enter the sequence.
var _cancel_token: int = 0


func _ready() -> void:
	# This layer must draw above post-process (UILayers.POST_PROCESS). Set in code
	# as well as the scene so refactors of the scene file can't quietly break it.
	layer = UILayers.TITLE

	# Register so Player can read pan_offset_px / pan_duration without a hard
	# NodePath dependency. Done before any early-return so designers tweaking
	# pan values still apply when play_intro is false.
	add_to_group(&"title_intro")

	if not play_intro:
		# Defer free so Player's _ready (which queries this group) can run first.
		set_process(false)
		call_deferred("queue_free")
		return

	_time_manager = get_node_or_null("/root/TimeManager")
	# Set night IMMEDIATELY in _ready so the very first rendered frame is
	# already night-graded — avoids a one-frame flash of the default time.
	if control_time_of_day and _time_manager != null and _time_manager.has_method("set_time"):
		_time_manager.set_time(night_time_of_day)

	# Initialize state BEFORE any frame paints. ColorRect default modulate is
	# white-opaque; we want fully transparent so the first frame shows
	# gameplay, not a blue flash one frame too early.
	_curtain.color = color_a
	_curtain.modulate.a = 0.0

	# Build a single AtlasTexture pointing at the spritesheet, region locked
	# to frame 0. We mutate `.region` to swap frames — cheaper than swapping
	# the whole Texture2D and keeps TextureRect's stretch/expand settings stable.
	_atlas = AtlasTexture.new()
	_atlas.atlas = animated_texture
	_atlas.region = _frame_rect(0)
	_title.texture = _atlas
	_title.modulate.a = 0.0

	# Curtain and title are pure visual; clicks must pass through them so the
	# global _input() handler is what consumes events (uniform behavior for
	# mouse/key/joypad — see _input).
	_curtain.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE

	_gate_gameplay_ux()

	if wait_for_click:
		# Frozen entry screen, shown ONCE the terrain has generated: the world is
		# revealed at the camera's lake-centered start pose (curtain transparent,
		# title hidden) with a "click to begin" prompt. The whole cinematic — navy
		# fade-in, title, music, fullscreen and the straight-down camera pan — is
		# deferred to the first click (see _begin_from_click). The opening pan is
		# held by Player (it reads is_awaiting_click()), and TimeManager is paused
		# so the static view stays at night until the click.
		#
		# Until generation finishes (loading overlay up, layer 128, below this
		# layer 200), the gate stays PENDING: prompt hidden, all input swallowed,
		# no begin. _activate_gate flips it on at ProceduralWorld.generation_finished.
		_curtain.modulate.a = 0.0
		_title.modulate.a = 0.0
		_click_label.modulate.a = 0.0
		if _time_manager != null:
			_was_time_paused = _time_manager.paused
			_time_manager.paused = true
		_gate_pending = true
		var pw := get_tree().get_first_node_in_group(&"procedural_world")
		if pw != null and pw.has_signal(&"generation_finished"):
			pw.connect(&"generation_finished", _activate_gate, CONNECT_ONE_SHOT)
		else:
			# No async generation (handcrafted/test maps): world is ready now.
			_activate_gate()
		return

	# No gate: auto-run the intro and hide the prompt.
	_click_label.visible = false
	_run_intro()


# ----------------------------------------------------------------------------
# Gameplay UX gating
#
# Hover-poll systems (UXOverlay) read mouse position every frame regardless
# of input events, so swallowing events alone is not enough — they keep
# drawing hover decorations. Suspend their _process via process_mode and
# hide them while the intro plays. Restored in _restore_gameplay_ux().
# ----------------------------------------------------------------------------

func _gate_gameplay_ux() -> void:
	var tree := get_tree()
	if tree == null:
		return
	# UXOverlay drives the hover cursor and candidate hints. Disable + hide.
	for n: Node in tree.get_nodes_in_group(&"ux_overlay"):
		_register_gated(n)
	# HUD (minimap, equipped slot, season wheel) — hide for the whole cinematic
	# so it doesn't sit over the pre-title lake shot. Restored in
	# _restore_gameplay_ux when the intro finishes.
	for n: Node in tree.get_nodes_in_group(&"hud"):
		_register_gated(n)


func _register_gated(node: Node) -> void:
	if node == null or _gated_nodes.has(node):
		return
	_gated_nodes.append(node)
	# Both CanvasItem (Control/Node2D) and CanvasLayer (e.g. the HUD) expose
	# `visible`; they share no common base that declares it, so snapshot + clear
	# it dynamically. Hiding the CanvasLayer also hides its whole subtree.
	if node is CanvasItem or node is CanvasLayer:
		_gated_visible[node] = node.get(&"visible")
		node.set(&"visible", false)
	# Snapshot process_mode so a node authored with PROCESS_MODE_ALWAYS isn't
	# silently downgraded to INHERIT on restore.
	_gated_process_mode[node] = node.process_mode
	node.process_mode = Node.PROCESS_MODE_DISABLED


# Restore a single gated node's process_mode + visibility and drop it from the
# tracking dicts, so a later blanket restore won't touch it again.
func _restore_gated_node(node: Node) -> void:
	if is_instance_valid(node):
		if _gated_process_mode.has(node):
			node.process_mode = _gated_process_mode[node]
		if _gated_visible.has(node):
			node.set(&"visible", _gated_visible[node])
	_gated_nodes.erase(node)
	_gated_visible.erase(node)
	_gated_process_mode.erase(node)


# Re-enable the HUD ahead of the general restore. Called at the flash: the
# curtain is still fully opaque, so the HUD (layer 110, below this layer 200)
# is rendered but hidden behind it — then the fade-out reveals a HUD that is
# already live underneath, rather than popping in when the intro frees.
func _restore_hud() -> void:
	var tree := get_tree()
	if tree == null:
		return
	for n: Node in tree.get_nodes_in_group(&"hud"):
		_restore_gated_node(n)


func _restore_gameplay_ux() -> void:
	# Duplicate: _restore_gated_node mutates _gated_nodes as it goes.
	for n: Node in _gated_nodes.duplicate():
		_restore_gated_node(n)
	_gated_nodes.clear()
	_gated_visible.clear()
	_gated_process_mode.clear()


# ----------------------------------------------------------------------------
# Per-frame: drives the title animation. Independent of tweens — keeps
# ticking through the post-anim hold AND through the fade-out.
# ----------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _tracking_prompt:
		_update_prompt_intensity(delta)

	if not _animating:
		return
	if anim_fps <= 0.0:
		return

	_frame_accumulator += delta
	var frame_time: float = 1.0 / anim_fps
	while _frame_accumulator >= frame_time:
		_frame_accumulator -= frame_time
		_advance_frame()


func _advance_frame() -> void:
	if not _looping_tail:
		# One-shot phase: 0 → frame_count-1. On reaching the last frame,
		# flip into tail-loop mode and stay there.
		_current_frame += 1
		if _current_frame >= frame_count - 1:
			_current_frame = frame_count - 1
			_looping_tail = true
	else:
		# Tail loop: stay in [loop_start_frame, frame_count-1].
		_current_frame += 1
		if _current_frame > frame_count - 1:
			_current_frame = loop_start_frame

	_atlas.region = _frame_rect(_current_frame)


func _frame_rect(index: int) -> Rect2:
	var i: int = clamp(index, 0, frame_count - 1)
	return Rect2(
		Vector2(i * frame_size.x, 0),
		Vector2(frame_size.x, frame_size.y)
	)


# ----------------------------------------------------------------------------
# Sequence
# ----------------------------------------------------------------------------

func _run_intro() -> void:
	_running = true
	# Capture token at entry. Every stage await re-checks it on resume; if a
	# skip happened, the token has advanced and we return immediately WITHOUT
	# touching any node (the node may already be queue_freed).
	var token: int = _cancel_token

	if not await _stage_preroll(token): return
	if not await _stage_reveal(token): return
	if not await _stage_static_hold(token): return
	if not await _stage_flash(token): return
	if not await _stage_animation_hold(token): return
	if not await _stage_fade_out(token): return

	_finish()


# ----------------------------------------------------------------------------
# Stages
#
# Each stage is two functions: the body (returns false when cancelled) and
# the duration (consumed by get_total_intro_duration). Adding a stage means
# adding both halves AND wiring it into _run_intro — the duration sum picks
# it up automatically. Bodies are intentionally imperative (a tween/timer DSL
# would obscure timing decisions); the extraction is purely so the duration
# math lives next to the stage that owns it.
# ----------------------------------------------------------------------------

# Stage: pre-roll. Scene plays underneath at night, no curtain yet — lets
# the player register the world before the title overlay appears.
func _stage_preroll(token: int) -> bool:
	if start_delay > 0.0:
		await get_tree().create_timer(start_delay).timeout
	return token == _cancel_token


func _stage_preroll_duration() -> float:
	return start_delay


# Stage: curtain (color_a) ramps up. In parallel, title fade-in is queued
# with a delay so it begins partway through the curtain ramp. Title is shown
# on frame 0 — _animating stays false here. Once the curtain is fully opaque,
# swap the world to daytime; the transition is hidden behind the curtain.
func _stage_reveal(token: int) -> bool:
	var tw: Tween = create_tween().set_parallel(true)
	tw.tween_property(_curtain, "modulate:a", 1.0, curtain_fade_in) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(_title, "modulate:a", 1.0, title_fade_in) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT) \
		.set_delay(title_fade_in_delay)
	_active_tween = tw
	await tw.finished
	if token != _cancel_token:
		return false
	# Curtain is now fully opaque — the hidden moment to snap the camera's X over
	# the player (the lake→player horizontal correction) and swap to daytime, both
	# invisible behind the solid curtain.
	var player := get_tree().get_first_node_in_group(&"player")
	if player != null and player.has_method(&"snap_camera_over_player"):
		player.snap_camera_over_player()
	if control_time_of_day and _time_manager != null and _time_manager.has_method("set_time"):
		_time_manager.set_time(day_time_of_day)
	# Curtain is solid: clear any rain shown over the pre-title lake shot so
	# gameplay begins dry. Normal weather rolls resume from here. Hidden behind
	# the opaque curtain, so there's no visible pop.
	_reset_weather_dry()
	return true


func _stage_reveal_duration() -> float:
	# Parallel branches; stage completes when the slower one finishes.
	return maxf(curtain_fade_in, title_fade_in_delay + title_fade_in)


# Stage: static hold on frame 0 against color_a — gives the player a beat
# to register the title before the flash.
func _stage_static_hold(token: int) -> bool:
	if static_hold > 0.0:
		await get_tree().create_timer(static_hold).timeout
	return token == _cancel_token


func _stage_static_hold_duration() -> float:
	return static_hold


# Stage: flash curtain to color_b. Short tween → feels like a snap / event.
# Using `color` (not modulate) so the curtain stays fully opaque.
func _stage_flash(token: int) -> bool:
	# Bring the HUD back to life now, while the curtain is still opaque and
	# hides it, so the upcoming fade-out reveals a HUD that is already running
	# underneath instead of popping in when the intro frees.
	_restore_hud()
	var tw: Tween = create_tween()
	tw.tween_property(_curtain, "color", color_b, flash_duration) \
		.set_trans(Tween.TRANS_LINEAR)
	_active_tween = tw
	await tw.finished
	return token == _cancel_token


func _stage_flash_duration() -> float:
	return flash_duration


# Stage: kick off animation, then hold while it plays its one-shot then
# tail-loops. The animation is NOT awaited explicitly — by design it runs
# forever until fade-out. The hold gives the tail loop a beat to breathe.
func _stage_animation_hold(token: int) -> bool:
	_animating = true
	if hold_duration > 0.0:
		await get_tree().create_timer(hold_duration).timeout
	return token == _cancel_token


func _stage_animation_hold_duration() -> float:
	return hold_duration


# Stage: both fade out together. Animation keeps ticking through the fade —
# looks more alive than freezing the title at fade-start.
func _stage_fade_out(token: int) -> bool:
	var tw: Tween = create_tween().set_parallel(true)
	tw.tween_property(_curtain, "modulate:a", 0.0, fade_out_duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(_title, "modulate:a", 0.0, fade_out_duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_active_tween = tw
	await tw.finished
	return token == _cancel_token


func _stage_fade_out_duration() -> float:
	return fade_out_duration


# ----------------------------------------------------------------------------
# Click-to-begin gate
# ----------------------------------------------------------------------------

## True while the frozen entry screen is up and waiting for the first input.
## Player reads this so it can hold the opening camera pan until we release it.
func is_awaiting_click() -> bool:
	return _awaiting_click


# Generation finished (loading overlay gone, world visible at the lake): reveal
# the prompt and start accepting the begin click.
func _activate_gate() -> void:
	if not _gate_pending:
		return
	_gate_pending = false
	_awaiting_click = true
	_running = true
	# Start dim; proximity tracking in _process ramps it up as the mouse nears.
	_click_label.modulate.a = prompt_min_alpha
	_tracking_prompt = true


# Per-frame: drive the prompt's alpha from how close the mouse is to it. On top
# of / inside the label → prompt_max_alpha; at prompt_falloff_px or beyond →
# prompt_min_alpha. Uses distance to the label's rect (0 when inside) so the
# whole glyph is the target, not just its center. Exponential smoothing keeps
# the ramp from snapping/jittering as the cursor moves.
func _update_prompt_intensity(delta: float) -> void:
	var rect: Rect2 = _click_label.get_global_rect()
	var m: Vector2 = _click_label.get_global_mouse_position()
	var closest := Vector2(
		clampf(m.x, rect.position.x, rect.end.x),
		clampf(m.y, rect.position.y, rect.end.y)
	)
	var dist: float = m.distance_to(closest)
	# Linear ramp: intensity falls off evenly with distance from the label.
	var t: float = clampf(dist / maxf(prompt_falloff_px, 1.0), 0.0, 1.0)
	var target: float = lerpf(prompt_max_alpha, prompt_min_alpha, t)
	var k: float = 1.0 - exp(-prompt_track_speed * delta)
	_click_label.modulate.a = lerpf(_click_label.modulate.a, target, k)


# First interaction: fade the prompt out, request fullscreen, start the music,
# release the camera pan + time, then run the intro. The full sequence runs
# (preroll included): the camera begins panning on click and start_delay
# elapses with the world visible before the navy curtain starts fading in —
# matching the auto-run path.
func _begin_from_click() -> void:
	_awaiting_click = false

	# Stop proximity tracking so _process stops fighting the fade-out tween.
	_tracking_prompt = false
	var fade: Tween = create_tween()
	fade.tween_property(_click_label, "modulate:a", 0.0, 0.25) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	fade.tween_callback(_click_label.hide)

	# Resume time-of-day; the intro drives night→day from here.
	if _time_manager != null:
		_time_manager.paused = _was_time_paused

	_request_fullscreen()
	_start_music()

	# Release the opening camera pan held by Player during the gate.
	var player := get_tree().get_first_node_in_group(&"player")
	if player != null and player.has_method(&"start_opening_pan"):
		player.start_opening_pan()

	_run_intro()


func _request_fullscreen() -> void:
	var mode := DisplayServer.window_get_mode()
	if mode == DisplayServer.WINDOW_MODE_FULLSCREEN \
			or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)


# Web-only: music lives entirely in the page (no Godot autoload). The first
# click is the user gesture browsers require to start audio. start() is
# idempotent (see docs/music/paramo-music.js).
func _start_music() -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.ParamoMusic && window.ParamoMusic.start && window.ParamoMusic.start();")


# ----------------------------------------------------------------------------
# Skip handling
# ----------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	# Gate still pending (world generating): swallow everything, never begin.
	if _gate_pending:
		get_viewport().set_input_as_handled()
		return
	# Gate phase: swallow everything, begin on a discrete click / key / button.
	if _awaiting_click:
		get_viewport().set_input_as_handled()
		var is_begin: bool = (
			(event is InputEventMouseButton and event.pressed)
			or (event is InputEventKey and event.pressed and not event.echo)
			or (event is InputEventJoypadButton and event.pressed)
		)
		if is_begin:
			_begin_from_click()
		return

	if not _running:
		return
	# Swallow EVERY event while the intro is running — clicks, hover-targeting
	# of GUI Controls, key presses, joypad. Using _input (not _unhandled_input)
	# means we also block GUI dispatch, so gameplay Controls never see them.
	get_viewport().set_input_as_handled()
	if _skipped:
		return
	# Skip ONLY on Escape (or its joypad equivalent via ui_cancel). Every other
	# key, mouse click, and motion / axis event is intentionally
	# consumed-but-not-skip so the player can't blow past the title by mashing a
	# key or clicking the scene, and a bumped mouse can't skip either.
	var is_skip: bool = event.is_action_pressed(&"ui_cancel") and not event.echo
	if not is_skip:
		return

	_skipped = true
	# Gate further input AND invalidate any parked _run_intro await: bumping
	# the token means the original coroutine bails the moment it wakes
	# (timer.timeout fires regardless of node state — the token is what
	# makes the resume safe).
	_running = false
	_cancel_token += 1

	# Kill any in-flight tween. Note: kill() does NOT emit `finished`
	# (godot#84615), so the parked `await stage*.finished` in _run_intro
	# will never resume — that's fine because the token guard would catch
	# it anyway. Don't `await` skip_tween from this _input frame; spawn it
	# as its own coroutine so _input returns promptly.
	if _active_tween != null and _active_tween.is_valid():
		_active_tween.kill()
	_active_tween = null
	# Snap the opening camera pan to its rest target. The pan is owned by
	# Player (top_level camera, independent _process loop), so we ask it to
	# finish — no-op if the pan already completed.
	var player := get_tree().get_first_node_in_group(&"player")
	if player != null and player.has_method(&"finish_opening_pan_now"):
		player.finish_opening_pan_now()
	_run_skip_fade(_cancel_token)


func _run_skip_fade(token: int) -> void:
	var skip_tween: Tween = create_tween().set_parallel(true)
	skip_tween.tween_property(_curtain, "modulate:a", 0.0, skip_fade_duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	skip_tween.tween_property(_title, "modulate:a", 0.0, skip_fade_duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	await skip_tween.finished
	# Token guard: a second skip / re-entry shouldn't double-call _finish.
	if token != _cancel_token:
		return
	# Ensure we land on the daytime target even if the user skipped before
	# the curtain reached full opacity.
	if control_time_of_day and _time_manager != null and _time_manager.has_method("set_time"):
		_time_manager.set_time(day_time_of_day)
	# A skip kills the reveal tween, so its dry-weather reset may never have run.
	# Ensure gameplay starts dry regardless of when the player skipped.
	_reset_weather_dry()
	_finish()


# Clear rain shown over the pre-title lake shot so gameplay begins dry. Normal
# weather rolls resume from here. No-op on maps without a DayNight controller.
func _reset_weather_dry() -> void:
	var dnc := get_tree().get_first_node_in_group(&"day_night_controller")
	if dnc != null and dnc.has_method(&"reset_weather_dry"):
		dnc.reset_weather_dry()


func _finish() -> void:
	_running = false
	_animating = false
	set_process(false)
	_restore_gameplay_ux()
	queue_free()
