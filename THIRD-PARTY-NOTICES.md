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

### Herbarium specimen photographs — `assets/photos/flora/*_dry.jpg`
- **License:** Creative Commons Zero v1.0 Universal (`CC0-1.0`) — public domain
  dedication. **No attribution is legally owed**; the provenance below is
  recorded because a field-log plate should be traceable to a real voucher, and
  because CC0 status is a claim this project has to be able to defend.
- **Verified at the media level, not the record level.** GBIF's
  `license=CC0_1_0` filter describes the *occurrence record*, and the attached
  photograph carries its own, different licence field — for *Hypericum
  juniperinum*, 27 of 31 images on CC0-flagged records are in fact CC BY 4.0.
  Every file below was checked against `media[].license`.
- **Source:** GBIF (<https://www.gbif.org>), re-fetchable via
  `scripts/tools/fetch_flora_photos.py`. Full per-image record, collector,
  locality and date in `flora_photos/manifest.csv` (gitignored review folder).
- Images are downscaled to 1024 px on the long edge and imported lossy
  (`compress/mode=1`); at the project's default Lossless they cost 3.96 MB
  against a 1.64 MB `index.pck`.

| File | Species | Holder | Collector | Voucher locality |
|---|---|---|---|---|
| `frailejon_dry.jpg` | *Espeletia grandiflora* | Smithsonian NMNH (US) | S. Díaz Píedrahíta, A. M. Cleef, O. Rangel & S. Salamanca, 1981 | Macizo de Sumapáz; Cuchilla La Rabona |
| `espeletia_hartwegiana_dry.jpg` | *Espeletia hartwegiana* | Smithsonian NMNH (US) | J. Betancur & S. Churchill, 1991 | Cauca-Huila, Municipio Coconuco-San Agustin:… |
| `espeletia_barclayana_dry.jpg` | *Espeletia barclayana* | Smithsonian NMNH (US) | J. Cuatrecasas & R. Jaramillo M., 1978 | Páramo de Gorgua o Guargua. Páramo de Gorgua… |
| `calamagrostis_dry.jpg` | *Calamagrostis effusa* | Naturalis Biodiversity Center | Naturalis Biodiversity Center, 1989 | Colombia, Risaralda, parque Los Nevados, Loma… |
| `chusquea_dry.jpg` | *Chusquea tessellata* | Smithsonian NMNH (US) | B. G. Stergios & L. Zambrano, 1996 | Parque Nacional Guaramacal, Fila de Agua Fria |
| `cortaderia_dry.jpg` | *Cortaderia nitida* | Smithsonian NMNH (US) | S. Lægaard, 1998 | Along road to Fierro Urcu, surroundings of th… |
| `hypericum_dry.jpg` | *Hypericum juniperinum* | Smithsonian NMNH (US) | B. G. Stergios & R. Caracas, 2002 | Parque Nacional Guaramacal, páramo de Guaramacal |
| `arcytophyllum_dry.jpg` | *Arcytophyllum nitidum* | Smithsonian NMNH (US) | B. G. Stergios, L. J. Dorr & K. Wurdack, 2003 | Laguna Larga, Páramo de Motumbo, Monumento Na… |

Each row's GBIF occurrence URL is in the manifest; the eight are occurrences
1456073482, 1456428550, 1319586021, 2514999371, 1317906058, 3062057526,
1318331229 and 1320585531.

**No CC0 photograph of a living *Espeletia barclayana* exists** in either GBIF or
iNaturalist — the sole CC0 "live" record is a scientific line drawing, and the
only photographs of the living plant are CC BY 4.0 (29 observations) or
CC BY-NC. That species therefore has a dry plate and no live one; adding a live
one is a licensing decision, not a sourcing problem.

### Living-plant photographs — `assets/photos/flora/*_live.jpg`
- **License:** CC0 1.0, verified per-photo (iNaturalist licences each photo
  separately from its observation, so the observation-level field is not the
  answer). No attribution owed; credited below anyway.
- **Source:** iNaturalist (<https://www.inaturalist.org>) via
  `scripts/tools/fetch_flora_photos.py`.

| File | Species | Photographer | Where | When |
|---|---|---|---|---|
| `arcytophyllum_live.jpg` | *Arcytophyllum nitidum* | Andrew J. Crawford (crawfordaj) | Junin, Junin, Cundinamarca, CO | 2018-09-09 |
| `calamagrostis_live.jpg` | *Calamagrostis effusa* | bat (Maria Vorontsova) (vorontsovams) | Belén, Boyaca, Colombia | 2017-11-22 |
| `chusquea_live.jpg` | *Chusquea tessellata* | Alfredo F. Fuentes Claros (alfredo_f_fuentes) | Totoró, Puracé, CO-CA, CO | 2024-11-04 |
| `cortaderia_live.jpg` | *Cortaderia nitida* | Quentin Groom (qgroom) | Tihuaque, Usme, Bogotá, Bogota, Colombia | 2025-10-25 |
| `espeletia_hartwegiana_live.jpg` | *Espeletia hartwegiana* | Jean-Paul Boerekamps (jeanpaulboerekamps) | Villamaría, Caldas, CO | 2015-11-24 |
| `frailejon_live.jpg` | *Espeletia grandiflora* | rebecca bachman (r_a_b) | Horizontes-Las Moyas, Bogotá, Bogotá, CO | 2023-07-08 |
| `hypericum_live.jpg` | *Hypericum juniperinum* | Dimitri Brosens (dimitribrosens) | Choachí, Cundinamarca, Colombia | 2025-10-20 |

**`espeletia_barclayana` has no live plate.** No CC0 photograph of the living
plant exists in GBIF or iNaturalist: the species' only CC0 "live" record is a
scientific line drawing, and every actual photograph is CC BY 4.0 (29
observations) or CC BY-NC (65). Adding one means accepting a credit obligation,
which is a decision rather than a fetch. Its dry plate above is unaffected.

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
