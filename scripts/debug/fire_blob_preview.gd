@tool
class_name FireBlobPreview
extends Node2D

# Debug-only node: spawns a row of FireBlobColumns at fixed intensities so
# fire_blobs.gdshader is visible in the editor without needing FireManager /
# Pathfinder / a real ignition. OPEN res://scenes/tools/fire_blob_test.tscn.
#
# TWO TUNING SURFACES, both live here (edit and the columns update this frame):
#   - LOOK params -> resources/materials/fire_blobs.tres, in the inspector:
#     the ramp colours, radial_bias, rise_curve, turb_freq_*, shape_evolve,
#     smoke_dither.
#   - INTENSITY-SCALED params -> scripts/vfx/fire_blob_tuning.gd constants:
#     rise speed (COLUMN_HEIGHT_* / LIFETIME_*), TURB_AMP_*, BLOB_*_RADIUS_*,
#     STRETCH_*, NOISE_*, RISE_SPEED_JITTER. These are MIN/MAX pairs (kindling ->
#     wildfire), so a single .tres uniform can't hold them — edit the .gd and
#     save; Godot recompiles and the columns pick it up.
#
# The live-ness is NOT automatic: each column holds a frozen .duplicate() of the
# material (it needs its own intensity uniforms), so an inspector edit would
# never reach it. _process re-syncs every column from the live sources each
# frame — see editor_refresh in fire_blob_column.gd.
#
# The row spans kindling -> wildfire left to right, which is the fastest way to
# check the two spec claims that are easy to get wrong:
#   - the leftmost column must be literally a couple of lit pixels;
#   - the rightmost must be a full plume that ends in char/smoke.
#
# Children are not assigned to the scene's `owner`, so they never get saved back
# into the .tscn — they're regenerated each time the script runs.
#
# Pair with the global `shader_debug` int (Project Settings > Shader Globals):
#   1 = stage index as grey (the rim index MUST exceed the core index)
#   2 = world-snap check (pan the camera; the grid must not swim)
#   3 = quad rect (nothing may clip at the edge)

const COLUMN_SCRIPT: GDScript = preload("res://scripts/vfx/fire_blob_column.gd")

## Columns to spawn, spread evenly across the intensity range.
@export_range(1, 12) var count: int = 5: set = _set_count
## Horizontal gap between columns, in px.
@export_range(8.0, 160.0) var spacing: float = 72.0: set = _set_spacing
## Intensity of the leftmost / rightmost column.
@export_range(0.0, 1.0) var intensity_from: float = 0.0: set = _set_from
@export_range(0.0, 1.0) var intensity_to: float = 1.0: set = _set_to
## Caps how hot blobs get: 1 = full ramp, 0.55 = burning down, 0.2 = smoke only.
## Drag to 0.2 to preview the smoulder tail without waiting for a burn.
@export_range(0.05, 1.0) var heat_ceiling: float = 1.0: set = _set_ceiling

## The intensity-scaled tuning (rise speed, turbulence, size, ...). Defaults to
## the ONE shared resource the game also reads, and the preview re-syncs from it
## live — so to tune, EDIT resources/fire_blob_tuning.tres DIRECTLY from the
## FileSystem dock (double-click -> inspector -> Save) and watch this scene update.
## Do NOT expand this export and drag the sliders here: Godot clones an @export
## resource default into the .tscn the instant you edit a sub-property, so the
## edits land in THIS scene, not the shared .tres, and the game never sees them
## (the preview still looks right, which is the trap). Point it at a different
## resource only to trial an alternative in isolation.
@export var tuning: FireBlobTuningData = preload("res://resources/fire_blob_tuning.tres"): set = _set_tuning


func _set_count(v: int) -> void:
	count = v
	_rebuild()


func _set_spacing(v: float) -> void:
	spacing = v
	_rebuild()


func _set_from(v: float) -> void:
	intensity_from = v
	_rebuild()


func _set_to(v: float) -> void:
	intensity_to = v
	_rebuild()


func _set_ceiling(v: float) -> void:
	heat_ceiling = v
	_rebuild()


func _set_tuning(v: FireBlobTuningData) -> void:
	tuning = v
	_rebuild()


func _ready() -> void:
	if not Engine.is_editor_hint():
		queue_free()
		return
	_rebuild()
	# Editor live-sync. Without this, editing fire_blobs.tres in the inspector
	# does nothing: each column holds a frozen .duplicate() of the material, and
	# _rebuild only fires on THIS node's export sliders. See _process.
	set_process(true)


# EDITOR ONLY (the node frees itself at runtime, so this never runs in game).
# Two per-frame jobs, both because a non-@tool FireBlobColumn is dormant in the
# editor:
#  1. editor_refresh — re-push the live tuning sources (the .tres, the shader,
#     FireBlobTuning) so inspector edits show immediately, the whole reason this
#     scene exists.
#  2. advance_phase — drive each column's blob-age clock. In game the column's own
#     _process does this; here that _process never runs, so WITHOUT this call the
#     fire is frozen. Cheap: <=12 columns.
func _process(delta: float) -> void:
	for c: Node in get_children():
		if c is FireBlobColumn:
			var col := c as FireBlobColumn
			col.editor_refresh(heat_ceiling)
			col.advance_phase(delta)


func _rebuild() -> void:
	if not is_inside_tree():
		return
	# Match by metadata so we never touch user-added siblings.
	for c: Node in get_children():
		if c.has_meta(&"_blob_preview"):
			c.queue_free()

	for i: int in count:
		var t: float = 0.0 if count == 1 else float(i) / float(count - 1)
		var col: FireBlobColumn = COLUMN_SCRIPT.new()
		col.set_meta(&"_blob_preview", true)
		col.tuning = tuning if tuning != null else FireBlobTuning.DATA
		col.position = Vector2((float(i) - float(count - 1) * 0.5) * spacing, 0.0)
		col.set_cell_seed(FireBlobColumn.seed_for_cell(Vector2i(i * 13, 7)))
		add_child(col)
		# Leave owner null so children stay runtime-only.
		# After add_child so _ready has built the material.
		col.set_intensity(lerpf(intensity_from, intensity_to, t))
		col.set_heat_ceiling(heat_ceiling)
