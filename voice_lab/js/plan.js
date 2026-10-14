// Text -> utterance plan, shared by every engine, so the three synths speak
// exactly the same phones, durations and pitch contour and only the
// synthesis differs.
//
//   buildPlan(text, lang, voice)  -> segments, syllables, phrases, typewriter events
//   buildFrames(plan, voice, opts) -> 5 ms control tracks (f0, voicing, formants, noise...)
//   miniPlan(syms, voice)          -> one isolated syllable (Godot bank mode)
(function () {
  "use strict";
  const { PHONES, LOCI, BURST, DUR, VOWELS, tokenize } = globalThis.VL;

  const FRAME_DT = 0.005;
  const LEAD_IN = 0.06;
  const TAIL = 0.12;

  // ---------------------------------------------------------------- helpers
  function hashStr(s) {
    let h = 2166136261 >>> 0;
    for (let i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul(h, 16777619) >>> 0;
    }
    return h >>> 0;
  }
  function mulberry32(a) {
    return function () {
      a = (a + 0x6D2B79F5) | 0;
      let t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  const clamp = (x, a, b) => (x < a ? a : x > b ? b : x);
  const lerp = (a, b, t) => a + (b - a) * t;
  const smooth = (t) => { t = clamp(t, 0, 1); return t * t * (3 - 2 * t); };
  const isVowel = (p) => p && p.cls === "vowel";
  const isSonorant = (p) => p && (p.cls === "vowel" || p.cls === "glide" || p.cls === "liquid");

  const CONSONANTS = {
    es: ["p", "b", "t", "d", "k", "g", "B", "D", "G", "f", "s", "x", "ch", "m", "n", "ny", "l", "r", "J"],
    en: ["p", "b", "t", "d", "k", "g", "f", "v", "th", "dh", "s", "z", "sh", "h", "ch", "jh", "m", "n", "l", "R", "w"],
  };

  // ---------------------------------------------------------------- syllables
  function syllabify(phones) {
    const nuclei = [];
    phones.forEach((ph, i) => { if (isVowel(PHONES[ph.sym])) nuclei.push(i); });
    if (nuclei.length === 0) return [[0, phones.length]];
    const bounds = [0];
    for (let k = 1; k < nuclei.length; k++) {
      const a = nuclei[k - 1], b = nuclei[k];
      const between = b - a - 1;
      let cut;
      if (between <= 1) cut = b - between;
      else {
        const c1 = PHONES[phones[b - 2].sym], c2 = PHONES[phones[b - 1].sym];
        const obstruentLiquid = (c1.cls === "stop" || c1.sym === "f" || c1.cls === "approx") &&
          (c2.sym === "l" || c2.sym === "r" || c2.sym === "R");
        const consGlide = c2.cls === "glide" && c1.cls !== "glide";
        cut = (obstruentLiquid || consGlide) ? b - 2 : b - 1;
      }
      bounds.push(cut);
    }
    const out = [];
    for (let k = 0; k < bounds.length; k++) {
      out.push([bounds[k], k + 1 < bounds.length ? bounds[k + 1] : phones.length]);
    }
    return out;
  }

  function stressIndex(word, sylls, lang) {
    const n = sylls.length;
    if (lang === "es") {
      for (let s = 0; s < n; s++) {
        for (let i = sylls[s][0]; i < sylls[s][1]; i++) if (word.phones[i].accent) return s;
      }
      if (n === 1) return 0;
      return "aeiouns".includes(word.lastLetter) ? n - 2 : n - 1;
    }
    const h = word.stressHint || { index: 0 };
    if (h.fromEnd !== undefined) return clamp(n - 1 - h.fromEnd, 0, n - 1);
    return clamp(h.index, 0, n - 1);
  }

  // Replaces phones with a random one of the same kind; seeded by the word so
  // a word always scrambles the same way.
  function scramble(word, amount, seed, lang) {
    if (amount <= 0) return word.phones;
    const rng = mulberry32(hashStr(word.text) ^ seed);
    return word.phones.map((ph) => {
      if (rng() >= amount) return ph;
      const p = PHONES[ph.sym];
      const pool = p.cls === "vowel" ? VOWELS[lang] : CONSONANTS[lang];
      return Object.assign({}, ph, { sym: pool[Math.floor(rng() * pool.length)] });
    });
  }

  // Word-final obstruents (stops, fricatives, taps...) are where releases into
  // silence click. "soften" marks them fully soft; "drop" removes them.
  const OBSTRUENT = new Set(["stop", "affric", "fric", "tap", "trill", "approx", "aspirate"]);
  function finalConsonants(phones, mode) {
    if (!mode || mode === "keep") return phones;
    let cut = phones.length;
    while (cut > 0 && OBSTRUENT.has(PHONES[phones[cut - 1].sym].cls)) cut--;
    if (cut === phones.length || cut === 0) return phones;
    if (mode === "drop") return phones.slice(0, cut);
    return phones.map((ph, i) => (i >= cut ? Object.assign({}, ph, { soft: true }) : ph));
  }

  // ---------------------------------------------------------------- plan
  function buildPlan(text, lang, v) {
    const seed = hashStr(String(v.seed));
    const tokens = tokenize(text, lang);

    // Group words into phrases at punctuation.
    const phrases = [];
    let cur = { words: [], type: "statement", pause: 0.3, punctCi: -1 };
    const close = (type, pause, ci) => {
      if (cur.words.length) {
        cur.type = type; cur.pause = pause; cur.punctCi = ci;
        phrases.push(cur);
      }
      cur = { words: [], type: "statement", pause: 0.3, punctCi: -1 };
    };
    for (const t of tokens) {
      if (t.type === "word") { cur.words.push(t); continue; }
      switch (t.ch) {
        case ",": case ";": case ":": case "-": case "—": close("continue", 0.14, t.ci); break;
        case ".": case "…": close("statement", 0.34, t.ci); break;
        case "!": close("exclaim", 0.34, t.ci); break;
        case "?": {
          const wh = lang === "es" ? cur.words.some((w) => w.wh) : (cur.words[0] && cur.words[0].wh);
          close(wh ? "wh" : "yesno", 0.36, t.ci);
          break;
        }
        case "¿": case "¡": close("continue", 0.14, -1); break;
      }
    }
    close("statement", 0.3, -1);

    const rngDur = mulberry32(seed ^ 0x9e3779b9);
    const segments = [];
    const syllables = [];
    const reveal = [];   // [time, revealCharCount]
    const words = [];
    let t = LEAD_IN;
    const speed = v.speed;

    phrases.forEach((ph, pi) => {
      ph.t0 = t;
      ph.syl0 = syllables.length;
      const lastWordIdx = ph.words.length - 1;
      ph.words.forEach((w, wi) => {
        const phones = finalConsonants(scramble(w, v.scramble, seed, lang), v.finalCons);
        const sylls = syllabify(phones);
        const lone = ph.words.length === 1;
        const stressed = (w.func && !lone) ? -1 : stressIndex(Object.assign({}, w, { phones }), sylls, lang);
        // English reduces unstressed short vowels to schwa: "banana" -> b ax n ae n ax.
        if (lang === "en" && sylls.length > 1) {
          sylls.forEach(([a, b], si) => {
            if (si === stressed) return;
            for (let i = a; i < b; i++) {
              if (["ae", "eh", "ah", "ao"].includes(phones[i].sym)) phones[i] = Object.assign({}, phones[i], { sym: "ax" });
            }
          });
        }
        const wordRec = { text: w.text, sylls: [], func: w.func };
        sylls.forEach(([a, b], si) => {
          const finalSyl = wi === lastWordIdx && si === sylls.length - 1;
          const syl = { i0: segments.length, t0: t, stressed: si === stressed, phrase: pi, final: finalSyl,
                        syms: [], key: "" };
          for (let i = a; i < b; i++) {
            const p = PHONES[phones[i].sym];
            // Speech-rhythm stretches; evenRhythm pulls them toward 1 (machine-even syllables).
            let mod = 1;
            if (p.cls === "vowel") {
              mod *= syl.stressed ? 1.25 : 0.8;
              if (w.func) mod *= 0.8;
            }
            if (finalSyl) mod *= p.cls === "vowel" ? 1.45 : 1.15;
            if (ph.type === "exclaim" && syl.stressed) mod *= 1.1;
            mod *= 1 + (rngDur() - 0.5) * 0.12;
            const soft = phones[i].soft ? 1 : v.softness;
            const consShorten = (p.cls === "vowel" || p.cls === "glide") ? 1 : lerp(1, 0.65, soft);
            const ms = DUR[p.cls] * Math.pow(mod, 1 - v.evenRhythm) * consShorten;
            const dur = ms / 1000 / speed;
            segments.push({ sym: p.sym, p, t0: t, dur, ci: phones[i].ci, phrase: pi, soft,
                            syl: syllables.length, stressed: syl.stressed, final: finalSyl });
            reveal.push([t, phones[i].ci + 1]);
            syl.syms.push(p.sym);
            t += dur;
          }
          syl.i1 = segments.length;
          syl.t1 = t;
          syl.key = syl.syms.join(" ");
          wordRec.sylls.push({ syms: syl.syms, stressed: syl.stressed });
          syllables.push(syl);
        });
        reveal.push([t, w.end]);
        words.push(wordRec);
        if (wi < lastWordIdx && v.wordGap > 0) {
          segments.push({ sym: "_", p: null, t0: t, dur: v.wordGap / 1000 / speed, phrase: pi, syl: -1 });
          t += v.wordGap / 1000 / speed;
        }
      });
      ph.syl1 = syllables.length;
      ph.t1 = t;
      if (ph.punctCi >= 0) reveal.push([t, ph.punctCi + 1]);
      const pause = (pi === phrases.length - 1 ? TAIL : ph.pause / Math.sqrt(speed));
      segments.push({ sym: "_", p: null, t0: t, dur: pause, phrase: pi, syl: -1 });
      t += pause;
    });

    // Nuclear (last stressed) syllable per phrase.
    for (const ph of phrases) {
      ph.nuclear = -1;
      for (let s = ph.syl1 - 1; s >= ph.syl0; s--) if (syllables[s].stressed) { ph.nuclear = s; break; }
      if (ph.nuclear < 0) ph.nuclear = ph.syl1 - 1;
    }

    return { lang, text, segments, syllables, phrases, words, reveal, duration: t };
  }

  // A plan holding one syllable on its own, for Godot bank mode.
  function miniPlan(syms, v) {
    const segments = [];
    let t = 0.02;
    for (const sym of syms) {
      const p = PHONES[sym];
      let ms = DUR[p.cls];
      const dur = ms / 1000 / v.speed;
      segments.push({ sym, p, t0: t, dur, phrase: 0, syl: 0, stressed: true, final: false });
      t += dur;
    }
    segments.push({ sym: "_", p: null, t0: t, dur: 0.04, phrase: 0, syl: -1 });
    t += 0.04;
    return {
      lang: v.lang, segments, duration: t, reveal: [],
      syllables: [{ i0: 0, i1: syms.length, t0: 0.02, t1: t - 0.04, stressed: true, phrase: 0, final: false }],
      phrases: [{ t0: 0.02, t1: t - 0.04, type: "statement", syl0: 0, syl1: 1, nuclear: 0 }],
    };
  }

  // ---------------------------------------------------------------- frames
  function neighbourVowel(segs, k) {
    for (let j = k + 1; j < segs.length && segs[j].p; j++) if (isVowel(segs[j].p)) return segs[j].p;
    for (let j = k - 1; j >= 0 && segs[j].p; j--) if (isVowel(segs[j].p)) return segs[j].p;
    return PHONES.ax;
  }

  function formantTarget(segs, k, scale) {
    let s = segs[k];
    if (!s.p) {
      // Pauses take the neighbouring target so nothing glides through silence.
      let j = k - 1;
      while (j >= 0 && !segs[j].p) j--;
      if (j < 0) { j = k + 1; while (j < segs.length && !segs[j].p) j++; }
      if (j < 0 || j >= segs.length) return [500 * scale, 1500 * scale, 2500 * scale];
      return formantTarget(segs, j, scale);
    }
    const p = s.p;
    let F;
    if (p.cls === "vowel" || p.cls === "glide" || p.cls === "liquid" || p.cls === "nasal") F = p.F;
    else {
      const nv = neighbourVowel(segs, k).F;
      const loc = p.place ? LOCI[p.place] : nv;
      F = [lerp(loc[0], nv[0], 0.5), lerp(loc[1], nv[1], 0.5), lerp(loc[2], nv[2], 0.5)];
    }
    return [F[0] * scale, F[1] * scale, F[2] * scale];
  }

  // Snap a semitone offset to a grid: "semitone" or a major pentatonic over the base.
  const PENTA = [0, 2, 4, 7, 9];
  function quantize(s, mode) {
    if (mode === "semitone") return Math.round(s);
    if (mode === "pentatonic") {
      const oct = Math.floor(s / 12);
      let best = 0, bestD = Infinity;
      for (const d of PENTA.concat(12)) {
        const c = oct * 12 + d;
        if (Math.abs(c - s) < bestD) { bestD = Math.abs(c - s); best = c; }
      }
      return best;
    }
    return s;
  }

  const FRIC_KIND ={ lab: 3, den: 3, alv: 1, post: 2, pal: 5, vel: 4 };

  function buildFrames(plan, v, opts) {
    opts = opts || {};
    const segs = plan.segments;
    const n = Math.ceil(plan.duration / FRAME_DT) + 1;
    const fr = {
      n, dt: FRAME_DT,
      f0: new Float32Array(n), voicing: new Float32Array(n), amp: new Float32Array(n),
      sylAmp: new Float32Array(n), F1: new Float32Array(n), F2: new Float32Array(n), F3: new Float32Array(n),
      B1: new Float32Array(n), B2: new Float32Array(n), B3: new Float32Array(n),
      asp: new Float32Array(n), fric: new Float32Array(n), fricF: new Float32Array(n),
      fricBW: new Float32Array(n), fricKind: new Int8Array(n), nasal: new Float32Array(n),
      burst: new Float32Array(n), burstF: new Float32Array(n), burstBW: new Float32Array(n),
      creak: new Float32Array(n), seg: new Int32Array(n), chop: new Float32Array(n),
    };
    const scale = v.formantScale;
    const fricScale = Math.sqrt(scale);
    const co = Math.max(0.005, v.coartic / 1000);
    const targets = segs.map((_, k) => formantTarget(segs, k, scale));
    const bw = [70 + 60 * v.breath, 100 + 60 * v.breath, 130 + 80 * v.breath];

    // ---- pitch contour (semitones above base), built per phrase
    const st = new Float32Array(n);
    if (!opts.monotone) {
      const rng = mulberry32(hashStr(String(v.seed)) ^ 0x51ed27);
      const ph1 = rng() * 6.28, ph2 = rng() * 6.28;
      for (let pi = 0; pi < plan.phrases.length; pi++) {
        const ph = plan.phrases[pi];
        const span = Math.max(0.05, ph.t1 - ph.t0);
        const exclaim = ph.type === "exclaim";
        const yesno = ph.type === "yesno";
        const accents = [];
        for (let s = ph.syl0; s < ph.syl1; s++) {
          const syl = plan.syllables[s];
          if (!syl.stressed) continue;
          let A = v.accentSt * (s === ph.nuclear ? 1.15 : 0.8);
          if (exclaim) A *= 1.6;
          if (ph.type === "wh" && s === ph.syl0) A *= 1.2;
          if (yesno && s === ph.nuclear) A = -0.4 * v.accentSt;   // low nuclear accent before the rise
          let c = (syl.t0 + syl.t1) / 2;
          for (let k = syl.i0; k < syl.i1; k++) if (isVowel(segs[k].p)) c = segs[k].t0 + segs[k].dur * 0.4;
          accents.push([c, Math.max(0.045, (syl.t1 - syl.t0) * 0.45), A]);
        }
        const lastSyl = plan.syllables[ph.syl1 - 1];
        const nuc = plan.syllables[ph.nuclear];
        const k0 = Math.max(0, Math.floor(ph.t0 / FRAME_DT));
        const k1 = Math.min(n - 1, Math.ceil(ph.t1 / FRAME_DT));
        for (let k = k0; k <= k1; k++) {
          const t = k * FRAME_DT;
          const u = clamp((t - ph.t0) / span, 0, 1);
          let s = v.declination * (0.6 - 1.6 * u);
          if (exclaim) s += 2;
          for (const [c, w, A] of accents) s += A * Math.exp(-0.5 * ((t - c) / w) ** 2);
          const lastU = smooth((t - lastSyl.t0) / Math.max(0.03, lastSyl.t1 - lastSyl.t0));
          switch (ph.type) {
            case "statement": s -= v.fallSt * lastU; break;
            case "wh": s -= v.fallSt * 1.2 * lastU; break;
            case "exclaim": s -= v.fallSt * 1.4 * lastU; break;
            case "continue": s += v.riseSt * 0.4 * lastU; break;
            case "yesno": {
              const nucC = (nuc.t0 + nuc.t1) / 2;
              s += v.riseSt * smooth((t - nucC) / Math.max(0.05, ph.t1 - nucC));
              break;
            }
          }
          s += v.wander * (0.6 * Math.sin(2 * Math.PI * 1.3 * t + ph1) + 0.4 * Math.sin(2 * Math.PI * 3.1 * t + ph2));
          st[k] = s;
          fr.creak[k] = v.creak * (u > 0.7 ? 1 : 0.25);
        }
      }
      // Hold pitch through pauses: carry the last phrase value forward.
      let last = 0;
      for (let k = 0; k < n; k++) {
        const t = k * FRAME_DT;
        const inPhrase = plan.phrases.some((ph) => t >= ph.t0 && t <= ph.t1);
        if (inPhrase) last = st[k]; else st[k] = last;
      }
      // Stepped pitch: one held note per syllable, sampled from the contour at the
      // vowel (at its end on a phrase-final syllable so a question's rise survives).
      if (v.flatPitch > 0) {
        for (const syl of plan.syllables) {
          let at = (syl.t0 + syl.t1) / 2;
          for (let q = syl.i0; q < syl.i1; q++) {
            const sg = segs[q];
            if (isVowel(sg.p)) at = sg.t0 + sg.dur * (syl.final ? 0.95 : 0.4);
          }
          const note = quantize(st[Math.min(n - 1, Math.round(at / FRAME_DT))], v.quantize);
          const k0 = Math.max(0, Math.floor(syl.t0 / FRAME_DT));
          const k1 = Math.min(n - 1, Math.floor(syl.t1 / FRAME_DT));
          for (let q = k0; q <= k1; q++) st[q] = lerp(st[q], note, v.flatPitch);
        }
      }
    } else {
      fr.creak.fill(v.creak * 0.25);
    }

    // ---- per-frame segment walk
    let k = 0;
    const lang = plan.lang;
    for (let f = 0; f < n; f++) {
      const t = f * FRAME_DT;
      while (k < segs.length - 1 && t >= segs[k].t0 + segs[k].dur) k++;
      const s = segs[k];
      const p = s.p;
      fr.seg[f] = k;
      fr.f0[f] = v.basePitch * Math.pow(2, st[f] / 12);

      // formants with coarticulation blends at both edges
      let F = targets[k];
      const t1 = s.t0 + s.dur;
      if (k > 0 && segs[k - 1].p && p && t < s.t0 + co / 2) {
        const w = 0.5 * (1 - smooth((t - s.t0) / (co / 2)));
        const P = targets[k - 1];
        F = [lerp(F[0], P[0], w), lerp(F[1], P[1], w), lerp(F[2], P[2], w)];
      }
      if (k + 1 < segs.length && segs[k + 1].p && p && t > t1 - co / 2) {
        const w = 0.5 * smooth((t - (t1 - co / 2)) / (co / 2));
        const N = targets[k + 1];
        F = [lerp(F[0], N[0], w), lerp(F[1], N[1], w), lerp(F[2], N[2], w)];
      }
      fr.F1[f] = F[0]; fr.F2[f] = F[1]; fr.F3[f] = F[2];
      fr.B1[f] = bw[0]; fr.B2[f] = bw[1]; fr.B3[f] = bw[2];

      if (!p || t < s.t0) { fr.voicing[f] = 0; fr.amp[f] = 0; fr.sylAmp[f] = 0; continue; }

      const syl = plan.syllables[s.syl];
      const ph = plan.phrases[s.phrase];
      let sylAmp = s.stressed ? 1 : 0.72;
      if (ph && ph.type === "exclaim") sylAmp *= 1.2;
      if (s.final && syl) sylAmp *= lerp(1, 0.7, smooth((t - syl.t0) / Math.max(0.03, syl.t1 - syl.t0)));
      sylAmp = lerp(sylAmp, 1, v.evenRhythm);
      fr.sylAmp[f] = sylAmp;
      // Chop: a short silence at the end of every syllable, so syllables don't run together.
      if (syl && v.chop > 0 && t > syl.t1 - v.chop / 1000 / v.speed) {
        fr.chop[f] = 1; fr.voicing[f] = 0; fr.amp[f] = 0; fr.sylAmp[f] = 0;
        continue;
      }

      let voicing = 1, amp = 1, asp = 0, fric = 0;
      const local = t - s.t0;
      // Softness turns closures into voiced murmurs, shrinks bursts and hiss.
      const soft = s.soft !== undefined ? s.soft : v.softness;
      const placeKind = FRIC_KIND[p.place] || 3;
      const setFric = (band, g) => {
        fric = g * (1 - 0.7 * soft);
        fr.fricF[f] = band[0] * fricScale; fr.fricBW[f] = band[1] * fricScale; fr.fricKind[f] = placeKind;
      };
      switch (p.cls) {
        case "vowel": break;
        case "glide": amp = 0.8; break;
        case "liquid": amp = p.sym === "R" ? 0.7 : 0.65; break;
        case "nasal": amp = 0.55; fr.nasal[f] = 1; fr.B1[f] = 160; break;
        case "tap": amp = lerp(0.35, 0.7, soft); break;
        case "trill": amp = 0.35 + 0.45 * (0.5 + 0.5 * Math.cos(2 * Math.PI * 28 * local)) * (1 - soft) + 0.35 * soft; break;
        case "approx": amp = 0.6; setFric(p.fric, p.fric[2]); break;
        case "aspirate": voicing = 0; asp = 0.7; break;
        case "fric":
          if (p.voiced) { voicing = 0.5; amp = 0.45; } else { voicing = 0; }
          setFric(p.fric, p.fric[2]);
          break;
        case "stop":
        case "affric": {
          const relAt = p.cls === "stop" ? s.dur - Math.min(0.012, s.dur * 0.3) : s.dur * 0.45;
          if (local < relAt) {
            voicing = lerp(p.voiced ? (lang === "es" ? 0.3 : 0.12) : 0, 0.6, soft);
            amp = lerp(voicing ? 0.25 : 0, 0.55, soft);
            fr.F1[f] = lerp(200 * scale, fr.F1[f], soft);
          } else {
            voicing = lerp(p.voiced ? 0.5 : 0, 0.6, soft);
            amp = lerp(p.voiced ? 0.4 : 0, 0.6, soft);
            if (local - FRAME_DT < relAt && soft < 1) {
              const b = BURST[p.place];
              fr.burst[f] = b[2] * (1 - soft); fr.burstF[f] = b[0] * fricScale; fr.burstBW[f] = b[1] * fricScale;
            }
            if (p.cls === "affric") setFric(p.fric, p.fric[2]);
          }
          break;
        }
      }
      // Voice onset time after a voiceless stop or affricate.
      if (isSonorant(p) && k > 0) {
        const pv = segs[k - 1].p;
        if (pv && (pv.cls === "stop" || pv.cls === "affric") && !pv.voiced) {
          const vot = (lang === "es" ? 0.012 : (s.stressed ? 0.05 : 0.025)) / v.speed;
          if (local < vot) { voicing = soft; asp = 0.6 * (1 - soft); }
        }
      }
      fr.voicing[f] = voicing;
      fr.amp[f] = amp * sylAmp;
      fr.asp[f] = asp * sylAmp;
      fr.fric[f] = fric * sylAmp;
    }
    return fr;
  }

  Object.assign(globalThis.VL, { buildPlan, buildFrames, miniPlan, syllabify, hashStr, mulberry32, clamp, lerp, smooth, FRAME_DT });
})();
