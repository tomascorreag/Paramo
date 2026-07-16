class_name FireBlobTuningData
extends Resource

# The intensity-scaled tuning for the procedural blob fire, as an inspector-
# editable resource (resources/fire_blob_tuning.tres). FireBlobTuning reads these
# via its shared DATA preload, so BOTH the game and the editor preview
# (scenes/tools/fire_blob_test.tscn) use the same values — edit the .tres and the
# preview updates live, and the game ships whatever it holds.
#
# WHY A RESOURCE AND NOT fire_blobs.tres: every field here is a MIN/MAX PAIR,
# lerped kindling (intensity 0) -> wildfire (intensity 1). A shader material
# uniform is a single value and cannot hold a pair, so these cannot live on the
# material. They also drive the quad bound (FireBlobTuning.quad_size), which is
# the shader's only spatial limit — get them wrong and blobs clip silently, which
# is why the tuning math (and its tests) sit in code and only the VALUES live
# here.
#
# Look params (colours, radial_bias, rise_curve, turb_freq_*, shape_evolve,
# smoke_dither) are NOT here — they are constant across the fire's life and go on
# the material, resources/materials/fire_blobs.tres.

@export_group("Rise", "column_height_")
## Column height at kindling / wildfire, in px. RISE SPEED is height / lifetime —
## there is no separate speed field. Raise these (or lower lifetime) for faster,
## taller fire. Biggest fill-cost lever: quad area is linear in the max.
@export_range(4.0, 320.0) var column_height_min: float = 24.0
@export_range(4.0, 320.0) var column_height_max: float = 200.0

@export_group("Lifetime", "lifetime_")
## How long a blob lives, kindling / wildfire, in seconds. Longer = slower rise
## (speed = height / lifetime) and a longer smoke tail.
@export_range(0.2, 8.0) var lifetime_min: float = 0.5
@export_range(0.2, 8.0) var lifetime_max: float = 2.2

@export_group("Turbulence", "turb_amp_")
## How far blobs wander sideways, kindling / wildfire, in px. (How FAST they
## wiggle is turb_freq on the material.)
@export_range(0.0, 24.0) var turb_amp_min: float = 0.5
@export_range(0.0, 24.0) var turb_amp_max: float = 8.0
## Per-blob rise-speed spread: each blob rises at 1 +/- this, fixed for its life.
## 0 = lockstep (mechanical); 0.3 = a natural spread. Raising it makes the quad
## taller (bound-relevant) and costs fill.
@export_group("Rise jitter")
@export_range(0.0, 0.6) var rise_speed_jitter: float = 0.3

@export_group("Blob size", "blob_")
## Blob radius grows from min-radius (birth) to max-radius (full) over life. The
## MAX at wildfire must be big enough that blobs meet up the column (~10 at the
## default spacing) or the plume reads as floating embers.
@export_range(0.5, 24.0) var blob_max_radius_min: float = 1.2
@export_range(0.5, 24.0) var blob_max_radius_max: float = 10.0
@export_range(0.1, 8.0) var blob_min_radius_min: float = 0.4
@export_range(0.1, 8.0) var blob_min_radius_max: float = 1.2

@export_group("Shape", "")
## Elongation along the flow direction, kindling / wildfire. 1 = round.
@export_range(1.0, 4.0) var stretch_min: float = 1.3
@export_range(1.0, 4.0) var stretch_max: float = 2.0
## Amorphous carve depth, kindling / wildfire.
@export_range(0.0, 1.5) var noise_amp_min: float = 0.3
@export_range(0.0, 1.5) var noise_amp_max: float = 0.65
## Carve feature scale, kindling / wildfire (bigger blobs want coarser features,
## so max < min here is intentional).
@export_range(0.02, 2.0) var noise_scale_min: float = 0.7
@export_range(0.02, 2.0) var noise_scale_max: float = 0.45

@export_group("Density")
## Emitter half-width across the diamond, kindling / wildfire, in px.
@export_range(0.0, 24.0) var half_width_min: float = 0.5
@export_range(0.0, 24.0) var half_width_max: float = 12.0
## Live blobs per slot, kindling / wildfire. Capped by the shader's K_MAX.
@export_range(1.0, 8.0) var k_active_min: float = 2.0
@export_range(1.0, 8.0) var k_active_max: float = 8.0
## Emitter slot count, kindling / wildfire. Capped by the shader's SLOT_MAX.
@export_range(1, 3) var slot_count_min: int = 1
@export_range(1, 3) var slot_count_max: int = 3
