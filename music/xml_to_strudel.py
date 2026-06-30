#!/usr/bin/env python
"""Convert a MusicXML / MIDI / ABC score (or a music21 corpus path) into a
Strudel REPL .js file, faithful to pitch + rhythm.

Meter-agnostic by design: notated barlines/time-signatures are IGNORED. Pitched
parts are `chordify`'d (collapsing chords + inner voices into one stream);
percussion (Unpitched) parts are read raw and mapped to drum hits. Every part is
flattened to a strictly sequential, non-overlapping timeline laid out by each
note's actual quarterLength, then padded to the score's total length. The whole
piece becomes ONE Strudel cycle whose tokens are weighted by duration
(`pitch@quarterLength`), so mixed meters (2/4 <-> 3/4) and cross-bar ties play
correctly regardless of how the source labels its bars, and all layers stay
aligned. Tempo: setcpm(bpm / total_quarters) => 1 quarter = bpm.

Usage:
    python xml_to_strudel.py <input> <out.js> [--bpm 72] [--title "Name"]
                                             [--labels "Flute,PianoRH,..."]
    python xml_to_strudel.py --corpus bach/bwv66.6 out.js
    # MIDI is auto-quantized (1/8 + triplet grid); --no-quantize to disable.

Lines in the output are grouped one-per-source-measure for readability only;
whitespace is insignificant to Strudel's mini-notation parser.

Overlapping notes (e.g. from OMR rhythm errors) are clipped to the next onset so
the stream stays monophonic-sequential; this honors onsets and shortens the
overlap, audible only where the source was already malformed.
"""
import sys
from fractions import Fraction
from functools import reduce
from math import gcd
import music21 as m21


def strudel_pitch(midi: int) -> str:
    p = m21.pitch.Pitch()
    p.midi = midi
    return p.nameWithOctave.replace('#', 's').replace('-', 'f').lower()


def frac(x) -> Fraction:
    """Exact Fraction from a music21 quarterLength/offset (Fraction or dyadic float)."""
    return x if isinstance(x, Fraction) else Fraction(x).limit_denominator(1000000)


def token_for(el) -> str:
    """Strudel token: '~' rest, note name, [c,e,g] chord, or 'bd' for unpitched."""
    if el.isRest:
        return '~'
    try:
        if isinstance(el, m21.chord.Chord):
            ps = el.pitches
            if len(ps) == 1:
                return strudel_pitch(ps[0].midi)
            return '[' + ','.join(strudel_pitch(p.midi) for p in ps) + ']'
        return strudel_pitch(el.pitch.midi)
    except Exception:           # unpitched (percussion)
        return 'bd'


def part_is_percussion(part) -> bool:
    perc_chord = getattr(m21, 'percussion', None)
    pc_cls = getattr(perc_chord, 'PercussionChord', ()) if perc_chord else ()
    for n in part.recurse().notes:
        if isinstance(n, m21.note.Unpitched) or (pc_cls and isinstance(n, pc_cls)):
            return True
    return False


def emit_part(part, total_ql: Fraction):
    """Return (lines, is_drum). `lines` is a list of measures, each a list of
    (token, Fraction weight) pairs: a strictly-sequential, gap-filled, exact
    timeline padded to total_ql. Weights are scaled to integers later, globally."""
    is_drum = part_is_percussion(part)
    src = part if is_drum else part.chordify()
    sounding = sorted(
        (e for e in src.flatten().notesAndRests
         if not e.isRest and frac(e.duration.quarterLength) > 0),
        key=lambda e: frac(e.offset))
    evs = [[frac(e.offset), frac(e.duration.quarterLength), token_for(e), e.measureNumber]
           for e in sounding]
    # clip overlaps to the next onset -> strictly sequential, sum == span
    for i in range(len(evs) - 1):
        end, nxt = evs[i][0] + evs[i][1], evs[i + 1][0]
        if nxt < end:
            evs[i][1] = max(Fraction(0), nxt - evs[i][0])
    evs = [e for e in evs if e[1] > 0]

    lines, line, cur_meas, cursor = [], [], None, Fraction(0)
    for onset, ql, txt, mn in evs:
        if cur_meas is not None and mn != cur_meas and line:
            lines.append(line)
            line = []
        cur_meas = mn
        if onset > cursor:
            line.append(("~", onset - cursor))
        line.append((txt, ql))
        cursor = onset + ql
    if line:
        lines.append(line)
    if cursor < total_ql:
        lines.append([("~", total_ql - cursor)])
    return lines, is_drum


