# voice_lab

A browser dashboard for comparing three ways to synthesize mumble speech for dialogue. It is a dev tool and is never shipped. `.gdignore` keeps Godot from importing or exporting the folder.

Open `index.html` directly (double-click, `file://` works, no server needed).

## Pipeline

1. **`js/g2p.js`: text to phonemes.**
   - es-CO: near-complete rules, including seseo, ll/y → ʝ, lenited b/d/g between vowels, and i/u → glides in diphthongs. Stress comes from the written accent, otherwise the vowel/n/s rule.
   - en-GB: rough digraph and magic-e rules, non-rhotic, with a small dictionary of very common words. Suffix and prefix rules choose the stress.
2. **`js/plan.js`: phonemes to plan.**
   - Syllables, durations, and phrases split at punctuation, each tagged statement / continue / yes-no / wh / exclaim.
   - A pitch contour in semitones built from declination, stressed-syllable accents and the final contour. Yes/no questions rise; wh-questions fall, in both languages.
   - 5 ms control frames: f0, voicing, formants with coarticulation blends, frication, bursts, aspiration for voice onset.
3. **`js/engines.js`: five engines render the same frames.** The cost figures are GDScript time per second of 22.05 kHz speech, measured with Godot 4.6.1 on an M1; web is expected to be 1.5–3× slower (not measured).
   - `trombone`: Pink Trombone. About 490 ms or more, so it serves as the reference only.
   - `lite`: Pink Trombone's glottis and tract shaper driving an 11-section waveguide, stepped once per sample, with no nose tube. About 45 ms. On held vowels its spectrum is within about 1 dB of full Pink Trombone for a/e/i and 4 dB for u.
   - `cheap`: four parallel band-pass formants. About 28 ms.
   - `blips`: one vowel blip per syllable. About 10 ms.
   - `klatt`: KlattSyn. About 40–45 ms, measured on a loop with Klatt's per-sample shape (natural source, 9 cascade resonators, 7 parallel on noisy samples), not a full port.
   - A shared post chain (Mii-style chain, lo-fi) then normalises the result.

## Flatness controls

These push any engine from human-sounding speech toward flat gibberish:

- **Stepped pitch:** one held note per syllable, sampled from the intonation contour.
- **Pitch grid:** snaps those notes to semitones or a pentatonic scale.
- **Even rhythm:** removes stress and phrase-final lengthening.
- **Syllable chop:** puts a short silence at the end of every syllable.
- **Consonant softness:** stops and taps narrow without closing, fricatives hiss less, bursts shrink, and consonants get shorter. In Pink Trombone, softness 0.5 or higher means no closure is ever complete, so the release click never fires.
- **Word-final consonants:** keep, soften (fully soft regardless of the slider) or drop. Releases into silence at word ends are where the "slap" comes from.
- **Trombone plosive click:** sets the strength of the pressure pulse Pink Trombone fires on every release of a full closure (stock 0.3).
- **Trombone natural wobble:** unticking it strips the two simplex pitch wobbles (about ±6%) and the tenseness drift that Pink Trombone's glottis adds even with `autoWobble` off.

## Synthetic and smooth

- **Trombone source:** replaces Pink Trombone's LF glottal pulse with a soft raised-cosine pulse, or a saw or square (polyBLEP band-limited). The tract still shapes the vowels.
- **Trombone pure voice:** drops the breath noise the stock glottis mixes into every voiced sample. Noise is kept where the glottis is meant to be open: h, aspiration, voiceless consonants.
- **Warmth / chorus / reverb:** post-processing on all engines.
  - Warmth is a low-pass that sweeps from 12 kHz down to 2.5 kHz.
  - Chorus is two detuned delay taps.
  - Reverb is a small Freeverb-style room.
  - Warmth and chorus would bake into syllable clips in-game. Reverb can't run as a bus effect on the web build; it would have to be baked per syllable, and the lab can't preview that because it applies reverb to the whole line.

## Godot bank mode

The Godot web build can't create audio at runtime per line (see the research in the conversation that started this lab: every runtime `AudioStreamWAV` leaks on web, and bus effects do nothing in sample mode). Bank mode shows what a shippable version sounds like:

- each unique syllable is rendered once, alone, at the base pitch;
- the line is rebuilt by resampling each clip by `f0 / base`, which is exactly what `pitch_scale` does.

Listen for formant shift on the large pitch moves, and for seams between syllables. The stats line gives the bank size that line needs.

## The game's copy

The game ships tract-lite only, ported to GDScript in `scripts/systems/voice/`. Its settings are in `resources/voices/coordinator.tres`, the "coordinator (exported)" preset here, from `voices/coordinator.json`.

After changing `js/phonemes.js`, `js/g2p.js`, `js/plan.js`, the voice JSON, or the spoken copy, run `node voice_lab/tools/make_fixture.mjs`. `tests/test_voice.gd` then checks that the port still says exactly what the lab says.

`tools/bench_voice.gd` prices the GDScript synth. See `dev-notes/voice.md`.

## Data sources

- English vowel formants: Hillenbrand et al. 1995. These are American English men; RP data (Wells 1962) could not be fetched. NURSE's F3 was raised by hand to remove the r-colouring.
- Spanish F1/F2: Bradlow 1995. F3 is estimated.
- Pink Trombone tongue positions: zakaton/Pink-Trombone's table. Values not in that table are guesses.

## Vendored code

`js/vendor.js` is an esbuild bundle of three MIT-licensed packages:

| Package | Copyright |
|---|---|
| `klatt-syn@1.0.9` | Christian d'Heureuse |
| `dsp-collection@1.0.1` | Christian d'Heureuse |
| `pink-trombone-mod@0.1.0` | Neil Thapen 2017, modular port by Christian d'Heureuse |

The licence text is in the file header. To rebuild it, run `npm install klatt-syn@1.0.9 pink-trombone-mod@0.1.0 esbuild` in a scratch directory, then bundle an entry that assigns `window.VoiceLabVendor = { generateKlatt, PinkTromboneSynthesizer }` with `esbuild --bundle --format=iife`.
