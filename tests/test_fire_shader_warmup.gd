extends GutTest

# Guards FireShaderWarmup, whose whole job is invisible: if it silently stops
# covering a shader, nothing breaks, nothing looks wrong, and the stutter it was
# written for comes back the next time someone walks up on a wildfire.
#
# The load-bearing test is _shaders_are_all_covered: it DISCOVERS which shaders
# the fire VFX draw by reading their sources, rather than restating the same list
# the warm-up already holds — a hand-copied list would agree with itself forever.

const WARMUP_SCRIPT: String = "res://scripts/vfx/fire_shader_warmup.gd"

# Everything that can put a fire shader on screen. A new one belongs here AND in
# FireShaderWarmup.WARM_SHADERS; the test below is what connects the two.
const FIRE_VFX_SOURCES: Array[String] = [
	"res://scripts/vfx/burning_cell_vfx.gd",
	"res://scripts/vfx/fire_blob_column.gd",
	"res://scripts/vfx/fire_aura_overlay.gd",
	"res://scripts/tools/frailejon.gd",
]

# Fire materials attached in a SCENE rather than by a script, which a source
# scan cannot see. fire_aura.tres hangs off the FireAuraRect in
# gameplay_base.tscn; scanning that scene instead would drag in every unrelated
# material on it (water, post-process, rain) and demand those be warmed too.
const FIRE_VFX_MATERIALS: Array[String] = [
	"res://resources/materials/fire_aura.tres",
]

# The one shader the fire VFX reference that the warm-up deliberately skips: the
# legacy sprite-flame path behind Debug.fire_blob_flames, which ships off. Kept
# here so the exclusion is asserted rather than assumed — if it ever becomes the
# shipped path, this line is what has to be deleted, and the test says so.
const DELIBERATELY_UNWARMED: Array[String] = [
	"res://assets/shaders/fire.gdshader",
]


func test_warm_shaders_all_exist() -> void:
	for path: String in FireShaderWarmup.WARM_SHADERS:
		assert_true(ResourceLoader.exists(path),
				"WARM_SHADERS points at a missing shader: %s" % path)


## Every shader reachable from the fire VFX is either warmed or explicitly
## excused. This is the test that fails when someone adds a fire shader.
func test_shaders_are_all_covered() -> void:
	var used: Array[String] = _shaders_the_fire_vfx_draw()
	assert_gt(used.size(), 0, "found no shaders at all — the scan is broken")

	for path: String in used:
		if DELIBERATELY_UNWARMED.has(path):
			continue
		assert_true(FireShaderWarmup.WARM_SHADERS.has(path),
				"%s is drawn by the fire VFX but is not warmed." % path
				+ " Add it to FireShaderWarmup.WARM_SHADERS and to the viewport"
				+ " it builds, or list it in DELIBERATELY_UNWARMED with a reason.")


## Nothing may sit in WARM_SHADERS that no fire VFX draws — a stale entry is a
## compile charged to every player for nothing.
func test_no_stale_warm_entries() -> void:
	var used: Array[String] = _shaders_the_fire_vfx_draw()
	for path: String in FireShaderWarmup.WARM_SHADERS:
		assert_true(used.has(path),
				"%s is warmed but nothing in the fire VFX draws it." % path)


## The warm-up feeds its viewport one item per frame, so this has to drain the
## queue before looking. Asserting on the viewport straight after _ready would
## see an empty one and pass or fail for the wrong reason.
func test_viewport_draws_every_warmed_shader() -> void:
	var warm := (load(WARMUP_SCRIPT) as GDScript).new() as Node
	add_child(warm)
	var vp: SubViewport = _viewport_of(warm)
	assert_not_null(vp, "the warm-up built no SubViewport, so it draws nothing")
	if vp == null:
		return

	var drawn_unlit: Array[String] = []
	var drawn_lit: Array[String] = []
	var budget: int = warm.call(&"frames_needed")
	for _i in budget:
		if not is_instance_valid(warm):
			break
		for item in vp.get_children():
			var path: String = _shader_path_of(item)
			if path.is_empty():
				continue
			var bucket: Array[String] = drawn_lit if _is_lit(item) else drawn_unlit
			if not bucket.has(path):
				bucket.append(path)
		await get_tree().process_frame

	# Both permutations, or the one that was skipped is paid on the reveal frame.
	for path: String in FireShaderWarmup.WARM_SHADERS:
		assert_true(drawn_unlit.has(path),
				"%s is in WARM_SHADERS but is never drawn UNLIT" % path)
		assert_true(drawn_lit.has(path),
				"%s is in WARM_SHADERS but is never drawn under the light" % path)


## Nothing may share a frame with anything else — that concentration is the bug
## the staggering exists to avoid, and it would regress silently.
func test_items_are_added_one_per_frame() -> void:
	var warm := (load(WARMUP_SCRIPT) as GDScript).new() as Node
	add_child(warm)
	var vp: SubViewport = _viewport_of(warm)
	assert_not_null(vp)
	if vp == null:
		return

	var prev: int = _drawable_count(vp)
	var budget: int = warm.call(&"frames_needed")
	for _i in budget:
		await get_tree().process_frame
		if not is_instance_valid(warm) or not is_instance_valid(vp):
			break
		var now: int = _drawable_count(vp)
		assert_lte(now - prev, 1,
				"%d shader items landed on one frame; the warm-up must add at most 1"
				% (now - prev))
		prev = now


