class_name FireAuraOverlay
extends ColorRect

# Screen-edge fire aura. A fullscreen ColorRect running fire_aura.gdshader that
# glows warm at the border in the direction of any OFF-SCREEN fire. Sits on a
# root CanvasLayer above post-process (see gameplay_base.tscn / UILayers.FIRE_AURA).
#
# This node is the CPU half of the effect: every frame it projects each live
# fire (from a tree-change-cached list) into screen space and bakes an angular
# WEIGHT STRIP the shader samples by bearing. The shader itself knows nothing about fires (see
# fire_aura.gdshader) — all the "which fires, where, how strong" logic is here.
#
# The weight of a single fire is  intensity × rise × far:
#   intensity  the fire's own 0..1 heat (BurningCellVFX.get_intensity) — the
#              "size/intensity of the fire" half of the brief.
#   rise       0 while the fire sits comfortably INSIDE the frame, ramping to 1
#              as it crosses the edge. This is the fade: walk a fire on-screen and
#              its aura fades out; let it drift off and the aura fades back in.
#   far        1 just off the edge, decaying to 0 far off-screen — proximity.
# Overlapping fires simply sum in the strip, so a cluster off one edge glows
# brighter and deeper than a lone fire with no extra bookkeeping and no cap.
#
# A temporal lerp on the strip (SMOOTH_TAU) smooths the geometric fade so nothing
# pops when a fire ignites, is extinguished, or the camera snaps.

# The fire VFX group BurningCellVFX joins — covers both live and smouldering
# fires (both expose get_intensity + a world global_position). Kept as a literal
# rather than BurningCellVFX.FIRE_VFX_GROUP on purpose: the overlay only needs the
# group name and a duck-typed get_intensity(), so it stays decoupled from the
# heavy VFX class (and its Debug-autoload dependency). MUST match
# BurningCellVFX.FIRE_VFX_GROUP.
const FIRE_VFX_GROUP: StringName = &"fire_vfx"

# Angular resolution of the weight strip. 96 texels over 360° ≈ 3.75°/texel —
# finer than the eye resolves a soft edge glow, and the shader samples it linearly.
const BINS: int = 96

# --- Presence / proximity shaping (all in normalized 0..1 screen units) -------
# How far INSIDE the frame (as a fraction of screen size) a fire's aura has fully
# faded to nothing. Larger => the aura lingers further after the fire is on-screen.
const FADE_IN: float = 0.18
# Signed distance just past the edge where proximity is still full before it
# starts decaying. Keeps the glow solid right at the border.
const EDGE_HOLD: float = 0.03
# Signed distance off-screen where proximity has decayed to 0 — a fire further
# than REACH screens away contributes nothing.
const REACH: float = 0.9

# --- Angular spread of one fire's bump ----------------------------------------
# Base half-width (std-dev) of the Gaussian a fire deposits, in radians (~17°).
const SIGMA_BASE: float = 0.30
# Extra spread per unit weight: a big/near fire fans its glow wider along the edge.
const SIGMA_GAIN: float = 0.30

# Temporal smoothing time-constant (seconds) for the strip. The aura reaches ~63%
# of a change in this long — short enough to feel responsive, long enough to hide
# per-frame jitter and ignition/extinguish pops.
const SMOOTH_TAU: float = 0.16

# Ignore fires below this heat (the tail end of a douse / a barely-lit kindling) —
# they'd contribute an imperceptible glow at real per-frame cost.
const MIN_INTENSITY: float = 0.02

# Below this peak strip value the aura is invisible; hide the rect so the
# fullscreen pass costs nothing while no fire is off-screen.
const HIDE_BELOW: float = 0.0025

# Target (this frame) and smoothed (displayed) weight per angular bin.
var _target: PackedFloat32Array
var _smoothed: PackedFloat32Array
var _img: Image
var _tex: ImageTexture
var _mat: ShaderMaterial

# Cached fire_vfx member list, refreshed lazily after any tree change so the
# per-frame path doesn't allocate a fresh Array via get_nodes_in_group
# (mirrors day_night_scene_controller's shadow-list dirty flag).
var _fires: Array[Node] = []
var _fires_dirty: bool = true

