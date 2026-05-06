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
# Skippable: any input fast-forwards to a quick fade-out and frees the node.
# The camera pan is intentionally NOT skipped — only the title card.
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
@export var curtain_fade_in: float = 1.0
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
	# This layer must draw above post-process (layer 100). Set in code as
	# well as the scene so refactors of the scene file can't quietly break it.
	layer = 200

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


func _register_gated(node: Node) -> void:
	if node == null or _gated_nodes.has(node):
		return
	_gated_nodes.append(node)
	if node is CanvasItem:
		_gated_visible[node] = (node as CanvasItem).visible
		(node as CanvasItem).visible = false
	# Snapshot process_mode so a node authored with PROCESS_MODE_ALWAYS isn't
	# silently downgraded to INHERIT on restore.
	_gated_process_mode[node] = node.process_mode
	node.process_mode = Node.PROCESS_MODE_DISABLED


func _restore_gameplay_ux() -> void:
	for n: Node in _gated_nodes:
		if not is_instance_valid(n):
			continue
		if _gated_process_mode.has(n):
			n.process_mode = _gated_process_mode[n]
		if n is CanvasItem and _gated_visible.has(n):
			(n as CanvasItem).visible = _gated_visible[n]
	_gated_nodes.clear()
	_gated_visible.clear()
	_gated_process_mode.clear()


# ----------------------------------------------------------------------------
# Per-frame: drives the title animation. Independent of tweens — keeps
# ticking through the post-anim hold AND through the fade-out.
# ----------------------------------------------------------------------------

func _process(delta: float) -> void:
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
	if control_time_of_day and _time_manager != null and _time_manager.has_method("set_time"):
		_time_manager.set_time(day_time_of_day)
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
# Skip handling
# ----------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not _running:
		return
	# Swallow EVERY event while the intro is running — clicks, hover-targeting
	# of GUI Controls, key presses, joypad. Using _input (not _unhandled_input)
	# means we also block GUI dispatch, so gameplay Controls never see them.
	get_viewport().set_input_as_handled()
	if _skipped:
		return
	# Skip on any discrete press. Motion / axis events are intentionally
	# consumed-but-not-skip so the player doesn't blow past the title from
	# bumping the mouse while picking up the controller.
	var is_skip: bool = (
		(event is InputEventKey and event.pressed and not event.echo)
		or (event is InputEventMouseButton and event.pressed)
		or (event is InputEventJoypadButton and event.pressed)
	)
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
	_finish()


func _finish() -> void:
	_running = false
	_animating = false
	set_process(false)
	_restore_gameplay_ux()
	queue_free()
