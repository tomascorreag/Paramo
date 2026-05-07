# Code Review — 2026-05-06

## Files Reviewed
- `scripts/ui/title_intro.gd` (new)
- `scenes/ui/title_intro.tscn` (new)
- `scripts/player.gd` (diff in `_snap_to_starting_cell`)
- `scenes/templates/gameplay_base.tscn` (format change + TitleIntro instance)

## Summary
- Critical: 1
- Warnings: 9
- Info: 4

---

## Critical Issues

### [C1] Skip path leaks a parked coroutine and double-runs the sequence
- **File:** `scripts/ui/title_intro.gd:368-405` interacting with `:297-361`
- **Description:** `_active_tween.kill()` does NOT emit `finished` in Godot 4 (confirmed open issue godotengine/godot#84615 and 4.x forum thread). Effects:
  - Skip during `start_delay` or `static_hold`: those use `create_timer().timeout`, which is not the tracked `_active_tween` and is unaffected by `kill()`. The original timer fires after `_finish()` already ran, the awaited coroutine resumes on a queue-freed node, may pass `if _skipped: return` only to set `_animating=true` and queue Stage 6 on a freed node.
  - Skip during a tracked tween: `await stage*.finished` parks forever; the parked frame is released only when the node is freed in `_finish()`. During the ~150 ms skip-fade window two state machines are alive.
- **Suggested Fix:** Cancel-token guard on every awaited stage; never rely on tween finished for cancellation.
```gdscript
var _cancel_token: int = 0

func _input(event: InputEvent) -> void:
    if not _running:
        return
    get_viewport().set_input_as_handled()
    if _skipped:
        return
    var is_skip := (
        (event is InputEventKey and event.pressed and not event.echo)
        or (event is InputEventMouseButton and event.pressed)
        or (event is InputEventJoypadButton and event.pressed)
    )
    if not is_skip:
        return
    _skipped = true
    _running = false
    _cancel_token += 1
    if _active_tween != null and _active_tween.is_valid():
        _active_tween.kill()
    _active_tween = null
    _start_skip_fade(_cancel_token)

# In _run_intro, capture the token at entry and bail if it changes after any await.
```

---

## Warnings

### [W1] `_pan_duration` fallback (14.0) does not match TitleIntro defaults (15.25)
- **File:** `scripts/player.gd:554-555`
- **Description:** Defaults sum to 11.25 s + 4.0 s pan_additional = 15.25 s. Player falls back to 14.0 s when the group is empty, so the camera lands 1.25 s before the intro would have ended. Two sources of truth that drift.
- **Suggested Fix:** Drop the fallback. TitleIntro is now part of `gameplay_base.tscn`, so all gameplay-derived scenes get it. If it is absent (e.g. test scene with `play_intro=false` and the deferred free already ran), skip the opening pan entirely and `push_warning`.

### [W2] One-frame day/night flash window in `_ready`
- **File:** `scripts/ui/title_intro.gd:165-184`
- **Description:** Strategy depends on `TitleIntro._ready` running before `DayNightController._ready`, but in `gameplay_base.tscn` `DayNightController` is declared first (sibling document order), so its `_ready` fires earlier. Currently lucky — `DayNightController` does its first sample in `_process`, by which time `TimeManager.set_time(night_time_of_day)` has already executed. Fragile; one ordering change breaks it.
- **Suggested Fix:** Have `DayNightController` connect to `TimeManager.time_changed` and grade on signal (event-driven, not poll-based). OR set the initial time in TimeManager itself (autoloads run before the scene tree). OR drive the time set from the level scene's `_ready` rather than the UI overlay.

### [W3] UX gating restore is asymmetric for `process_mode`
- **File:** `scripts/ui/title_intro.gd:236, 243`
- **Description:** `_register_gated` snapshots `visible` but force-sets `process_mode = INHERIT` on restore. If a UX node was authored with `PROCESS_MODE_ALWAYS` (e.g. needs to keep updating during pause), gating then ungating silently downgrades it.
- **Suggested Fix:** Add `_gated_process_mode: Dictionary[Node, int]`, snapshot the original value in `_register_gated`, restore it in `_restore_gameplay_ux`.

### [W4] `_advance_frame` last-frame display walked through
- **File:** `scripts/ui/title_intro.gd:268-282`
- **Description:** Verified: frame `frame_count - 1` displays for exactly one `frame_time` tick before jumping to `loop_start_frame`. Correct, not a bug. Note: artist cannot author "linger on last frame before loop" without this code change.
- **Suggested Fix:** None required. Document if the artist asks for a tail-hold beat.

### [W5] Hardcoded 6-stage sequence — limited scaling path
- **File:** `scripts/ui/title_intro.gd:297-361`
- **Description:** Adding a new cinematic (per-season intro, end-card, level stinger) means editing `_run_intro`, `get_total_intro_duration`, and consumers that read pan duration. `get_total_intro_duration` math can drift from the actual sequence body silently.
- **Suggested Fix:** Option B (low cost): extract each stage into a named method `_stage_*` with a paired `_stage_*_duration()`; `get_total_intro_duration` becomes a sum of those. Same imperative shape, no DSL invented, but the duration calc lives next to the stage. Defer Resource-driven stage interpreter (Option A) until a second cinematic actually appears.

### [W6] `_input` blocks all GUI for the intro duration
- **File:** `scripts/ui/title_intro.gd:368-374`
- **Description:** `_input` (vs `_unhandled_input`) blocks GUI control hover/click dispatch. Confirmed intentional per the docstring. ALT+F4 / editor stop are not affected. Per-frame `set_input_as_handled` for mouse motion is trivial cost.
- **Suggested Fix:** None.

### [W7] `"pan_offset_px" in intro` and `has_method("get_pan_duration")` are redundant
- **File:** `scripts/player.gd:558, 560`
- **Description:** The `in` operator on a Node checks properties (incl. `@export` vars from script). Since the only thing in group `&"title_intro"` is a `TitleIntro` instance, both guards are dead code.
- **Suggested Fix:** Cast statically: `var intro := get_tree().get_first_node_in_group(&"title_intro") as TitleIntro`. If null, skip pan and warn.

### [W8] Coupling: gameplay node reads UI node via duck-typed group lookup
- **File:** `scripts/player.gd:556-561`
- **Description:** Dependency direction is wrong (gameplay -> UI). Three options:
  - **Group + typed cast** (recommended for vertical-slice scope): low ceremony, fine while there is one consumer.
  - **Resource-driven** (`OpeningPanConfig.tres` shared by both nodes): correct dependency direction; do this when a second consumer (HUD fade, ambient duck) appears.
  - **Signal-driven**: rejected — `Player._ready` may fire before `TitleIntro._ready` and miss the emit.
- **Suggested Fix:** Apply the typed-cast variant now; revisit Resource extraction when a second consumer appears.

### [W9] `play_intro=false` works only by load-bearing on Godot's deferred ordering
- **File:** `scripts/ui/title_intro.gd:165-178`
- **Description:** `add_to_group` runs synchronously, then `call_deferred("queue_free")` queues deletion. Player's `_snap_to_starting_cell` is also deferred and reads the group before the actual delete pass. Works today but breaks if `_snap_to_starting_cell` ever migrates to a `process_frame`-style hook.
- **Suggested Fix:** Add a comment in `_snap_to_starting_cell` referencing the deferred-ordering contract, or push pan params from TitleIntro into Player rather than letting Player pull.

---

## Info

### [I1] `_process` keeps running when `_animating == false`
- **File:** `scripts/ui/title_intro.gd:255-257`
- **Description:** Trivial cost (one bool branch per frame). For cleanliness, `set_process(false)` after the one-shot+tail loop ends or in the early-return path.
- **Suggested Fix:** Disable `_process` in the early-return branch; toggle it on at Stage 4 and off at `_finish`.

### [I2] Scene format change is correct, not corruption
- **File:** `scenes/templates/gameplay_base.tscn:1`
- **Description:** `format=3` with `unique_id=` per node is the Godot 4.6 native format introduced by PR godotengine/godot#106837 (merged Oct 2025). `load_steps` is now optional/ignored. The earlier `format=4` was a transient pre-stable value.
- **Suggested Fix:** None.

### [I3] AtlasTexture region mutation is the right perf pattern
- **File:** `scripts/ui/title_intro.gd:268-290`
- **Description:** Region mutation rebuilds quad UVs at draw time, no GPU upload. Beats Texture2D swapping which would invalidate `TextureRect` cached layout state.
- **Suggested Fix:** None.

### [I4] `_gated_visible` keyed by Node identity
- **File:** `scripts/ui/title_intro.gd:162, 234`
- **Description:** Identity-keyed dict; if a tracked node is freed mid-intro and a new node spawns with the same name, the dict holds a stale entry that is filtered out by `is_instance_valid` on restore. Correct but worth a one-line comment if kept.
- **Suggested Fix:** Optional comment.

---

## What's Done Well
- `_finish_opening_pan` ordering (enable smoothing → `reset_smoothing` → drop `top_level`) is the correct sequence.
- Camera pan continues during skipped intro — right call.
- `_camera_pan_target_world` chases the moving player.
- `add_to_group` before any early-return — group contract upheld even for `play_intro=false`.
- Layer = 200 set in code AND scene — defensive.
- AtlasTexture region mutation — documented, correct.