# Viewport size / aspect and the DisplayManager autoload (absent in the preview
# tool's bare viewport), cached so aspect/texel are pushed on change, not per frame.
var _vp: Vector2 = Vector2.ZERO
var _aspect: float = 1.0
var _dm: Node = null


func _ready() -> void:
	# Own a private material so the per-frame aura_tex we bind doesn't leak onto
	# other instances sharing the .tres (mirrors FireBlobColumn duplicating its mat).
	_mat = (material as ShaderMaterial).duplicate() as ShaderMaterial
	material = _mat

	_target = PackedFloat32Array()
	_target.resize(BINS)
	_smoothed = PackedFloat32Array()
	_smoothed.resize(BINS)

	_img = Image.create(BINS, 1, false, Image.FORMAT_RF)
	_tex = ImageTexture.create_from_image(_img)
	_mat.set_shader_parameter(&"aura_tex", _tex)

	# These fire for EVERY node, but the handler is a single bool write.
	# Deliberately NOT filtered on group membership: BurningCellVFX joins
	# fire_vfx in its own _ready, which runs AFTER node_added is emitted, so a
	# membership filter here would miss every real fire. The refresh happens on
	# the next _process, after the whole add_child call stack has completed.
	var tree: SceneTree = get_tree()
	tree.node_added.connect(_on_scene_tree_changed)
	tree.node_removed.connect(_on_scene_tree_changed)

	get_viewport().size_changed.connect(_update_screen_params)
	_dm = get_node_or_null(^"/root/DisplayManager")
	if _dm != null:
		_dm.scale_changed.connect(_on_scale_changed)
	_update_screen_params()

	# Start hidden — nothing is burning at spawn, and a hidden rect skips the fill.
	visible = false


func _on_scene_tree_changed(_n: Node) -> void:
	_fires_dirty = true


func _on_scale_changed(_new_scale: int) -> void:
	_update_screen_params()


# Push the uniforms that depend only on viewport size and integer scale. Called
# on size/scale change instead of every frame.
func _update_screen_params() -> void:
	_vp = get_viewport_rect().size
	if _vp.x <= 0.0 or _vp.y <= 0.0:
		return
	_aspect = _vp.x / _vp.y
	_mat.set_shader_parameter(&"aspect", _aspect)

	# Feed the shader the low-res texel size so it snaps its glow to the same grid
	# as the pixel-art world. This rect draws at full monitor res (root layer,
	# above post-process), so N window pixels == one logical texel; texel in the
	# rect's 0..1 UV is therefore N / window. Fall back to no snap (1px) when the
	# DisplayManager autoload is absent (e.g. the preview tool's bare viewport).
	var scale_n: int = 1
	if _dm != null:
		scale_n = maxi(1, int(_dm.current_scale))
	_mat.set_shader_parameter(&"texel", Vector2(scale_n, scale_n) / _vp)


## Seconds between strip rebuilds. The whole update — bearing bake, smoothing,
## 96 set_pixel calls and a texture upload — used to run every frame and
## measured 164 us at the 80-fire cap, the second largest per-frame script cost
## in the game and all of it in ONE node.
##
## 20 Hz because of what this draws: a soft, heavily smoothed edge glow whose
## own SMOOTH_TAU already lags it far more than 50 ms. The one thing that could
## show is bearing lag while the camera pans fast, and at 50 ms that is a
## fraction of a texel on a 96-bin strip.
##
## The smoothing stays frame-rate independent for free — it is exp(-dt/TAU), so
## handing it the accumulated delta at 20 Hz traces the same curve it traced at
## 60.
const UPDATE_INTERVAL: float = 1.0 / 20.0


