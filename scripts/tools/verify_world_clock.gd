extends SceneTree

## Proves the pause-freezes-the-world contract end to end, on the GPU:
##
##   1. LIVE  — the `world_time` global uniform actually reaches a shader at
##      runtime. It has to be checked on the GPU: `global_shader_parameter_get`
##      is editor-only (it errors and returns null in a running game), so there
##      is no CPU-side read-back to assert against.
##   2. FROZEN — `get_tree().paused = true` stops WorldClock advancing, so a
##      shader reading world_time renders the identical frame while paused.
##
## Needs a rendering context — do NOT pass --headless.
##
##   ... --script res://scripts/tools/verify_world_clock.gd
##
## Exit 0 = both hold. See dev-notes/vfx.md.

# Red channel IS world_time, so a pixel read-back is a read of the uniform.
const CODE := """
shader_type canvas_item;
global uniform float world_time;
void fragment() { COLOR = vec4(world_time, 0.0, 0.0, 1.0); }
"""

const PAUSED_FRAMES: int = 30

var _vp: SubViewport
var _clock: Node
var _step: int = 0
var _red_a: float = -1.0
var _red_b: float = -1.0
var _paused_seconds: float = -1.0
var _paused_red: float = -1.0
var _failures: int = 0


func _initialize() -> void:
	var sh := Shader.new()
	sh.code = CODE
	var mat := ShaderMaterial.new()
	mat.shader = sh
	var rect := ColorRect.new()
	rect.size = Vector2(4, 4)
	rect.material = mat
	_vp = SubViewport.new()
	_vp.size = Vector2i(4, 4)
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.transparent_bg = false
	_vp.add_child(rect)
	root.add_child(_vp)


func _process(_delta: float) -> bool:
	# Autoloads enter the tree after _initialize, so resolve on the first frame.
	if _clock == null:
		_clock = root.get_node_or_null(^"/root/WorldClock")
		if _clock == null:
			print("FAIL: no /root/WorldClock autoload")
			quit(1)
			return true

	_step += 1
	# One frame of slack after every write so the render target holds the value
	# that write produced, not the previous one.
	match _step:
		1:
			_clock.set_seconds(0.25)
		3:
			_red_a = _read_red()
			_clock.set_seconds(0.75)
		5:
			_red_b = _read_red()
			_check_live()
			# Freeze: the clock is pausable, so its _process stops here.
			paused = true
			_paused_seconds = _clock.seconds
			_paused_red = _read_red()
		5 + PAUSED_FRAMES:
			_check_frozen()
			paused = false
			print("world clock: %s" % ("OK" if _failures == 0 else "%d FAILURE(S)" % _failures))
			quit(1 if _failures > 0 else 0)
			return true
	return false


func _check_live() -> void:
	# Only the ordering is asserted: the render target is 8-bit and the value
	# goes through the canvas colour path, so the exact float does not survive.
	if _red_b > _red_a + 0.05:
		print("LIVE   ok   (world_time 0.25 -> %.3f, 0.75 -> %.3f)" % [_red_a, _red_b])
	else:
		print("LIVE   FAIL the shader did not track world_time (%.3f vs %.3f)" % [_red_a, _red_b])
		_failures += 1


func _check_frozen() -> void:
	var drift: float = absf(float(_clock.seconds) - _paused_seconds)
	var pixel_drift: float = absf(_read_red() - _paused_red)
	if drift <= 0.0 and pixel_drift <= 0.0:
		print("FROZEN ok   (%d paused frames, clock held at %.3f)" % [PAUSED_FRAMES, _paused_seconds])
		return
	print("FROZEN FAIL clock advanced %.4fs over %d paused frames (pixel drift %.4f)"
			% [drift, PAUSED_FRAMES, pixel_drift])
	_failures += 1


func _read_red() -> float:
	return _vp.get_texture().get_image().get_pixel(2, 2).r
