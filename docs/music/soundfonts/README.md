# Soundfonts (vendored, third-party)

The three General MIDI instruments the arrangement plays, in
[webaudiofont](https://github.com/surikov/webaudiofont) `.js` form. Served to
every visitor of the web build, and **not** covered by Paramo's MIT licence.

| File | GM program | Layer |
|---|---|---|
| `0750_FluidR3_GM_sf2_file.js` | 75 — pan flute | `melody` |
| `0240_FluidR3_GM_sf2_file.js` | 24 — nylon acoustic guitar | `chords` |
| `0320_FluidR3_GM_sf2_file.js` | 32 — acoustic bass | `bass` |

## Licence

**MIT**, on both layers that matter:

- The sample data is the **Fluid (R3) SoundFont**, © 2000-2002, 2008 Frank Wen.
  His README states plainly: *"I hereby release Fluid under the MIT license, as
  described in COPYING."* Full text in [`LICENSE`](./LICENSE); the notice there
  is not optional decoration — MIT requires it to travel with the copies.
- The `*_sf2_file.js` packaging comes from
  [`surikov/webaudiofontdata`](https://github.com/surikov/webaudiofontdata),
  also MIT.

## Why FluidR3 and not the engine default

Strudel's default variant for all three instruments is **JCLive**, and that is
what this directory used to hold. No affirmative redistribution grant could be
found for the JCLive sample data in any primary source, so shipping it on a
public site was an open-ended risk on assets we redistribute.

FluidR3 is the same instruments with provenance that can be cited, so the song
selects it explicitly with the `n` control:

```js
.sound("gm_pan_flute").n(1)              // 0750_FluidR3_GM_sf2_file
.sound("gm_acoustic_guitar_nylon").n(3)  // 0240_FluidR3_GM_sf2_file
.sound("gm_acoustic_bass").n(1)          // 0320_FluidR3_GM_sf2_file
```

**Those indices are per-instrument and not interchangeable.** Each instrument in
`web-sf-1.3.0.js` carries its own ordered variant list, and FluidR3 sits at a
different position in each — index 3 for the guitar, index 1 for the other two.
`registerSoundfonts` resolves them as `t[Ta(s.n, t.length)]`, so a wrong index
does not error: it silently loads a different soundfont, and the wrapper file it
then asks for is not in this directory, so the layer goes **silent**. If you add
an instrument, read its list out of the bundle rather than assuming a position.

`n` is a distinct control from `note`, so selecting a variant does not transpose
anything.