func _process(delta: float) -> void:
	if _fires_dirty:
		_fires_dirty = false
		_fires = get_tree().get_nodes_in_group(FIRE_VFX_GROUP)

	# Fully idle path: nothing in the group and the glow already decayed below
	# HIDE_BELOW (visible only goes false after that decay completes), so the
	# target is zero and the smoothed strip is ~zero — nothing to rebuild,
	# smooth, or upload. Checked EVERY frame, unlike the work below: it is two
	# comparisons, and it is what makes a map with no fire on it free.
	if _fires.is_empty() and not visible:
		return

	_since_update += delta
	if _since_update < UPDATE_INTERVAL:
		return
	delta = _since_update
	_since_update = 0.0

	_build_target()

	# Exponential smoothing toward this frame's target. a = 1 at long delta, small
	# at short delta — frame-rate independent, unlike a fixed lerp weight.
	var a: float = 1.0 - exp(-delta / SMOOTH_TAU)
	var peak: float = 0.0
	for b: int in BINS:
		var s: float = lerpf(_smoothed[b], _target[b], a)
		_smoothed[b] = s
		if s > peak:
			peak = s

	if peak < HIDE_BELOW:
		# Fully faded and nothing off-screen — stop drawing entirely.
		visible = false
		return

	visible = true
	for b: int in BINS:
		_img.set_pixel(b, 0, Color(_smoothed[b], 0.0, 0.0, 1.0))
	_tex.update(_img)


# Rebuild _target from the current off-screen fires. Leaves _target zeroed when
# nothing qualifies, so the smoothing above fades any lingering glow out.
var _since_update: float = 0.0


func _build_target() -> void:
	for b: int in BINS:
		_target[b] = 0.0

	if _fires.is_empty():
		return
	if _vp.x <= 0.0 or _vp.y <= 0.0:
		return
	# World -> screen-pixel transform for the current Camera2D. Works regardless of
	# WHICH camera is current — we never touch a camera node.
	var cam: Transform2D = get_viewport().get_canvas_transform()

	for node: Node in _fires:
		# queue_free()d nodes leave the tree at frame end, emitting node_removed
		# before the next _process refreshes the cache, so a stale entry can't
		# normally be hit — this guards a same-frame free() only.
		if not is_instance_valid(node):
			continue
		if not (node is Node2D) or not node.has_method(&"get_intensity"):
			continue
		var vfx := node as Node2D
		var intensity: float = float(vfx.call(&"get_intensity"))
		if intensity <= MIN_INTENSITY:
			continue

		# Fire position in normalized screen space (0..1 on-screen, outside = off).
		var uv: Vector2 = (cam * vfx.global_position) / _vp

		# Signed distance to the screen rect: negative inside (dist to nearest
		# edge), positive outside (euclidean overshoot, incl. corners).
		var inside_dist: float = minf(minf(uv.x, 1.0 - uv.x), minf(uv.y, 1.0 - uv.y))
		var dx: float = maxf(maxf(-uv.x, uv.x - 1.0), 0.0)
		var dy: float = maxf(maxf(-uv.y, uv.y - 1.0), 0.0)
		var outside: float = sqrt(dx * dx + dy * dy)
		var sd: float = outside if outside > 0.0 else -inside_dist

		# rise: fade in as the fire leaves the frame. far: proximity decay off-screen.
		var rise: float = smoothstep(-FADE_IN, 0.0, sd)
		var far: float = 1.0 - smoothstep(EDGE_HOLD, REACH, sd)
		var w: float = intensity * rise * far
		if w <= 0.0001:
			continue

		# Aspect-corrected bearing — must match the shader's fragment bearing.
		var dc: Vector2 = Vector2((uv.x - 0.5) * _aspect, uv.y - 0.5)
		_deposit(atan2(dc.y, dc.x), w)


# Add a Gaussian bump of total weight `w` centred on bearing `ang` into _target,
# wrapping across the ±PI seam. Only bins within 3σ are touched.
func _deposit(ang: float, w: float) -> void:
	var sigma: float = SIGMA_BASE + SIGMA_GAIN * clampf(w, 0.0, 1.0)
	var bin_width: float = TAU / float(BINS)
	var center: int = int(round((ang / TAU + 0.5) * float(BINS)))
	var span: int = int(ceil(3.0 * sigma / bin_width))
	for off: int in range(-span, span + 1):
		var da: float = float(off) * bin_width           # angular offset from centre
		var g: float = exp(-0.5 * (da / sigma) * (da / sigma))
		var bi: int = posmod(center + off, BINS)          # wrap the seam
		_target[bi] += w * g
