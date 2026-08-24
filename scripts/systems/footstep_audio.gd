class_name FootstepAudio
extends Node

# ============================================================================
# FootstepAudio — surface-aware footstep SFX for the player
# ============================================================================
#
# Driven by Player: `step_started` on each grid step (which surface are we on?)
# and `footfall` on each foot contact of the walk cycle (play it now). The node
# owns surface resolution and clip randomization; CADENCE IS NOT ITS BUSINESS —
# see the note below.
#
# WHY a separate node rather than fields on player.gd: the player script is
# already the movement state machine; footsteps only need (destination cell,
# step kind, step duration) — a narrow enough interface that keeping the audio
# state (pool, cadence timer, surface tables) out of it costs nothing and lets
# other walkers (future NPCs/threats) reuse this verbatim.
#
# Surface resolution, in priority order:
#   1. LADDER step            -> wood (ladders are timber)
#   2. bridge_deck occupant   -> wood
#   3. tile atlas source id   -> snow -> snow, rock -> rock
#   4. everything else        -> grass (dirt included; see _SOURCE_TO_SURFACE)
#
# Every clip goes through an AudioStreamRandomizer (resources/audio/*.tres),
# which per play picks one of 5 takes (no immediate repeat), scales pitch within
# [1/1.15, 1.15] and offsets volume within [-3 dB, +3 dB]. So no two footfalls
# are identical even on a straight line across one biome.
#
# The clips are MONO WAV, imported as QOA (assets/audio/footsteps/). This is a
# measured decision, not a default: play() on an Ogg Vorbis stream costs ~0.60 ms
# because it spins up a Vorbis decoder per shot, and that landed as a ~0.6 ms
# spike on every footfall frame in-game. The same clips as mono QOA cost
# ~0.045 ms — 13x cheaper — for +17 KB per surface in the pck. Keep one-shot SFX
# on WAV/QOA; Ogg is for long streamed audio, where the decoder setup amortises.
#
# Cadence lives in Player, not here, because the authority on when a foot hits
# the ground is the WALK ANIMATION: Player.WALK_CONTACT_FRAMES marks the contact
# frames of the 6-frame cycle and Player calls footfall() as it passes them.
# Two earlier designs were wrong for the same reason — they invented a rhythm
# instead of reading one:
#   - one clip per grid cell: the character takes more than one pace to cross a
#     32x16 tile, so the walk sounded sluggish against its own animation;
#   - a free-running timer here: correct on average, but free to drift out of
#     phase with the visible footfall, which is the one thing that must match.
# Anything that changes the animation's pace (WALK_FPS, a re-authored sheet)
# now moves the audio with it automatically.
#
# ============================================================================


## Surface id -> AudioStreamRandomizer. Add a new surface by adding a folder
## under assets/audio/footsteps/, a randomizer .tres, and an entry here plus a
## row in _surface_for_step.
const SURFACE_GRASS: StringName = &"grass"
const SURFACE_SNOW: StringName = &"snow"
const SURFACE_WOOD: StringName = &"wood"
const SURFACE_ROCK: StringName = &"rock"

# Atlas source ids the terrain painter uses per biome. Mirrored from
# TerrainPainter (the paint-side authority) so a biome retune is a one-line
# change there and a one-line change here. DIRT is deliberately absent — it
# falls through to grass, which reads fine for packed earth; give it its own
# clips when a dirt-specific sound exists.
const _SOURCE_TO_SURFACE: Dictionary[int, StringName] = {
	TerrainPainter.SOURCE_SNOW: SURFACE_SNOW,
	TerrainPainter.SOURCE_ROCK: SURFACE_ROCK,
}

const _BRIDGE_DECK_KIND: StringName = &"bridge_deck"

# Voices in the pool. Footsteps are ~0.3 s and the fastest cadence is ~0.4 s,
# so overlap is rare — but a single player would hard-cut the previous clip
# when it does happen, which is audible. Three is enough headroom.
const _VOICE_COUNT: int = 3

