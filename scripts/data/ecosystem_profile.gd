@tool
class_name EcosystemProfile
extends Resource

# ============================================================================
# EcosystemProfile
# ============================================================================
#
# Which plant species a mountain has, and how much of each. One profile is
# picked per run (ObjectPainter draws it from the object rng, so it is part of
# the seed's identity) and modelled on a real Colombian paramo, because the
# species do not all cohabit: the three Espeletia in the sprite sheet are
# allopatric — E. grandiflora is the humid Cordillera Oriental (Chingaza,
# Sumapaz), E. barclayana the dry Oriental paramos north of Bogota (Guerrero,
# Neusa, Rabanal), E. hartwegiana the Cordillera Central (Los Nevados, Purace)
# — and the shrubs follow the same split (Arcytophyllum nitidum has one GBIF
# record in the whole Central cordillera). design/flora.md has the species;
# the per-profile numbers are in resources/ecosystems/*.tres.
#
# This is a density LAYER over `WorldObjectData.density_by_biome`, not a
# replacement: the per-kind .tres still says where on a slope a species sits;
# the profile says whether, and how strongly, it is on THIS mountain.
#
# ============================================================================


## Stable identity (`&"chingaza"`), used by `ProceduralWorld.ecosystem_override`
## and by tools to name the profile in reports.
@export var id: StringName = &""

## Reserved for a journal/UI label. Not wired: any copy shown to the player
## needs a CSV key and an accent-free Eggmode form (see CLAUDE.md, Localization).
@export var display_key: String = ""

## Kind → multiplier on that kind's procgen density. A kind MISSING from the
## dictionary never spawns on this mountain (multiplier 0) — the absence is the
## point, so don't "complete" the table with zeros for readability; missing
## and 0.0 mean the same thing to the painter.
@export var density_scale: Dictionary = {}

## Kinds the shop may sell on this mountain. A plantable species absent from
## the mountain is not sold — the player restores what belongs here.
@export var plantable: Array[StringName] = []


## Density multiplier for `kind`; 0.0 when the kind is not part of this
## ecosystem.
func scale_for(kind: StringName) -> float:
	return float(density_scale.get(kind, 0.0))


## Whether the shop may offer `kind` on this mountain.
func can_plant(kind: StringName) -> bool:
	return plantable.has(kind)
