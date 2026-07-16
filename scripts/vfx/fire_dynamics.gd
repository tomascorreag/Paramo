class_name FireDynamics
extends RefCounted

# The SIM math for the wildfire: how a fire's intensity grows, how fast it eats
# its tile's fuel, how likely it is to spread, and how many flame quads it draws.
# FireManager (the autoload) owns the per-cell state and calls into here every
# tick; this file holds nothing but pure, side-effect-free functions + the
# tunable constants, exactly like FireBlobTuning does for the shader mapping.
#
# Split out for the same reason FireBlobTuning is: this is where the SPEC lives
# ("a fire grows on its own from kindling", "it can't spread below intensity 0.2",
# "grass burns faster the hotter the fire"), and it is the only part of the fire
# that can be unit-tested. See tests/test_fire_dynamics.gd.
#
# The old model (isolated_cap + a burning-neighbour ceiling) is gone: intensity is
# no longer capped for a lone fire. A fire grows individually, and it spreads
# BECAUSE it grew — the runaway comes from the population, not from a per-fire
# ceiling. See FireManager for the integration.

# --- Intensity ramp / burn arc ------------------------------------------------

# Seconds from ignition to full intensity, at plentiful fuel. This is the "slow
# at first" knob: a fresh fire spends this long climbing out of kindling before
# it is hot enough to spread.
const RAMP_SECONDS: float = 3.0

# The last fraction of a tile's fuel over which the fire dies back to embers. Once
# fuel_frac drops below this the flame cools and shrinks toward EMBER_INTENSITY.
const EMBER_FUEL_FRAC: float = 0.25

# Intensity floor the die-back approaches as fuel runs out (embers, not a full
# fire). Matches the "falls back to embers" tail the old size_envelope had.
const EMBER_INTENSITY: float = 0.35

# --- Per-fire ceiling ---------------------------------------------------------
# Each fire rolls its OWN max intensity in [MAX_INTENSITY_MIN, MAX_INTENSITY_MAX]
# at ignition (FireManager) and its whole envelope is scaled to it — so a field
# is a mix of small fires that mostly just char their tile and big ones that run
# away. The min sits just above SPREAD_MIN so even the weakest fire can *barely*
# spread; the closer a fire's ceiling is to 1, the more readily it does. Note a
# low-ceiling fire is dimmer, so (fuel burning ∝ intensity) it also consumes its
# tile slower and lives longer — a weak fire is a slow creep by construction.
const MAX_INTENSITY_MIN: float = 0.25
const MAX_INTENSITY_MAX: float = 1.0

# --- Fuel ---------------------------------------------------------------------

# Fuel (in the abstract 0..1 unit a default tile carries) burned per second at
# intensity 1.0. Chosen so a default FUEL_DEFAULT tile's full life (ramp-up +
# sustained + ember tail) lands near the old ~10s burn, keeping FireManager's
# MAX_CONCURRENT_BURNING and the flame budget valid. See test_fire_dynamics.
const FUEL_BURN_PER_SEC: float = 0.11

# Fuel a default grass tile starts with. FireManager._fuel_for_cell can return
# more/less per tile (long vs short grass) — a tile with more fuel simply burns
# longer. This is the unit the ramp/consumption constants are calibrated against.
const FUEL_DEFAULT: float = 1.0

# --- Spread -------------------------------------------------------------------

# Below this intensity a fire cannot spread at all — it just grows and chars its
# own tile. This is the "0 to 0.2 doesn't spread" gate.
const SPREAD_MIN: float = 0.2

# Base per-neighbour spread scale, per second, at intensity 1.0 and no rain. The
# actual chance ramps quadratically from 0 at SPREAD_MIN — gentle just over the
# gate, aggressive once the fire is hot. Tuned (with RAMP/fuel) so a fire reliably
# seeds its grass neighbours over its life without going up instantly — the
# spread-window guard in test_fire_dynamics holds this.
const SPREAD_RATE: float = 0.35

# --- Flame count --------------------------------------------------------------

# Max scattered flame quads a single cell draws, at full intensity. Kept low: the
# blob shader is fill-heavy and scattered extras overlap the primary, so most of
# the extra fill is redundant overdraw. Raise only if benchmark_fire.gd shows the
# look is worth it. flame_count TRACKS current intensity (it may shrink), so this
# is a peak, not a running cost.
const MAX_FLAMES_PER_CELL: int = 2


## Fire intensity in [0, 1] from its age (seconds since ignition), how much of its
## tile's fuel remains (fuel_frac in [0, 1]), and this fire's own ceiling
## (max_intensity in [0, 1], rolled once at ignition). Rises from 0 over
## RAMP_SECONDS, sits near max_intensity while fuel is plentiful, and dies back
## toward EMBER_INTENSITY*max_intensity as the last EMBER_FUEL_FRAC of fuel burns.
## No neighbour term — a lone fire grows too. Scaling (not clamping) the whole
## envelope keeps the ember floor below the ceiling even for a low-ceiling fire.
static func intensity(age: float, fuel_frac: float, max_intensity: float = 1.0) -> float:
	var ramp: float = clampf(age / RAMP_SECONDS, 0.0, 1.0)
	var ember: float = smoothstep(0.0, EMBER_FUEL_FRAC, clampf(fuel_frac, 0.0, 1.0))
	return clampf(max_intensity, 0.0, 1.0) * ramp * lerpf(EMBER_INTENSITY, 1.0, ember)


## Fuel consumed this frame. Proportional to intensity, so kindling barely touches
## the grass and a raging fire clears it fast — this is what makes the grass "burn
## slowly by the fire as it progresses".
static func fuel_consumed(fire_intensity: float, dt: float) -> float:
	return maxf(fire_intensity, 0.0) * FUEL_BURN_PER_SEC * dt


## Per-neighbour spread chance this frame, in [0, 1). Zero below SPREAD_MIN; above
## it, ramps as the square of the normalised over-threshold intensity so it is
## gentle near the gate and aggressive when hot. `rain_mult` (0..1) is FireManager's
## rain damping.
static func spread_probability(fire_intensity: float, dt: float, rain_mult: float) -> float:
	if fire_intensity < SPREAD_MIN:
		return 0.0
	var s: float = clampf((fire_intensity - SPREAD_MIN) / (1.0 - SPREAD_MIN), 0.0, 1.0)
	return SPREAD_RATE * s * s * dt * rain_mult


## How many scattered flame quads a cell at this intensity should draw (>=1).
## Tracks current intensity and is allowed to fall — a flame dropping out as a
## fire calms reads fine, and holding peak-count quads through the long ember tail
## would waste fill.
static func flame_count(fire_intensity: float) -> int:
	return clampi(1 + int(floor(clampf(fire_intensity, 0.0, 1.0) * float(MAX_FLAMES_PER_CELL))),
			1, MAX_FLAMES_PER_CELL)
