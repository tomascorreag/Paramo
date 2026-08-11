extends GutTest

# Guards the "pause freezes the world, visually too" contract:
# WorldClock (scripts/systems/world_clock.gd) drives the `world_time` global
# shader uniform and is pausable, and every world shader animates off that
# uniform instead of the TIME built-in — TIME keeps running under
# get_tree().paused, which is exactly the bug this replaced.

const WorldClockScript: GDScript = preload("res://scripts/systems/world_clock.gd")

# The shaders that draw the world. A world shader that animates must read
# `world_time`; UI/post shaders are out of scope (none use TIME today, but a
# menu effect legitimately could).
const WORLD_SHADERS: Array[String] = [
	"res://assets/shaders/rain.gdshader",
	"res://assets/shaders/water.gdshader",
	"res://assets/shaders/wind.gdshader",
	"res://assets/shaders/fire.gdshader",
	"res://assets/shaders/fire_blobs.gdshader",
]

var clock: Node


func before_each() -> void:
	clock = WorldClockScript.new()
	add_child_autofree(clock)


# ===========================================================================
# The clock itself
# ===========================================================================

func test_advance_accumulates() -> void:
	clock.seconds = 0.0
	clock.advance(0.25)
	clock.advance(0.25)
	assert_almost_eq(clock.seconds, 0.5, 0.0001)


func test_advance_wraps_at_rollover() -> void:
	# Mirrors the engine's own TIME rollover so shader magnitudes are unchanged.
	clock.set_seconds(WorldClockScript.ROLLOVER_SECS - 0.5)
	clock.advance(1.0)
	assert_almost_eq(clock.seconds, 0.5, 0.0001)


# There is no CPU-side read-back to assert against: RenderingServer's
# global_shader_parameter_get is editor-only and returns null in a running game.
# That the uniform reaches the GPU — and holds while paused — is proved on the
# GPU by scripts/tools/verify_world_clock.gd. This only pins the clock's own API.
func test_set_seconds_clamps_and_wraps() -> void:
	clock.set_seconds(-5.0)
	assert_eq(clock.seconds, 0.0)
	clock.set_seconds(WorldClockScript.ROLLOVER_SECS + 2.0)
	assert_almost_eq(clock.seconds, 2.0, 0.0001)


# ===========================================================================
# Pausability — the whole point
# ===========================================================================

func test_clock_is_pausable() -> void:
	# INHERIT under a pausable root: get_tree().paused stops _process, so
	# world_time holds and every world shader freezes on that frame.
	assert_eq(clock.process_mode, Node.PROCESS_MODE_INHERIT)


func test_clock_stops_processing_while_paused() -> void:
	var was: bool = get_tree().paused
	get_tree().paused = true
	var can: bool = clock.can_process()
	get_tree().paused = was
	assert_false(can, "WorldClock must not process while the tree is paused")


func test_autoload_is_registered() -> void:
	# The game's instance, not the one this test spawns.
	assert_not_null(get_node_or_null(^"/root/WorldClock"),
			"WorldClock must be an autoload — nothing else writes world_time")


# ===========================================================================
# Shaders
# ===========================================================================

func test_world_shaders_use_the_clock_not_time() -> void:
	for path: String in WORLD_SHADERS:
		var src: String = _code_of(path)
		assert_true(src.contains("global uniform float world_time;"),
				"%s must declare the world_time global uniform" % path)
		assert_false(_uses_time_builtin(src),
				"%s uses the TIME built-in; it does not stop under pause — use world_time" % path)


func test_world_time_is_declared_in_project_settings() -> void:
	# Global uniforms must exist in project.godot [shader_globals] or the shaders
	# fail to resolve them in the editor.
	assert_true(ProjectSettings.has_setting("shader_globals/world_time"))


# Shader source with `//` comments stripped — every file here *talks* about TIME
# in its header, so a raw substring search would always trip.
func _code_of(path: String) -> String:
	var shader: Shader = load(path) as Shader
	assert_not_null(shader, "could not load %s" % path)
	var out: String = ""
	for line: String in shader.code.split("\n"):
		var c: int = line.find("//")
		out += (line if c < 0 else line.substr(0, c)) + "\n"
	return out


# TIME as a whole word: `world_time` and `lifetime` must not match.
func _uses_time_builtin(src: String) -> bool:
	var re := RegEx.create_from_string("\\bTIME\\b")
	return re.search(src) != null
