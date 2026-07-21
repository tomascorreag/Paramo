class_name UILayers
extends RefCounted

## Single source of truth for every CanvasLayer.layer number in the project.
##
## Higher value draws on top. Gaps of 10 leave room to insert new layers without
## renumbering. Keep authored `.tscn` layer values in sync with these constants —
## scenes can't reference GDScript constants, so `tests/test_ui_layers.gd` guards
## against drift.
##
## Previously several UI layers collided at 100 (PostProcess + DebugOverlay +
## Toast), leaving their stacking to implicit tree order. This registry resolves
## those collisions.

const POST_PROCESS := 100  ## color grade + vignette; all screen UI sits ABOVE this
const FIRE_AURA := 105     ## off-screen-fire edge glow; ABOVE the grade (so the
                           ## vignette can't cancel it), BELOW the HUD
const HUD := 110           ## gameplay HUD (season gauge, item slot). Ungraded.
const TOAST := 120         ## inspect/info messages (was 100)
const RADIAL_MENU := 130   ## right-click action wheel + dim overlay (was 101)
const JOURNAL := 140       ## field journal modal (season gauge + run info). Pauses the
                           ## game; below PAUSE so the pause modal can still cover it.
const LOADING := 200       ## startup world-gen cover (was 128)
const TITLE := 210         ## opening cinematic (was 200)
const PAUSE := 220         ## pause modal — gameplay overlay ABOVE the startup loading/title
                           ## covers (only shown once those are gone), below debug
const DEBUG := 250         ## dev panel — always on top (was 100)
