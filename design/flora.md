# Flora: the 20 species the game draws from

**Status: provisional, set 2026-08-25.** This is the working shortlist for vegetation art and journal content — not a commitment. The GDD talks about frailejones and vegetation generically; this file is the species-level layer under it, and it exists so that "which plant is this tile" has one answer instead of being re-decided per sprite.

## The list

Ordered as the reference PDF is ordered: structural dominants first, then shrubs, then rosettes/ground, then treeline.

| # | Species | Family | Growth form | Height | Common names (es-CO) | Range |
|---|---|---|---|---|---|---|
| 1 | *Calamagrostis effusa* | Poaceae | hierba macolla | 1 m | paja de paramo, paja, espartillo | CO, EC, VE |
| 2 | *Espeletia grandiflora* | Asteraceae | roseta caulescente | 3 m | frailejon | CO |
| 3 | *Espeletia barclayana* | Asteraceae | roseta caulescente | 2 m | frailejon motoso | CO |
| 4 | *Espeletia hartwegiana* | Asteraceae | roseta caulescente | 4 m | frailejon | CO |
| 5 | *Chusquea tessellata* | Poaceae | hierba bambusoide | 1.5 m | chusque, carrizo, chusquejon | CO, EC, VE |
| 6 | *Cortaderia nitida* | Poaceae | hierba macolla | 1 m | cortadera, carrizo, sixe, rabo de zorro | CO, EC, PE |
| 7 | *Hypericum juniperinum* | Hypericaceae | arbusto | 1 m | chite, guardarrocio, escobo | CO, VE |
| 8 | *Vaccinium floribundum* | Ericaceae | arbusto | 1 m | agraz, mortiño, reventadera, chivaco | Centroamerica → Argentina |
| 9 | *Pernettya prostrata* | Ericaceae | arbusto postrado | 1 m | reventadera, mortiño venenoso, chirriadera, borrachero | Guatemala → Peru |
| 10 | *Arcytophyllum nitidum* | Rubiaceae | arbusto | 1 m | piojo, sanalotodo, velito, gurrubu, venadillo | CO, VE |
| 11 | *Bejaria resinosa* | Ericaceae | arbusto | 1.5 m | pegamosco, pegapega, azalea del monte, carbonero | CO, EC, PE, VE |
| 12 | *Ageratina gracilis* | Asteraceae | arbusto | 1 m | amargoso, suica | CO, EC, VE |
| 13 | *Calea peruviana* | Asteraceae | arbusto | 1 m | cabezona, carrasposa, chicharron, carrasquillo | CO |
| 14 | *Puya goudotiana* | Bromeliaceae | roseta acaule | 2 m | cardon, puya | CO |
| 15 | *Blechnum loxense* | Blechnaceae | roseta caulescente | 1.5 m | (see note) | CO, BO, EC, PE, VE |
| 16 | *Plantago rigida* | Plantaginaceae | hierba en cojin | 0.5 m | — | CO → Bolivia |
| 17 | *Epidendrum fimbriatum* | Orchidaceae | hierba terrestre | 0.5 m | pajarito blanco | CO, BO, EC, PE, VE |
| 18 | *Elleanthus aurantiacus* | Orchidaceae | hierba terrestre | 0.4 m | — | Centroamerica → Bolivia |
| 19 | *Weinmannia rollottii* | Cunoniaceae | arbol | 12 m | encenillo, encenillo blanco, encenillo rosado | CO, EC, VE |
| 20 | *Escallonia myrtilloides* | Escalloniaceae | arbol | 5 m | rodamonte, tibar, chilco, sombrerito, cuasa, pagoda | Suramerica |

