class_name BotPolicy
extends Resource

## Configuration for the balance simulator's scripted player stand-in.
## Deliberately a Resource: sweeps compare policies the way they compare
## balance scenarios, and a policy can be authored as a .tres later.
## All decisions drawn from the bot's own seeded rng — noise included, a run
## stays deterministic per (seed, policy).

## Seconds between a fire starting and the bot being able to react to it —
## the stand-in for human noticing/attention. Applied per travel decision.
@export var reaction_delay_seconds: float = 3.0

## The bot ignores fires until at least this many cells burn at once
## (a lazier player archetype at higher values).
@export var min_fires_to_act: int = 1

## Water the bot refuses to spend below — dousing stops when the reserve
## would be broken (keeps a buffer for the next fire).
@export var water_reserve: float = 2.0

## Unlock purchase order during planning phases (10 tokens each).
@export var unlock_priority: Array[StringName] = [&"ladder", &"bridge", &"frailejon"]

## Probability [0,1] of a suboptimal decision: targeting a random fire
## instead of the nearest, or skipping an affordable planning purchase.
## 0 = optimal scripted play; raise to model imperfect players.
@export var decision_noise: float = 0.0

## Placements attempted per planning phase (5 tokens each, after unlocks).
@export var place_per_planning: int = 1

## Random walkable cells sampled when searching for a legal ladder wall or a
## frailejon spot (bounds the per-planning search cost).
@export var placement_samples: int = 30

## How many of the nearest fires get a pathfinding attempt per decision
## (bounds the per-decision cost; fires beyond this are ignored this pass).
@export var candidate_fires: int = 5

## Movement timing — the player's exports (player.gd defaults). Same values
## the game charges via TileGrid.step_duration_for.
@export var step_seconds: float = 0.45
@export var climb_mult: float = 2.0
@export var scramble_mult: float = 4.0