def main():
    args = sys.argv[1:]
    title, bpm, labels = "Score", 100.0, []
    for flag, conv in (("--title", str), ("--bpm", float), ("--labels", str)):
        if flag in args:
            i = args.index(flag)
            val = conv(args[i + 1])
            if flag == "--title": title = val
            elif flag == "--bpm": bpm = val
            else: labels = [s.strip() for s in val.split(",")]
            del args[i:i + 2]
    no_quant = "--no-quantize" in args
    if no_quant:
        args.remove("--no-quantize")

    if args and args[0] == "--corpus":
        src_path, score, out_path = args[1], m21.corpus.parse(args[1]), args[2]
    else:
        src_path, out_path = args[0], args[1]
        score = m21.converter.parse(src_path)

    if src_path.lower().endswith((".mid", ".midi")) and not no_quant:
        score.quantize(quarterLengthDivisors=(4, 3), inPlace=True,
                       processOffsets=True, processDurations=True)
    score = score.stripTies()

    parts = list(score.parts) if score.parts else [score]
    total_ql = max(frac(p.flatten().highestTime) for p in parts)

    # Emit every part to (lines of (token, Fraction)); then scale all weights to
    # integers via the global LCM of denominators -> exact, drift-free, aligned.
    emitted = [emit_part(p, total_ql) for p in parts]
    denoms = {w.denominator for lines, _ in emitted for line in lines for _, w in line}
    scale = reduce(lambda a, b: a * b // gcd(a, b), denoms, 1)
    # 1 cycle = whole piece = total_ql quarters; tempo: 1 quarter = bpm.
    cpm = float(bpm / float(total_ql)) if total_ql else 1.0

    def render(lines):
        out = []
        for line in lines:
            toks = [f"{t}@{int(w * scale)}" for t, w in line]
            out.append(" ".join(toks))
        return "\n  ".join(out)

    palette = ["triangle", "sawtooth", "square", "sine", "triangle"]
    lines = [
        f"// {title} -- generated from {src_path} by xml_to_strudel.py",
        f"// {len(parts)} part(s), bpm={bpm:g}, total={float(total_ql):g} quarters."
        " Meter-agnostic: notes laid by exact duration, whole piece = 1 cycle.",
        f"setcpm({cpm:.5g})",
        "",
    ]
    layer_names = []
    for idx, (plines, is_drum) in enumerate(emitted):
        label = labels[idx] if idx < len(labels) else f"part{idx + 1}"
        safe = "".join(c for c in label if c.isalnum() or c == "_") or f"part{idx + 1}"
        layer = f"p_{safe}"
        body = render(plines)
        gain = 0.9 if idx == 0 else 0.45
        layer_names.append(layer)
        lines.append(f"// {label}")
        if is_drum:
            lines.append(f"const {layer} = sound(`\n  {body}\n`).gain({gain}).room(0.2)")
        else:
            snd = palette[idx % len(palette)]
            lines.append(f"const {layer} = note(`\n  {body}\n`)")
            lines.append(f'  .sound("{snd}").gain({gain}).release(0.25).room(0.3)')
        lines.append("")
    lines.append("stack(\n  " + ",\n  ".join(layer_names) + "\n)")

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print(f"wrote {out_path}: {len(parts)} part(s), bpm={bpm:g}, "
          f"total={total_ql:g}q, cpm={cpm:.5g}")


if __name__ == "__main__":
    main()