Common names are stripped of accents in the table above **on purpose** — see [Naming and localisation](#naming-and-localisation).

## Why these twenty

Selected for **ground cover and encounter frequency in Colombian paramo**, not for taxonomic representativeness. Two lines of evidence, and species were only kept where both agreed:

- **Community ecology.** Species that name or dominate a vegetation type: the *Calamagrostis effusa* pajonal (fragments to 7000 ha at Sumapaz), *Espeletia* frailejonales (often >40% plant cover), *Chusquea tessellata* chuscales (the most representative species of the humid Eastern-cordillera paramo and its largest biomass contributor), *Arcytophyllum nitidum* low shrubland (≥750 ha).
- **GBIF occurrence counts filtered to Colombia**, as a frequency-of-encounter proxy. This is what settled the two close calls: *Arcytophyllum nitidum* (4388) over *Diplostephium phylicoides* (2019), and *Epidendrum fimbriatum* (1724) + *Elleanthus aurantiacus* (1205) over the other 31 orchids in the source, including the far more famous *Masdevallia coccinea* (112).

**The GBIF proxy is biased and was never used alone.** It counts *collection events*, so it rewards species that grow near roads, near universities, and press easily. It agreed with the ecological literature everywhere it was consulted here; on a closer call it should not be trusted by itself.

Two species were considered and dropped: *Polylepis quadrijuga* (a third tree was over-weighting the treeline) and *Diplostephium phylicoides* (component species, not a community former).

## Growth-form composition

The source book's six chapters are a growth-form taxonomy, which is also very close to a sprite taxonomy — silhouette and height, not species identity.

| Growth form | Count | Source book | Note |
|---|---|---|---|
| Arbustos | 7 | 42% | on target |
| Hierbas (incl. 2 orchids) | 6 | 40% | under, and deliberately so |
| Rosetas caulescentes | 4 | 2.7% | heavily over-weighted, correctly |
| Arboles | 2 | 5.8% | on target |
| Rosetas acaules | 1 | 7.3% | on target |
| Bejucos | 0 | 2.3% | absent, see gaps |

**Rosetas caulescentes being 4/20 against the book's 2.7% is the point, not an error.** Chapter size measures taxonomic diversity; the game needs cover. Seven species of *Espeletia* in the book account for a plant group that can be 40% of what a hillside actually looks like.

The three *Espeletia* are a **height-and-silhouette ramp**, not three paint-overs of one plant: 2 m dense silver rosette (*barclayana*), 3 m broad classic (*grandiflora*), 4 m slender bare trunk (*hartwegiana*). They are also a geographic split — *grandiflora* is cordillera Oriental (Chingaza/Sumapaz, our setting), *hartwegiana* is Central. Frailejones are a textbook sky-island radiation, each massif with its own; a procedural run picking one signature *Espeletia* per mountain would be botanically honest and give each run a silhouette for free.

## Known gaps

Deliberate, and listed so they are not rediscovered as oversights:

- **No bejucos (vines).** The source gives them 6 pages of 259 because they are a *bosque altoandino* element that barely exists above treeline. *Mutisia clematis* is the candidate if one is ever wanted.
- **No invasives.** The source flags *Ulex europaeus* (retamo espinoso) and *Acacia decurrens* as **invasora**, and *Rumex acetosella* (sangretoro) as **potencial invasora**. These are fire-and-grazing indicators that colonise disturbed ground — they map directly onto the regrowth ledger in [../dev-notes/vegetation.md](../dev-notes/vegetation.md), where a burn scar regrowing as retamo instead of paja would be a legible and botanically real failure state. Left out of the *flora* list because they are a *threat* concern; add deliberately, not by drift.
- **No lycopods, no Gentianaceae, no small forbs.** Visual variety was traded for cover fidelity. The source has 7 Lycopodiaceae and 33 Orchidaceae; we took 2 orchids and no lycopods.

## Naming and localisation

- **Common names come from the source book**, which took them from Bernal et al. (2020). Most species have several; the table lists them in the book's order, which is the order of prevalence the book chose.
- **English common names mostly do not exist** for these species. `en_GB` copy should use the Spanish name as a loanword (frailejon, paramo) or the scientific name, not an invented translation.
- **Eggmode has no accented glyphs.** Anything drawn in the journal's title face must be accent-free, which hits this list hard: *frailejón, páramo, mortiño, cardón, chusquejón, guardarrocío, chicharrón, bichachá* all carry diacritics. Either author the accent-free form for Eggmode contexts, or keep flora names in Tiny5. See the localisation section of `CLAUDE.md` and [../dev-notes/journal.md](../dev-notes/journal.md).
- **Spanish runs ~25% longer than English and this project pins widgets to exact pixels.** Some of these common-name strings are long (*mortiño venenoso*, *azalea del monte*). Measure before putting one in a journal heading.

## Source and licence

**Marín, C. (Ed.). (2021). _Bitácora de flora. Guía visual de plantas de páramo._ Segunda edición.** Instituto de Investigación de Recursos Biológicos Alexander von Humboldt, Bogotá. 296 pp. ISBN 978-958-5183-00-1 (digital). Produced under the EU-funded *Páramos: Biodiversidad y Recursos Hídricos en los Andes del Norte* project.

**Licence: Creative Commons Attribution–NonCommercial–NoDerivatives.**

- The photographs **cannot ship in the game**, and pixel art traced from them would be a derivative work. Use them as reference for *what the plant looks like*, then draw originals.
- Species names, heights, distributions and common names are **facts** and are not covered by the licence.
- If any of this ever appears in-game as credited text, the attribution above is the one to use.

## The reference extract

A 20-page PDF of just these species, each page rotated upright, currently lives outside the repo at `Downloads/Paramo - 20 plantas comunes (Bitacora de flora).pdf`. **It is not committed** — it is a derivative of a NoDerivatives work and does not belong in a public repo.

To rebuild it from the source PDF, these are the page numbers, 0-indexed, in list order:

```
236, 254, 252, 255, 237, 238, 92, 81, 77, 132, 70, 35, 41, 267, 259, 235, 209, 206, 21, 24
```

**Most pages need rotating and the file does not say so.** Every page is physically portrait 396×612 pt with `/Rotate 0`; the sideways ones are sideways *in the content stream*, because the designer typeset landscape spreads onto portrait pages. The only signal is the writing direction of the text itself — PyMuPDF's per-line `dir` vector, **weighted by character count**, because every page carries a horizontal `[ Arbustos • 44 ]` footer that outvotes the body text on a per-line count.

| Dominant `dir` | `/Rotate` to apply |
|---|---|
| `(1, 0)` | 0 |
| `(0, 1)` | 270 |
| `(0, -1)` | 90 |

## Open questions

- **The source prints "Frailejón" as the common name of *Blechnum loxense*** (p. 260), and files it under Rosetas caulescentes beside the *Espeletia*. *Blechnum* is a fern. This is either a genuine editorial error in the book or real local usage for a caulescent fern rosette; it was **not** an extraction artifact — the string is on the page. Verify before putting that name in journal copy.
- Whether one *Espeletia* per procedural mountain (a per-run signature species) is worth the extra art over a single shared frailejón sprite.
