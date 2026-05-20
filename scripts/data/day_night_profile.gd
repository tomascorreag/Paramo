class_name DayNightProfile
extends Resource

## Data container for day-night cycle visual parameters.
## All gradients/curves are sampled at time_of_day [0.0, 1.0].
## 0.0 = midnight, 0.25 = dawn, 0.5 = noon, 0.75 = dusk.

# --- Ambient lighting (CanvasModulate) ---

## Maps time → CanvasModulate color. White = no tint, dark = nighttime.
@export var ambient_gradient: Gradient

# --- Post-process shader ---

@export_group("Post-Process")
## Color temperature shift: -1.0 cool (blue) .. +1.0 warm (golden).
@export var temperature_curve: Curve
## Contrast around midpoint. Centered at 1.0.
@export var contrast_curve: Curve
## Color saturation. Centered at 1.0.
@export var saturation_curve: Curve
## Brightness offset. Centered at 0.0.
@export var brightness_curve: Curve
## Vignette darkness at screen edges. 0 = none.
@export var vignette_strength_curve: Curve
## Overlay tint color over time (e.g., golden haze at sunset).
@export var tint_gradient: Gradient
## Overlay tint blend strength.
@export var tint_strength_curve: Curve

# --- Wind ---

@export_group("Wind")
## Global wind intensity multiplier over time. 0 = still, 1 = full per-material wind.
@export var wind_intensity_curve: Curve

# --- Water ---

@export_group("Water")
## Global water intensity multiplier over time. 0 = calm, 1 = full animation.
@export var water_intensity_curve: Curve

# --- Player visuals ---

@export_group("Player")
## Shadow alpha multiplier over time. 0 at night, ~0.5 at noon.
@export var shadow_opacity_curve: Curve
## Shadow taper direction and length over time.
## Negative = taper points left (morning sun from east),
## positive = taper points right (afternoon sun from west).
## Magnitude controls elongation; near 0 at noon = short shadow.
@export var shadow_length_curve: Curve

# --- Rain ---
#
# Weather rolls fire on TimeManager.period_changed (six per simulated day).
# At each roll the rain controller samples this curve at the current
# time_of_day and computes:
#   P(start) = rain_base_probability * curve_sample      (when idle)
#   P(stop)  = rain_base_probability * (1 - curve_sample) (when raining)
# So a curve that rises into dusk both makes rain MORE likely to start AND
# LESS likely to stop during dusk.
#
# Three guards prevent pathological streaks where the single curve makes rain
# start, stop, and immediately restart on adjacent period boundaries:
#   * rain_max_event_duration   — forces a stop after this long in ACTIVE
#   * rain_post_start_cooldown  — suppresses stop rolls right after a start
#   * rain_post_stop_cooldown   — suppresses start rolls right after a stop
# All three are in fractions of an in-game day, so they pause with the clock
# and scale with seconds_per_game_day.
@export_group("Rain")
## Probability multiplier over time-of-day. Range [0, 1].
@export var rain_probability_curve: Curve
## Per-roll scalar. Multiplied by the curve sample to get the start/stop
## probability. With ~6 rolls per simulated day, 0.25 gives a comfortable
## "rain happens most days at the favorable time-of-day" cadence.
@export_range(0.0, 1.0) var rain_base_probability: float = 0.25
## Maximum continuous ACTIVE-state duration before the controller forces a
## stop, in fractions of an in-game day. 0.5 ≈ half a day-night cycle.
@export_range(0.0, 2.0) var rain_max_event_duration: float = 0.5
## After a rain event starts, ignore stop rolls until this much in-game time
## has elapsed in ACTIVE. Prevents 'started for one period then stopped' blips.
@export_range(0.0, 1.0) var rain_post_start_cooldown: float = 0.08
## After a rain event ends, ignore start rolls until this much in-game time
## has elapsed in IDLE. Prevents stop-immediate-restart on adjacent periods.
@export_range(0.0, 1.0) var rain_post_stop_cooldown: float = 0.20
## When an event begins, target intensity is randf_range(min, max).
@export_range(0.0, 1.0) var rain_target_intensity_min: float = 0.35
@export_range(0.0, 1.0) var rain_target_intensity_max: float = 1.0
## Real-time seconds for the shader rain_amount to ramp 0 → target on start.
@export_range(0.5, 60.0) var rain_ramp_up_seconds: float = 6.0
## Real-time seconds for the shader rain_amount to ramp current → 0 on stop.
@export_range(0.5, 60.0) var rain_ramp_down_seconds: float = 10.0
## Streak angle at full rain (1.0) AND full wind (1.0). Sign controls lean
## direction. Actual angle = rain_max_angle * rain_current * wind_current.
@export_range(-0.6, 0.6) var rain_max_angle: float = 0.4
## Amplitude of fluttering noise added to the held intensity while raining.
@export_range(0.0, 0.3) var rain_noise_amplitude: float = 0.08
## Frequency (Hz) of the fluttering noise.
@export_range(0.01, 1.0) var rain_noise_frequency: float = 0.13
