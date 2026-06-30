# Third-Party Notices

Paramo ("the game") is licensed under the MIT License (see [LICENSE](./LICENSE)).
The components below are third-party works bundled in, or loaded by, this
repository under their own licenses; the MIT grant does **not** apply to them.

- **Shipped** = included in the deployed web build (`docs/` → `gh-pages`).
- **Runtime CDN** = fetched from a third-party server at play time, not
  redistributed by us.

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

### General MIDI soundfonts — `docs/music/soundfonts/{0240,0320,0750}_JCLive_sf2_file.js`
- **Format/loader:** webaudiofont (<https://github.com/surikov/webaudiofont>).
- **Sample data:** "JCLive" GM soundfont (GM 24 nylon guitar, 32 acoustic bass,
  75 pan flute — the three instruments the arrangement uses).
- ⚠️ **License indeterminate** — no affirmative redistribution grant could be
  found for the JCLive sample data in any primary source.
- **TODO (before any release):** replace these three instruments with a
  clearly-licensed soundfont — e.g. **FluidR3** (MIT; ship its attribution here)
  or **GeneralUser GS v2.0** (permissive, no attribution) — then delete the
  JCLive files.

## Loaded at runtime from a CDN (not redistributed by us)

Fetched by `docs/music/paramo-music.js` from `strudel.b-cdn.net` at play time, so
the current build does not redistribute their bytes.

### uzu-drumkit
- **License:** The Unlicense (public domain). Safe to use; may be vendored freely.
- **Source:** <https://github.com/tidalcycles/uzu-drumkit>

### tidal-drum-machines (incl. the `AkaiMPC60` bank used by the bombo)
- **License:** No license granted (all rights reserved). Hot-linked only.
- ⚠️ **Do NOT vendor** into `docs/` — that would redistribute unlicensed,
  trademark-laden samples ("Akai"/"MPC" are inMusic trademarks). Replace the
  AkaiMPC60 bombo with a clearly-licensed source before vendoring or any sale.
- **Source:** <https://github.com/ritchse/tidal-drum-machines>

## Development-only (not shipped)

The `music/` score→Strudel converter uses `@strudel/core` and `@strudel/mini`
(AGPL-3.0-or-later) and `fraction.js` (MIT) as dev dependencies. They live in a
git-ignored `node_modules/` and never enter the build.
