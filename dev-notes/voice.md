# Voice — the coordinator's mumble speech

The coordinator says their lines out loud in a mumble voice that follows the text:
real-ish vowels and consonants, Spanish or English rules by locale, pitch rising
on a yes/no question and falling on a statement. It is synthesized live; nothing
is recorded or baked.

Spoken today: plant identification (`ActionInspect.execute`) and the three FTUE
narrative lines (`TutorialController._show_step`). Both call
`get_tree().call_group(CoordinatorVoice.GROUP, &"say", text)`, with the exact
string shown on screen.

## Where it lives

| Piece | File | Port of |
|---|---|---|
| Voice settings | `resources/voices/coordinator.tres` (`VoiceProfile`, `scripts/data/voice_profile.gd`) | `voice_lab/voices/coordinator.json` |
| Phoneme inventory | `scripts/systems/voice/voice_phones.gd` | `voice_lab/js/phonemes.js` |
| Text → phonemes | `scripts/systems/voice/voice_g2p.gd` | `voice_lab/js/g2p.js` |
| Syllables, stress, rhythm, pitch, 5 ms frames | `scripts/systems/voice/voice_plan.gd` | `voice_lab/js/plan.js` |
| Tract-lite synth + reverb | `scripts/systems/voice/voice_synth.gd` | `voice_lab/js/engines.js` + pink-trombone-mod (MIT) |
| Player node | `scripts/systems/voice/coordinator_voice.gd`, `CoordinatorVoice` in `gameplay_base.tscn` | |

The voice was designed in **`voice_lab/`** (open `voice_lab/index.html` from disk;
`.gdignore`'d, never shipped). The lab has five engines and every control; the game
ships one engine (tract-lite) and the subset of controls it reads. **Tune in the
lab, then copy the values into `coordinator.tres`** (the lab's "coordinator
(exported)" preset holds the shipped values).

## The port is checked against the lab

`tests/test_voice.gd` builds every line the coordinator can say (8 species × 11
inspect phrasings + 3 narrative lines, both locales, 162 lines with the edge
cases) with the GDScript front end and compares phones, durations (1e-6 s),
stress, phrase types and pitch against `tests/fixtures/voice_plan_fixture.json`,
which the lab writes:

```
node voice_lab/tools/make_fixture.mjs
```

The hash and RNG (FNV-1a, mulberry32) are bit-exact ports, so durations and
pitch wander match the lab exactly. Re-run the tool after changing the lab's
front end, the voice JSON, or the inspect/narrative copy; a mismatch means the
two drifted.

The synth itself is not bit-exact (noise is unseeded and the simplex wobble is
Godot's `FastNoiseLite`, not Pink Trombone's table), only the same algorithm.

## Tract-lite, and why not Pink Trombone

MEASURED, M1, Godot 4.6.1 desktop, GDScript time per second of speech:

| Engine | ms |
|---|---|
| Pink Trombone (44 sections, 2 steps/sample, 22 kHz) | ~490 for the tract loop alone: not real time once the rest is added |
| tract-lite benchmark loop (11 sections, 22 kHz) | 45 |
| **shipped tract-lite, 16 kHz, 8 sections, reverb 0.05** | **~63** (`voice_lab/tools/bench_voice.gd`) |
| same, reverb off | ~50 |
| plan + frames for a 3.3 s line | 2.6 ms once per line |

Web/wasm is expected 1.5–3× slower (UNVERIFIED): roughly 10–20% of the main
thread while the coordinator talks.

Tract-lite is Pink Trombone's glottis (LF pulse, wobble, aspiration) and tract
shaper (tongue, constrictions, velum, release click) driving a much smaller
Kelly–Lochbaum waveguide, stepped once per sample, with no nose tube (nasals mix
in a low-passed murmur). A tube's first resonance is about rate / (4 × sections),
so 8 sections at 16 kHz is the same acoustic length as Pink Trombone's 44 at
2 × 48 kHz. MEASURED in the lab on held vowels: within ~1 dB of full Pink
Trombone for /a e i/, ~4 dB for /u/; any other section count drifts 6–11 dB.
Formant scale is the tract's sample rate (`VoiceProfile.tract_rate()`), applied
for free as the generator's `mix_rate`.

Rejected: baking clips per line (~1.4 MB QOA for today's lines, grows per species)
and a syllable bank sequenced with `pitch_scale` (audible seams, formants shift with
pitch). Both are in `voice_lab/` as "Godot bank mode" if the live path fails on web.

## Live playback, and the open web question

`CoordinatorVoice` owns an `AudioStreamPlayer` on an `AudioStreamGenerator`
(`MIX_RATE_CUSTOM` at the tract rate, 0.15 s buffer) and, each frame, synthesizes
only what the buffer can take, capped at ~1.5× real time, so no frame pays for a
whole line. A new line clears the buffer and cuts the old one. It runs
`PROCESS_MODE_ALWAYS` (the FTUE talks while the journal pauses the tree) and goes
quiet while `PauseMenu.is_blocking()`.

**SPIKE-GATED:** the web build's default "sample" playback cannot play a generator
(`audio_stream_player_internal.cpp:155-166` keeps it a normal stream), so the
player is set to `PLAYBACK_TYPE_STREAM`. With threads disabled, a stream is mixed
on the main thread and fed through a JS ring buffer
(`platform/web/js/libs/library_godot_audio.js:1987-2024`), so a long frame is an
underrun. Whether that is clean in a real browser has not been tested. Test: web
export, inspect plants while walking, listen for crackle, compare
`profile_web.gd` with the voice talking and silent. If it crackles, raise
`buffer_seconds`; if it still does, fall back to bank mode.

Why not render the line to an `AudioStreamWAV` and play that: on web every runtime
`AudioStreamWAV` is registered as a sample and never released, and rewriting one's
`data` keeps playing the old audio (`audio_stream_wav.cpp:518-525`).

## Output level

The lab normalises every line to its own peak; a live stream cannot look ahead.
Calibration: 0.75 / the 90th-percentile raw peak (0.419) over every voiced line in
both locales, rendered by the lab at 16 kHz, is a gain of 1.8. Raw peaks span
0.16–0.49, so lines keep their natural loudness differences instead of all peaking
alike. **Shipped `output_gain` is 0.06**, 1/30 of that, set by ear in game in two
steps (1/3, then 1/10 of that); both earlier levels were far too loud against the mix.
A sustained voiced tone reads much louder than footsteps' short transients at a similar
peak (footsteps play at −11.5 dB on the same SFX bus). The loudest lines now peak near
0.03, so the soft ceiling above 0.8 never engages. Re-measure if the voice settings
change, then keep the same 1/30 ratio to the calibrated gain.

## Front-end notes

- No RegEx: the web template is built without the regex module, so every pattern in
  `g2p.js` is spelled out by hand in `voice_g2p.gd`.
- English copy borrows Spanish words ("páramo"); English folds accents to plain
  vowels before its rules run.
- Fixed in both lab and port: JavaScript's `"aeiou".includes("")` is true, so "past
  the end of the word" counted as a vowel. That had silently disabled word-final
  r-dropping ("car" kept its r), word-final "ng" and word-final soft "c".
