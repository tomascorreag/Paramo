# music/ — score → Strudel pipeline

Convert public-domain sheet music into [Strudel](https://strudel.cc) REPL code
with **pitch and rhythm faithful to the source** (no transcription by ear or by
eyeballing a PDF). Built for three Andean folk songs (Ojos Azules, El Cóndor
Pasa, Carnavalito) but works on any score.

## Pipeline

```
source ─► music21 ─► xml_to_strudel.py ─► <song>.strudel.js   (paste into strudel.cc)
  ▲ MusicXML ≫ MIDI ≫ ABC   (MusicXML = exact rhythm; MIDI = ambiguous rhythm)
  └ PDF/image ─► Audiveris (OMR) ─► MusicXML   (fallback when no data source exists)
```

`xml_to_strudel.py` maps **1 measure → 1 Strudel cycle** and emits every note as
`pitch@quarterLength`, so durations come straight from the score. Tempo →
`setcpm(bpm / beatsPerBar)`. Each part becomes its own `note(...)` layer in a
`stack(...)`.

## Provenance (all official sources, verified)

| Component | Source | Verification |
|---|---|---|
| music21 10.5.0 | PyPI (`pip`) | home-page → github.com/cuthbertLab/music21 |
| @strudel/core, @strudel/mini 1.1.0 | npm | repo → github.com/tidalcycles/strudel |
| Audiveris 5.10.2 | github.com/Audiveris/audiveris releases | MSI SHA-256 == published asset digest `459a9c6b…3e4b` |

Strudel is pinned to **1.1.0**: 1.2.x has a broken `@kabelsalat/web` transitive
dep that crashes headless `node` use (it still works in the browser REPL).

## One-time setup

Python venv (music21) and node deps (headless Strudel verification) are
git-ignored — recreate them:

```bash
cd music

# 1. Python venv + music21
python -m venv .venv
./.venv/Scripts/python.exe -m pip install music21        # Windows
# source .venv/bin/activate && pip install music21       # macOS/Linux

# 2. Node deps (only needed to verify output parses)
npm install @strudel/core@1.1.0 @strudel/mini@1.1.0

# 3. Audiveris (only needed for the PDF/OMR fallback) — NEEDS ADMIN.
#    The MSI writes an HKLM registry key, so it must be installed elevated.
#    Double-click music/audiveris-console.msi and approve UAC, or run elevated:
#      powershell Start-Process msiexec -ArgumentList '/i','music\audiveris-console.msi' -Verb RunAs
#    Installs to: %LocalAppData%\Programs\Audiveris\Audiveris.exe
```

## Usage

```bash
# MusicXML / MIDI / ABC -> Strudel
./.venv/Scripts/python.exe xml_to_strudel.py sources/song.musicxml song.strudel.js --title "Song Name"

# MIDI is auto-quantized to an 1/8+triplet grid; disable with --no-quantize.
# Self-test on a bundled corpus score (no external file needed):
./.venv/Scripts/python.exe xml_to_strudel.py --corpus bach/bwv66.6 selftest.js

# PDF -> MusicXML via Audiveris OMR, then convert:
"%LocalAppData%\Programs\Audiveris\Audiveris.exe" -batch -export -output sources -- sources/song.pdf
./.venv/Scripts/python.exe xml_to_strudel.py sources/song.mxl song.strudel.js --title "Song Name"

# Verify the generated pattern actually parses + times correctly (headless):
node verify.mjs "$(node -e "const t=require('fs').readFileSync('song.strudel.js','utf8');console.log(t.match(/note\(\`([\s\S]*?)\`\)/)[1])")"
```

> **OMR is not push-button.** Audiveris output usually needs a proofreading pass
> (open the `.omr` in Audiveris' GUI, fix mis-read notes, re-export) before the
> MusicXML is truly faithful.

## Files

- `xml_to_strudel.py` — the converter (stdlib + music21).
- `verify.mjs` — headless Strudel parse/timing check (`@strudel/mini`).
- `sources/` — git-ignored; drop input scores (MusicXML/MIDI/PDF) here.
- `*.strudel.js` — generated outputs (committed).
