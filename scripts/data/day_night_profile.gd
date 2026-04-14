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