## Canvas lighting is a separate shader permutation and every real fire draws
## under its own PointLight2D, so a warm-up without a light warms half of what
## the reveal frame needs.
func test_viewport_has_a_light() -> void:
	var warm := (load(WARMUP_SCRIPT) as GDScript).new() as Node
	add_child_autofree(warm)
	var vp: SubViewport = _viewport_of(warm)
	assert_not_null(vp)
	if vp == null:
		return
	var light: PointLight2D = null
	for item in vp.get_children():
		if item is PointLight2D and (item as PointLight2D).texture != null:
			light = item
	assert_not_null(light,
			"no PointLight2D with a texture — the lit permutation stays cold")
	if light == null:
		return
	# It must be present from the start, or the items that take an early turn
	# draw before it exists and land in the unlit bucket twice.
	assert_almost_eq(light.position.x, FireShaderWarmup.LIT_X, 0.01,
			"the light is not over the lit half")


## It must not linger. A SubViewport rendering every frame for the whole run
## would cost more than the stutter it removes.
func test_frees_itself() -> void:
	var warm := (load(WARMUP_SCRIPT) as GDScript).new() as Node
	add_child(warm)
	var budget: int = warm.call(&"frames_needed") + 2
	for _i in budget:
		await get_tree().process_frame
	assert_false(is_instance_valid(warm),
			"the warm-up is still alive after %d frames" % budget)


# ----------------------------------------------------------------------------

func _viewport_of(warm: Node) -> SubViewport:
	for child in warm.get_children():
		if child is SubViewport:
			return child
	return null


## The shader a canvas item draws with, or "" for anything else (the light).
func _shader_path_of(item: Node) -> String:
	var ci := item as CanvasItem
	if ci == null:
		return ""
	var mat := ci.material as ShaderMaterial
	if mat == null or mat.shader == null:
		return ""
	return mat.shader.resource_path


func _is_lit(item: Node) -> bool:
	var ci := item as CanvasItem
	if ci == null:
		return false
	# The aura is a Control positioned by its top-left; everything else is a
	# Node2D positioned by its centre. Compare the centre in both cases.
	var x: float = (ci as Node2D).position.x if ci is Node2D 			else (ci as Control).position.x + (ci as Control).size.x * 0.5
	return absf(x - FireShaderWarmup.LIT_X) < absf(x - FireShaderWarmup.UNLIT_X)


func _drawable_count(vp: SubViewport) -> int:
	var n: int = 0
	for item in vp.get_children():
		if not _shader_path_of(item).is_empty():
			n += 1
	return n


# ----------------------------------------------------------------------------

## Every shader the fire VFX can put on screen, from both discovery routes.
func _shaders_the_fire_vfx_draw() -> Array[String]:
	var out: Array[String] = []
	for src: String in FIRE_VFX_SOURCES:
		for path: String in _shaders_referenced_by(src):
			if not out.has(path):
				out.append(path)
	for mat_path: String in FIRE_VFX_MATERIALS:
		var mat := load(mat_path) as ShaderMaterial
		assert_not_null(mat, "%s is not a ShaderMaterial" % mat_path)
		if mat == null or mat.shader == null:
			continue
		var sp: String = mat.shader.resource_path
		if not sp.is_empty() and not out.has(sp):
			out.append(sp)
	return out


## Shader paths a source file names, whether directly (`res://….gdshader`) or
## through a material resource it preloads. Both matter: FireBlobColumn reaches
## fire_blobs.gdshader only via resources/materials/fire_blobs.tres, so a scan
## that only looked for .gdshader literals would call it uncovered.
func _shaders_referenced_by(source_path: String) -> Array[String]:
	var text: String = FileAccess.get_file_as_string(source_path)
	assert_gt(text.length(), 0, "could not read %s" % source_path)
	var out: Array[String] = []
	for path: String in _paths_in(text, ".gdshader"):
		if not out.has(path):
			out.append(path)
	for mat_path: String in _paths_in(text, ".tres"):
		var mat := load(mat_path) as ShaderMaterial
		if mat == null or mat.shader == null:
			continue
		var sp: String = mat.shader.resource_path
		if not sp.is_empty() and not out.has(sp):
			out.append(sp)
	return out


## Every "res://…<suffix>" literal in `text`. Deliberately crude — it reads
## quoted paths, so a comment mentioning a shader counts too. That errs toward
## warming something twice, never toward missing one.
func _paths_in(text: String, suffix: String) -> Array[String]:
	var out: Array[String] = []
	var from: int = 0
	while true:
		var start: int = text.find("res://", from)
		if start < 0:
			break
		var end: int = text.find(suffix, start)
		if end < 0:
			break
		var path: String = text.substr(start, end - start + suffix.length())
		# A quote between the two means these are different literals.
		if not path.contains("\"") and ResourceLoader.exists(path):
			out.append(path)
		from = start + 6
	return out
