class_name VoiceProfile
extends Resource

## One speaker's mumble voice: everything the tract-lite synth and the text
## front end need, tuned in voice_lab/ (open voice_lab/index.html) and copied
## here from its exported settings JSON. Field names mirror the lab's keys
## (snake_case here, camelCase there) so a lab export maps one to one.
##
## Unity bridge: a ScriptableObject holding a synth preset.

enum Quantize { OFF, SEMITONE, PENTATONIC }
enum FinalConsonants { KEEP, SOFTEN, DROP }
enum GlottalSource { NATURAL, PULSE, SAW, SQUARE }

@export_group("Voice")
## Speaker seed: scramble, duration jitter and pitch wander are deterministic per seed.
@export var seed: String = "coordinator"
@export_range(60.0, 420.0, 1.0, "suffix:Hz") var base_pitch: float = 200.0
## Vocal tract size. Above 1 is a smaller tract (higher formants); applied as the
## synth rate, so it costs nothing.
@export_range(0.8, 1.4, 0.01) var formant_scale: float = 1.1
@export_range(0.5, 2.2, 0.01) var speed: float = 1.35
@export_range(0.0, 1.0, 0.01) var tense: float = 0.0
@export_range(0.0, 1.0, 0.01) var breath: float = 0.0

@export_group("Prosody")
@export_range(0.0, 8.0, 0.1, "suffix:st") var accent_st: float = 3.0
@export_range(0.0, 10.0, 0.1, "suffix:st") var rise_st: float = 6.0
@export_range(0.0, 8.0, 0.1, "suffix:st") var fall_st: float = 3.0
@export_range(0.0, 4.0, 0.1, "suffix:st") var declination: float = 1.5
@export_range(0.0, 2.0, 0.05, "suffix:st") var wander: float = 1.25
@export_range(0.0, 120.0, 1.0, "suffix:ms") var word_gap_ms: float = 5.0
@export_range(5.0, 90.0, 1.0, "suffix:ms") var coartic_ms: float = 25.0
@export_range(0.0, 1.0, 0.01) var scramble: float = 0.05

@export_group("Flatness")
@export_range(0.0, 1.0, 0.01) var flat_pitch: float = 1.0
@export var quantize: Quantize = Quantize.SEMITONE
@export_range(0.0, 1.0, 0.01) var even_rhythm: float = 0.75
@export_range(0.0, 40.0, 1.0, "suffix:ms") var chop_ms: float = 0.0
@export_range(0.0, 1.0, 0.01) var softness: float = 0.75
@export var final_consonants: FinalConsonants = FinalConsonants.SOFTEN

@export_group("Texture")
@export_range(0.0, 5.0, 0.05, "suffix:%") var jitter: float = 1.5
@export_range(0.0, 15.0, 0.1, "suffix:%") var shimmer: float = 3.0
@export_range(0.0, 9.0, 0.1, "suffix:Hz") var vib_rate: float = 5.5
@export_range(0.0, 4.0, 0.05, "suffix:%") var vib_depth: float = 1.0
@export_range(0.0, 1.0, 0.01) var creak: float = 0.05

@export_group("Tract")
@export var glottal_source: GlottalSource = GlottalSource.NATURAL
## Pink Trombone's own simplex pitch wobble and tenseness drift.
@export var natural_wobble: bool = true
## No breath noise in voiced sounds (kept for h, aspiration, voiceless consonants).
@export var pure_voice: bool = true
@export_range(10.0, 80.0, 1.0) var tract_speed: float = 35.0
@export_range(0.0, 50.0, 1.0, "suffix:ms") var tract_lead_ms: float = 15.0
@export_range(0.5, 5.0, 0.05) var fric_boost: float = 2.5
@export_range(0.0, 1.0, 0.01) var plosive_click: float = 1.0
@export_range(0.985, 0.999, 0.0005) var tract_damping: float = 0.996

@export_group("Output")
## Synthesis rate before formant scaling. The tract's section count follows it
## (11 sections at 22.05 kHz is Pink Trombone's acoustic length).
@export_range(11025.0, 22050.0, 1.0, "suffix:Hz") var synth_rate: float = 16000.0
@export_range(0.0, 1.0, 0.01) var warmth: float = 0.1
@export_range(0.0, 0.6, 0.01) var reverb_mix: float = 0.05
## Fixed output gain. The lab normalises each line to its peak; a live stream
## cannot look ahead, so this is calibrated offline (voice_lab/README.md).
@export_range(0.0, 8.0, 0.01) var output_gain: float = 1.0


## Waveguide sections for this synth rate.
func tract_sections() -> int:
	return maxi(4, roundi(11.0 * synth_rate / 22050.0))


## The rate the tract actually runs at, and the AudioStreamGenerator's mix rate.
func tract_rate() -> float:
	return synth_rate * formant_scale
