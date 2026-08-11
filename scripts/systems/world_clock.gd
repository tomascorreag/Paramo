extends Node
## Autoload registered as "WorldClock" in project.godot.
## Cannot use class_name — Godot disallows class_name matching an autoload name.

## The world's shader clock, and the only writer of the `world_time` global
## shader uniform (declared in project.godot [shader_globals]).
##
## WHY IT EXISTS. `get_tree().paused` freezes every pausable node, so the sim,
## the visitors, the fire dynamics and the day/night tint all stop when the pause
## menu or the journal opens. The shader built-in `TIME` does not: it is engine
## uptime, driven by the rendering server, and it keeps advancing through a
## paused tree. So rain kept falling, water kept flowing, grass kept swaying and
## flames kept licking behind the pause menu — the world looked live while it was
## frozen. Every world shader that animated off `TIME` now reads `world_time`
## instead, and this node's `_process` is what advances it.
##
## HOW THE FREEZE HAPPENS. This node keeps the DEFAULT process mode (INHERIT ->
## pausable), so `get_tree().paused = true` stops its `_process`, `world_time`
## stops moving, and every shader reading it holds the exact frame the pause
## started on. Nothing else has to know about pausing — no per-material bookkeeping,
## no walking the scene. Unpausing resumes from the held value, so nothing jumps.
##
## Deliberately NOT `Engine.time_scale = 0`, the other way to stop shader time:
## that also zeroes the delta of everything running with PROCESS_MODE_ALWAYS, so
## the pause menu's and the journal's own open/close tweens would stall at the
## first frame unless each one opted out with `set_ignore_time_scale(true)`.
##
## Editor caveat: autoloads do not run in the editor, so `world_time` sits at its
## project-settings default there and water/wind/fire render a static frame in the
## editor viewport. Play the scene (or use the preview tools in dev-notes/vfx.md,
## which run the game) to see them animate.

## The global shader uniform this node drives. Shaders declare it as
## `global uniform float world_time;`.
const PARAM: StringName = &"world_time"

## Wrap point, in seconds. Mirrors the engine's own
## `rendering/limits/time/time_rollover_secs` (default 3600), which exists so
## `TIME` never grows large enough to lose float precision in noise lookups. Same
## wrap here, so a shader sees the same magnitudes it always did — including the
## same once-an-hour discontinuity, which the old TIME had too.
const ROLLOVER_SECS: float = 3600.0

## Seconds of unpaused world time since launch, mod ROLLOVER_SECS. Read it if you
## need the value a shader is currently seeing; write it only from tools.
var seconds: float = 0.0


func _ready() -> void:
	# Push once before the first frame so nothing renders against a stale value
	# left by a previous scene (autoloads survive reload_current_scene).
	_push()


func _process(delta: float) -> void:
	seconds = fmod(seconds + delta, ROLLOVER_SECS)
	_push()


## Advance by a fixed step. For tools and tests that drive the clock themselves
## (e.g. rendering a deterministic still); the game never calls it.
func advance(delta: float) -> void:
	seconds = fmod(seconds + delta, ROLLOVER_SECS)
	_push()


## Jump to an absolute time. Used by the equivalence/benchmark tools, which need
## two shaders to see the identical clock value.
func set_seconds(t: float) -> void:
	seconds = fmod(maxf(t, 0.0), ROLLOVER_SECS)
	_push()


func _push() -> void:
	RenderingServer.global_shader_parameter_set(PARAM, seconds)