@export var bus: StringName = &"SFX"
## Gain applied to every voice. dB, so 2/3 of a given loudness is that value
## minus 3.5 (20*log10(2/3)), not two-thirds of the number. Setter-backed so
## dragging it in the inspector while the game runs is audible immediately.
@export var volume_db: float = -11.5:
	set(v):
		volume_db = v
		for voice in _voices:
			voice.volume_db = v
@export var enabled: bool = true

@export_group("Surfaces")
@export var stream_grass: AudioStream = preload("res://resources/audio/footsteps_grass.tres")
@export var stream_snow: AudioStream = preload("res://resources/audio/footsteps_snow.tres")
@export var stream_wood: AudioStream = preload("res://resources/audio/footsteps_wood.tres")
## Kenney's "concrete" clips — the hardest, most mineral footfall in the pack.
@export var stream_rock: AudioStream = preload("res://resources/audio/footsteps_rock.tres")

var _voices: Array[AudioStreamPlayer] = []
var _next_voice: int = 0

# Surface the next footfall will play. Refreshed on each grid step, held between
# them — a walk cycle straddles cell boundaries, so a footfall can land at any
# point within a step.
var _surface: StringName = SURFACE_GRASS


func _ready() -> void:
	for i in _VOICE_COUNT:
		var v := AudioStreamPlayer.new()
		v.bus = bus
		v.volume_db = volume_db
		# Footsteps stop with the game — no reason to keep ringing through the
		# pause menu.
		v.process_mode = Node.PROCESS_MODE_PAUSABLE
		add_child(v)
		_voices.append(v)
	# Purely reactive — everything happens inside footfall().
	set_process(false)


# ----------------------------------------------------------------------------
# Public API (called by Player)
# ----------------------------------------------------------------------------

## Announce a grid step that has just begun, so later footfalls play the right
## material. `cell` is the DESTINATION cell (the surface being stepped onto) and
## `step_kind` a TileGrid.StepKind. Plays nothing by itself.
func step_started(pathfinder: Pathfinder, cell: Vector2i, step_kind: int) -> void:
	if not enabled:
		return
	_surface = _surface_for_step(pathfinder, cell, step_kind)


## A foot just hit the ground. Called by Player on the walk cycle's contact
## frames.
func footfall() -> void:
	_emit(_surface)


# ----------------------------------------------------------------------------
# Internals
# ----------------------------------------------------------------------------


func _emit(surface: StringName) -> void:
	if not enabled:
		return
	var stream := _stream_for(surface)
	if stream == null:
		return
	# Round-robin rather than "first idle": with 3 voices and this cadence the
	# oldest voice is always the safest to steal, and it needs no is_playing scan.
	var v := _voices[_next_voice]
	_next_voice = (_next_voice + 1) % _voices.size()
	v.stream = stream
	v.play()


func _stream_for(surface: StringName) -> AudioStream:
	match surface:
		SURFACE_SNOW: return stream_snow
		SURFACE_WOOD: return stream_wood
		SURFACE_ROCK: return stream_rock
	return stream_grass


func _surface_for_step(pathfinder: Pathfinder, cell: Vector2i, step_kind: int) -> StringName:
	if step_kind == TileGrid.StepKind.LADDER:
		return SURFACE_WOOD
	if pathfinder == null:
		return SURFACE_GRASS
	# One CellData fetch serves both checks below — occupant_at() and get_tile()
	# are separate public entry points onto the same per-cell record.
	var data := pathfinder.get_tile(cell)
	if data == null:
		return SURFACE_GRASS
	# has_method rather than a cast: occupants are duck-typed, not a class
	# hierarchy. Bridge extends Traversal -> Node2D, NOT WorldOccupant, so
	# `as WorldOccupant` would silently miss every bridge. TileGrid resolves
	# occupants the same way.
	var occ := data.occupant
	if occ != null and occ.has_method(&"occupant_kind"):
		if occ.call(&"occupant_kind") == _BRIDGE_DECK_KIND:
			return SURFACE_WOOD
	# Biome comes from which atlas source painted the winning tile — the same
	# mapping TerrainPainter used on the way in. Cheaper and more direct than
	# re-deriving the biome from altitude bands.
	if data.layer == null:
		return SURFACE_GRASS
	return _SOURCE_TO_SURFACE.get(data.layer.get_cell_source_id(cell), SURFACE_GRASS)
