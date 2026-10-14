class_name CoordinatorVoice
extends Node

## The coordinator's mumble voice: says a line of text out loud, synthesized live
## by tract-lite (VoiceSynth) from a VoicePlan of the text, in the active locale.
##
## Callers don't hold a reference: they `call_group(GROUP, &"say", text)`, the
## project's way of wiring across systems. A new line cuts the one playing.
## Spoken today: plant identification (ActionInspect) and the FTUE's narrative
## lines (TutorialController).
##
## Live synthesis, not clips: the line is synthesized as the generator asks for
## audio, at most ~1.5x real time per frame, so no frame pays for a whole line.
## Godot's web "sample" playback cannot play a generator, so this player is set
## to STREAM playback. Whether that is clean on the threadless web build is the
## open question in dev-notes/voice.md; desktop is fine.
##
## Unity bridge: an AudioSource fed from OnAudioFilterRead, except Godot pulls
## through AudioStreamGeneratorPlayback.push_buffer from _process instead.

const GROUP: StringName = &"coordinator_voice"

@export var profile: VoiceProfile = preload("res://resources/voices/coordinator.tres")
@export var bus: StringName = &"SFX"
@export var volume_db: float = 0.0
## Generator buffer. Longer survives worse frame hitches, at that much latency.
@export_range(0.05, 0.5, 0.01, "suffix:s") var buffer_seconds: float = 0.15

var _player: AudioStreamPlayer
var _playback: AudioStreamGeneratorPlayback
var _synth := VoiceSynth.new()
var _mono := PackedFloat32Array()
var _stereo := PackedVector2Array()
var _drain_left: float = 0.0


func _ready() -> void:
	add_to_group(GROUP)
	# ALWAYS: the FTUE speaks while the journal holds the tree paused. The pause
	# menu still silences it (_process checks PauseMenu.is_blocking()).
	process_mode = Node.PROCESS_MODE_ALWAYS
	var gen := AudioStreamGenerator.new()
	gen.mix_rate_mode = AudioStreamGenerator.MIX_RATE_CUSTOM
	gen.mix_rate = profile.tract_rate()
	gen.buffer_length = buffer_seconds
	_player = AudioStreamPlayer.new()
	_player.stream = gen
	_player.bus = bus
	_player.volume_db = volume_db
	_player.playback_type = AudioServer.PLAYBACK_TYPE_STREAM
	add_child(_player)
	set_process(false)


## Say `text` now, cutting off whatever was being said.
func say(text: String) -> void:
	if profile == null or text.strip_edges().is_empty():
		return
	var lang: StringName = &"es" if TranslationServer.get_locale().begins_with("es") else &"en"
	_synth.start(VoicePlan.build(text, lang, profile), profile)
	if not _player.playing:
		_player.play()
	_playback = _player.get_stream_playback() as AudioStreamGeneratorPlayback
	_playback.clear_buffer()
	_drain_left = 0.0
	_player.stream_paused = false
	set_process(true)


func stop() -> void:
	_synth.stop()
	if _player.playing:
		_player.stop()
	set_process(false)


func is_speaking() -> bool:
	return is_processing()


func _process(delta: float) -> void:
	var blocked := PauseMenu.is_blocking()
	_player.stream_paused = blocked
	if blocked:
		return
	if _synth.is_finished():
		# Let the last buffered audio play out, then stop pulling the generator.
		_drain_left += delta
		if _drain_left > buffer_seconds + 0.05:
			stop()
		return
	var rate := profile.tract_rate()
	var want := mini(_playback.get_frames_available(), ceili(delta * rate * 1.5) + 256)
	if want <= 0:
		return
	_mono.clear()
	_synth.fill(_mono, want)
	_stereo.resize(_mono.size())
	for i in _mono.size():
		_stereo[i] = Vector2(_mono[i], _mono[i])
	_playback.push_buffer(_stereo)
