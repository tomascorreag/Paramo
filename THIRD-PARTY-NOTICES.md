# Third-Party Notices

Paramo ("the game") is licensed under the MIT License (see [LICENSE](./LICENSE)).
The components below are third-party works bundled in, or loaded by, this
repository under their own licenses; the MIT grant does **not** apply to them.

- **Shipped** = included in the deployed web build (`docs/` → `gh-pages`).

**The deployed build fetches nothing from a third party at play time** (since
2026-08-17). Everything it loads is served from our own origin and appears below
with an affirmative open-source grant. There is deliberately no "runtime CDN"
category any more — see [Removed](#removed) for what used to be in it and why
re-adding one is a decision, not a detail.

## Shipped in the web build

### Strudel music engine — `docs/music/strudel/web-sf-1.3.0.js`
- **License:** GNU Affero General Public License v3.0-or-later (`AGPL-3.0-or-later`).
- **Copyright:** Strudel contributors.
- **Source:** <https://codeberg.org/uzu/strudel>
- **Local notice & corresponding-source offer:**
  [`docs/music/strudel/README.md`](./docs/music/strudel/README.md); full license
  text at [`docs/music/strudel/LICENSE`](./docs/music/strudel/LICENSE).
- Kept as a separate served file from the game (aggregate), so Paramo's own MIT
  code is not combined into the AGPL work.

### General MIDI soundfonts — `docs/music/soundfonts/{0240,0320,0750}_FluidR3_GM_sf2_file.js`
- **License:** MIT, on both layers.
- **Sample data:** Fluid (R3) SoundFont, **© 2000-2002, 2008 Frank Wen**
  (GM 24 nylon guitar, 32 acoustic bass, 75 pan flute — the three instruments the
  arrangement uses). Wen's README: *"I hereby release Fluid under the MIT
  license, as described in COPYING."*
- **Format/loader:** webaudiofont (<https://github.com/surikov/webaudiofont>);
  the `*_sf2_file.js` wrappers come from
  <https://github.com/surikov/webaudiofontdata> (MIT).
- **Local notice & required copyright line:**
  [`docs/music/soundfonts/README.md`](./docs/music/soundfonts/README.md); license
  text at [`docs/music/soundfonts/LICENSE`](./docs/music/soundfonts/LICENSE).
  MIT requires that notice to ship with the files — do not drop it when swapping
  instruments.
- The song selects this variant explicitly via `.n()`, because the engine's
  default for all three is JCLive (see [Removed](#removed)).

### Drum samples — `docs/music/samples/uzu-drumkit/`
- **License:** The Unlicense (public domain).
- **Source:** <https://github.com/tidalcycles/uzu-drumkit>
- 21 WAVs: all variants of the six keys the arrangement plays (`bd`, `sd`, `cr`,
  `oh`, `rd`, `sh`). Details in
  [`docs/music/samples/README.md`](./docs/music/samples/README.md).

## Removed

Kept here so neither decision gets quietly reversed by someone reaching for the
obvious fix.

### tidal-drum-machines / `AkaiMPC60` — removed 2026-08-17
The bombo used to play `sound("bd").bank("AkaiMPC60")`, hot-linked from
`strudel.b-cdn.net`. That pack **grants no license** (all rights reserved) and
the names are inMusic trademarks, so it could never be vendored — and hot-linking
it was the only reason a third-party fetch remained in the deployed build. The
bombo now plays the unbanked uzu `bd`.

**Do not re-add it, and do not vendor it.** Wanting the MPC60 timbre back means
sourcing a separately-licensed kick, not restoring the `.bank()` call.

### JCLive soundfonts — removed 2026-08-17
No affirmative redistribution grant could be found for the JCLive sample data in
any primary source, and it is Strudel's *default* variant for all three of our
instruments — so it comes back the moment someone deletes an `.n()` call. That is
exactly what those `.n()` indices are defending against. Replaced by FluidR3
above; `GeneralUser GS v2.0` remains a permissive alternative if FluidR3 ever
needs replacing.

## Development-only (not shipped)

The `music/` score→Strudel converter uses `@strudel/core` and `@strudel/mini`
(AGPL-3.0-or-later) and `fraction.js` (MIT) as dev dependencies. They live in a
git-ignored `node_modules/` and never enter the build.
