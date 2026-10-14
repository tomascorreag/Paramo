// The three synthesis engines, each turning the same plan + 5 ms frames into
// a Float32Array at OUT_SR, plus the shared post chain and Godot bank mode.
//
//   cheap:  source-filter written here. A glottal pulse (or saw) through four
//           parallel band-pass formants, band-passed noise for frication and
//           bursts. Coefficients update every 32 samples. This is the one that
//           ports to GDScript line for line.
//   klatt:  KlattSyn (chdh, MIT): Klatt 1980 cascade/parallel formant synth
//           with a natural glottal source, driven frame by frame.
//   trombone: Pink Trombone (Neil Thapen, MIT; chdh's modular port): a
//           44-segment waveguide vocal tract. The plan becomes tongue
//           positions, constrictions, velum and glottis targets; the
//           coarticulation comes out of the tract physics.
(function () {
  "use strict";
  const VL = globalThis.VL;
  const { PHONES, PT_PLACE, clamp, lerp, mulberry32, hashStr, buildFrames, miniPlan } = VL;
  const OUT_SR = 44100;

  // ---------------------------------------------------------------- DSP bits
  // RBJ band-pass with a constant 0 dB peak.
  function makeBpf() { return { b0: 0, b2: 0, a1: 0, a2: 0, x1: 0, x2: 0, y1: 0, y2: 0 }; }
  function setBpf(f, freq, bw, sr) {
    freq = clamp(freq, 40, sr * 0.45);
    const q = Math.max(0.3, freq / Math.max(20, bw));
    const w0 = 2 * Math.PI * freq / sr;
    const alpha = Math.sin(w0) / (2 * q);
    const a0 = 1 + alpha;
    f.b0 = alpha / a0; f.b2 = -alpha / a0; f.a1 = -2 * Math.cos(w0) / a0; f.a2 = (1 - alpha) / a0;
  }
  function runBpf(f, x) {
    const y = f.b0 * x + f.b2 * f.x2 - f.a1 * f.y1 - f.a2 * f.y2;
    f.x2 = f.x1; f.x1 = x; f.y2 = f.y1; f.y1 = y;
    return y;
  }
  function biquad(type, freq, q, gainDb, sr) {
    const w0 = 2 * Math.PI * freq / sr, cw = Math.cos(w0), sw = Math.sin(w0);
    const alpha = sw / (2 * q);
    const A = Math.pow(10, (gainDb || 0) / 40);
    let b0, b1, b2, a0, a1, a2;
    if (type === "hp") { b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = b0; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha; }
    else if (type === "lp") { b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = b0; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha; }
    else { b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A; a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A; }
    let x1 = 0, x2 = 0, y1 = 0, y2 = 0;
    return (x) => {
      const y = (b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0;
      x2 = x1; x1 = x; y2 = y1; y1 = y;
      return y;
    };
  }
  function resample(input, ratio) {
    // ratio > 1 plays faster (shorter, higher), like AudioStreamPlayer.pitch_scale.
    const outLen = Math.max(1, Math.floor((input.length - 1) / ratio));
    const out = new Float32Array(outLen);
    for (let i = 0; i < outLen; i++) {
      const x = i * ratio, j = Math.floor(x), a = x - j;
      out[i] = input[j] * (1 - a) + (input[j + 1] || 0) * a;
    }
    return out;
  }
  const interp = (arr, fp) => {
    const i = Math.floor(fp), a = fp - i;
    const n = arr.length - 1;
    if (i >= n) return arr[n];
    return arr[i] * (1 - a) + arr[i + 1] * a;
  };
  const db = (lin) => (lin <= 1e-5 ? -99 : 20 * Math.log10(lin));

  // ---------------------------------------------------------------- cheap
  function renderCheap(plan, fr, v) {
    const sr = OUT_SR;
    const len = Math.ceil(plan.duration * sr);
    const out = new Float32Array(len);
    const rng = mulberry32(hashStr(String(v.seed)) ^ 0xc4ea9);
    const noise = () => rng() * 2 - 1;
    const formants = [makeBpf(), makeBpf(), makeBpf(), makeBpf()];
    const fricF = makeBpf(), burstF = makeBpf();
    const scale = v.formantScale;
    const gains = [1.0, -0.8, 0.5, -0.3];
    const BLOCK = 32;
    const oq = lerp(0.4, 0.75, 1 - v.tense);
    const tp = oq * 0.6;
    const tiltA = lerp(0.2, 0.85, v.tense);
    let phase = 0, prevFlow = 0, tilt = 0;
    let periodF0 = v.basePitch, periodAmp = 1, creakOn = false;
    let burstEnv = 0, nasal = 0, lastBurstFrame = -1, f1Gain = 1;
    const burstDecay = Math.exp(-1 / (0.006 * sr));
    for (let i0 = 0; i0 < len; i0 += BLOCK) {
      const fp = (i0 / sr) / fr.dt;
      const fi = Math.min(fr.n - 1, Math.round(fp));
      setBpf(formants[0], interp(fr.F1, fp), interp(fr.B1, fp), sr);
      setBpf(formants[1], interp(fr.F2, fp), interp(fr.B2, fp), sr);
      setBpf(formants[2], interp(fr.F3, fp), interp(fr.B3, fp), sr);
      setBpf(formants[3], 3300 * scale, 250, sr);
      nasal = interp(fr.nasal, fp);
      // A parallel band-pass passes the source level at F1, and the source falls with
      // frequency, so low-F1 vowels and nasals would be the loudest. Open vowels are, in speech.
      f1Gain = Math.pow(clamp(interp(fr.F1, fp) / (500 * scale), 0.3, 1.6), 1.5) * (1 - 0.45 * nasal);
      if (fr.fric[fi] > 0) setBpf(fricF, fr.fricF[fi], fr.fricBW[fi], sr);
      const fb = Math.floor(fp);
      for (let f = Math.max(lastBurstFrame + 1, fb - 1); f <= fb + 1 && f < fr.n; f++) {
        if (fr.burst[f] > 0 && f * fr.dt <= (i0 + BLOCK) / sr) {
          burstEnv = fr.burst[f]; setBpf(burstF, fr.burstF[f], fr.burstBW[f], sr); lastBurstFrame = f;
        }
      }
      const end = Math.min(len, i0 + BLOCK);
      for (let i = i0; i < end; i++) {
        const t = i / sr;
        const p = t / fr.dt;
        const voicing = interp(fr.voicing, p);
        const amp = interp(fr.amp, p);
        const asp = interp(fr.asp, p);
        const fric = interp(fr.fric, p);
        // glottal source
        phase += periodF0 / sr;
        if (phase >= 1) {
          phase -= 1;
          const vib = 1 + (v.vibDepth / 100) * Math.sin(2 * Math.PI * v.vibRate * t);
          const creak = interp(fr.creak, p);
          creakOn = rng() < creak * 0.5 ? !creakOn : false;
          periodF0 = interp(fr.f0, p) * vib * (1 + (v.jitter / 100) * noise()) * (creakOn ? 0.55 : 1);
          periodAmp = 1 + (v.shimmer / 100) * noise() - (creakOn ? 0.35 : 0);
        }
        let src;
        if (v.cheapSource === "saw") {
          src = (2 * phase - 1) * 0.5;
        } else if (v.cheapSource === "pulse") {
          const w = 0.18;
          src = ((phase < w ? 0.5 - 0.5 * Math.cos(2 * Math.PI * phase / w) : 0) - w / 2) * 1.2;
        } else {
          let flow;
          if (phase < tp) flow = 0.5 * (1 - Math.cos(Math.PI * phase / tp));
          else if (phase < oq) flow = Math.cos(0.5 * Math.PI * (phase - tp) / (oq - tp));
          else flow = 0;
          src = (flow - prevFlow) * (sr / periodF0) * 0.12;
          prevFlow = flow;
        }
        tilt += tiltA * (src - tilt);
        const breath = noise() * v.breath * 0.5 * (phase < oq ? 1 : 0.3);
        const excite = (tilt * periodAmp + breath) * voicing * amp + noise() * asp * 0.5;
        let y = 0;
        for (let k = 0; k < 4; k++) {
          const g = k === 0 ? gains[0] * f1Gain : gains[k] * (1 - 0.6 * nasal);
          y += g * runBpf(formants[k], excite);
        }
        if (fric > 0) y += runBpf(fricF, noise()) * fric * 0.25;
        if (burstEnv > 1e-3) { y += runBpf(burstF, noise()) * burstEnv * 0.4; burstEnv *= burstDecay; }
        out[i] = y;
      }
    }
    return out;
  }

  // ---------------------------------------------------------------- Klatt
  // Frication patterns: which parallel formants the noise excites, by place.
  const KLATT_FRIC_DB = {
    1: [-99, -99, -99, -99, -12, 0],   // alveolar (s z), F6 moved to the noise centre
    2: [-99, -99, 0, -8, -99, -6],     // postalveolar (sh ch)
    3: [-99, -99, -99, -99, -99, -10], // labiodental / dental: mostly bypass (flat)
    4: [-99, -4, 0, -99, -99, -99],    // velar (x, k bursts)
    5: [-99, -99, 0, -6, -99, -10],    // palatal
  };
  function renderKlatt(plan, fr, v) {
    const rng = mulberry32(hashStr(String(v.seed)) ^ 0x4b1a77);
    const scale = v.formantScale;
    const frames = [];
    const tiltDb = (1 - v.tense) * 18;
    const opr = lerp(0.4, 0.8, 1 - v.tense);
    const breathDb = lerp(-45, -8, v.breath);
    let burstHold = 0, burstKind = 0, burstF = 0, burstBW = 0;
    for (let f = 0; f < fr.n; f++) {
      const t = f * fr.dt;
      const vib = 1 + (v.vibDepth / 100) * Math.sin(2 * Math.PI * v.vibRate * t);
      const creak = fr.creak[f] > 0 && rng() < fr.creak[f] * 0.5;
      const shim = 1 + (v.shimmer / 100) * (rng() * 2 - 1) - (creak ? 0.35 : 0);
      const nasal = fr.nasal[f] > 0.5;
      if (fr.burst[f] > 0) {
        burstHold = fr.burst[f];
        burstF = fr.burstF[f]; burstBW = fr.burstBW[f];
        burstKind = burstF < 1500 * Math.sqrt(scale) ? 3 : burstF < 2500 * Math.sqrt(scale) ? 4 : burstF < 3500 * Math.sqrt(scale) ? 2 : 1;
      }
      const fric = fr.fric[f];
      const noiseOn = fric > 0 || burstHold > 0.01;
      const kind = fric > 0 ? fr.fricKind[f] : burstKind;
      const nf = fric > 0 ? fr.fricF[f] : burstF;
      const nbw = fric > 0 ? fr.fricBW[f] : burstBW;
      const oralF = [fr.F1[f], fr.F2[f], fr.F3[f], 3300 * scale, 3750 * scale, 4900 * scale];
      const oralBw = [fr.B1[f], fr.B2[f], fr.B3[f], 250, 200, 1000];
      if (noiseOn && (kind === 1 || kind === 3)) { oralF[5] = nf; oralBw[5] = nbw; }
      const fricLin = fric * 1.0 + burstHold * 0.5;
      frames.push({
        duration: fr.dt,
        f0: Math.max(30, fr.f0[f] * vib * (creak ? 0.55 : 1)),
        flutterLevel: v.jitter / 6,
        openPhaseRatio: opr,
        breathinessDb: breathDb,
        tiltDb,
        gainDb: 0,
        agcRmsLevel: 0,
        nasalFormantFreq: nasal ? 270 * scale : NaN,
        nasalFormantBw: nasal ? 100 : NaN,
        oralFormantFreq: oralF,
        oralFormantBw: oralBw,
        cascadeEnabled: true,
        cascadeVoicingDb: db(fr.voicing[f] * fr.amp[f] * shim),
        cascadeAspirationDb: db(fr.asp[f] * 0.35 + fr.voicing[f] * fr.amp[f] * v.breath * 0.08),
        cascadeAspirationMod: 0.5,
        nasalAntiformantFreq: nasal ? 450 * scale : NaN,
        nasalAntiformantBw: nasal ? 100 : NaN,
        parallelEnabled: noiseOn,
        parallelVoicingDb: -99,
        parallelAspirationDb: -99,
        parallelAspirationMod: 0,
        fricationDb: noiseOn ? db(fricLin) + v.klattFricDb : -99,
        fricationMod: fr.voicing[f] > 0 ? 0.5 : 0,
        parallelBypassDb: noiseOn && kind === 3 ? -6 : -99,
        nasalFormantDb: NaN,
        oralFormantDb: noiseOn ? KLATT_FRIC_DB[kind] || KLATT_FRIC_DB[3] : [-99, -99, -99, -99, -99, -99],
      });
      burstHold *= 0.35;
    }
    const out64 = globalThis.VoiceLabVendor.generateKlatt({ sampleRate: OUT_SR, glottalSourceType: 1 }, frames);
    return Float32Array.from(out64);
  }

  // ---------------------------------------------------------------- tract-lite
  // Pink Trombone's control layer (Glottis + TractShaper, unchanged) over a much
  // smaller waveguide: `segs` sections (default 11) stepped ONCE per output sample,
  // no nose tube. Pink Trombone runs 44 sections twice per sample; a tube's first
  // resonance is about rate / (4 * sections), so 11 sections at 22.05 kHz is the
  // same acoustic length as 44 at 2 x 48 kHz, for about 1/8 of the work.
  // The shaper still drives 44 control points; they are averaged (as areas) down
  // to `segs` once per block. Nasals: the velum opening mixes in a low-passed
  // copy of the glottal source (a murmur) and damps the oral output.
  class LiteTract {
    constructor(glottis, rate, segs, damping) {
      this.n = 44; this.bladeStart = 10; this.tipStart = 32; this.lipStart = 39;
      this.noseLength = 28; this.noseStart = 44 - 28 + 1;
      this.glottis = glottis; this.rate = rate; this.m = segs; this.damping = damping;
      this.diameter = new Float64Array(44); this.noseDiameter = new Float64Array(28);
      this.transients = []; this.turbulencePoints = [];
      this.time = 0; this.sampleCount = 0;
      this.R = new Float64Array(segs); this.L = new Float64Array(segs);
      this.jR = new Float64Array(segs); this.jL = new Float64Array(segs + 1);
      this.refl = new Float64Array(segs); this.newRefl = new Float64Array(segs);
      this.fricF = makeBpf(); setBpf(this.fricF, 1000, 2000, rate);
      this.murmur = 0;
      this.murmurA = 1 - Math.exp(-2 * Math.PI * 250 / rate);
      this.nasal = 0;
    }
    calculateNoseReflections() {}
    calculateNewBlockParameters() {
      const m = this.m, per = 44 / m;
      const area = new Float64Array(m);
      for (let k = 0; k < m; k++) {
        let a = 0, c = 0;
        for (let i = Math.floor(k * per); i < Math.floor((k + 1) * per) && i < 44; i++) { a += this.diameter[i] ** 2; c++; }
        area[k] = c ? a / c : 0;
      }
      this.refl.set(this.newRefl);
      for (let k = 1; k < m; k++) {
        this.newRefl[k] = area[k] === 0 ? 0.999 : (area[k - 1] - area[k]) / (area[k - 1] + area[k]);
      }
      this.nasal = clamp((this.noseDiameter[0] - 0.01) / 0.39, 0, 1);
    }
    step(g, lambda) {
      const m = this.m, R = this.R, L = this.L, jR = this.jR, jL = this.jL;
      this.processTransients();
      this.addTurbulence();
      jR[0] = L[0] * 0.75 + g;
      jL[m] = R[m - 1] * -0.85;
      for (let k = 1; k < m; k++) {
        const r = this.refl[k] * (1 - lambda) + this.newRefl[k] * lambda;
        const w = r * (R[k - 1] + L[k]);
        jR[k] = R[k - 1] - w;
        jL[k] = L[k] + w;
      }
      const d = this.damping;
      for (let k = 0; k < m; k++) { R[k] = jR[k] * d; L[k] = jL[k + 1] * d; }
      this.murmur += this.murmurA * (g - this.murmur);
      this.sampleCount++;
      this.time = this.sampleCount / this.rate;
      return R[m - 1] * (1 - 0.6 * this.nasal) + this.murmur * this.nasal * 0.8;
    }
    seg(pos44) { return clamp(Math.round(pos44 * this.m / 44), 1, this.m - 1); }
    processTransients() {
      for (let i = this.transients.length - 1; i >= 0; i--) {
        const t = this.transients[i];
        const age = this.time - t.startTime;
        if (age > t.lifeTime) { this.transients.splice(i, 1); continue; }
        const amp = t.strength * Math.pow(2, -t.exponent * age);
        const k = this.seg(t.position);
        this.R[k] += amp / 2; this.L[k] += amp / 2;
      }
    }
    addTurbulence() {
      for (const p of this.turbulencePoints) {
        if (p.diameter <= 0) continue;
        const att = 0.1;
        const inten = isNaN(p.endTime) ? clamp((this.time - p.startTime) / att, 0, 1) : clamp(1 - (this.time - p.endTime) / att, 0, 1);
        if (inten <= 0) continue;
        const thin = clamp(8 * (0.7 - p.diameter), 0, 1), open = clamp(30 * (p.diameter - 0.3), 0, 1);
        const nz = 0.66 * runBpf(this.fricF, Math.random() * 2 - 1) * inten * this.glottis.getNoiseModulator() * thin * open;
        const k = this.seg(p.position);
        this.R[k] += nz / 2; this.L[k] += nz / 2;
      }
    }
  }

  class LiteSynth {
    constructor(rate, v) {
      const V = globalThis.VoiceLabVendor;
      this.sampleRate = rate;
      this.glottis = new V.PinkTromboneGlottis(rate);
      // Sections follow the synth rate so the tube keeps its length: liteSegs is the
      // count at 22.05 kHz (11 = Pink Trombone's length), 8 at 16 kHz.
      const segs = Math.max(4, Math.round(v.liteSegs * (v.liteRate || 22050) / 22050));
      this.tract = new LiteTract(this.glottis, rate, segs, v.liteDamping);
      this.tractShaper = new V.PinkTromboneTractShaper(this.tract);
    }
    synthesize(buf) {
      const n = buf.length;
      const dt = n / this.sampleRate;
      this.glottis.adjustParameters(dt);
      this.tractShaper.adjustTractShape(dt);
      this.tract.calculateNewBlockParameters();
      for (let i = 0; i < n; i++) {
        const lambda = i / n;
        buf[i] = this.tract.step(this.glottis.step(lambda), lambda) * 0.25;
      }
    }
  }

  // ---------------------------------------------------------------- vowel blips
  // The simplest thing that still follows the text: one blip per syllable.
  // A soft pulse at the syllable's (stepped) pitch through the vowel's F1/F2,
  // an attack/decay envelope, and a short noise tick for an obstruent onset.
  // No coarticulation, no consonant articulation: Animalese with real vowels.
  function renderBlips(plan, fr, v) {
    const sr = OUT_SR;
    const out = new Float32Array(Math.ceil(plan.duration * sr));
    const rng = mulberry32(hashStr(String(v.seed)) ^ 0xb1195);
    const f1 = makeBpf(), f2 = makeBpf(), tick = makeBpf();
    for (const syl of plan.syllables) {
      let vow = null, vt0 = syl.t0, vdur = syl.t1 - syl.t0;
      for (let k = syl.i0; k < syl.i1; k++) {
        const sg = plan.segments[k];
        if (sg.p.cls === "vowel") { vow = sg.p; vt0 = sg.t0; vdur = sg.dur; break; }
      }
      if (!vow) continue;
      const onset = plan.segments[syl.i0].p;
      const fi = Math.min(fr.n - 1, Math.round((vt0 + vdur * 0.4) / fr.dt));
      const f0 = fr.f0[fi];
      const gain = fr.sylAmp[fi] || 1;
      setBpf(f1, vow.F[0] * v.formantScale, 90, sr);
      setBpf(f2, vow.F[1] * v.formantScale, 130, sr);
      // onset tick
      if (onset && onset !== vow && (onset.cls === "stop" || onset.cls === "fric" || onset.cls === "affric")) {
        const band = onset.fric || BURST_FALLBACK[onset.place] || [3000, 2000];
        setBpf(tick, band[0] * Math.sqrt(v.formantScale), band[1], sr);
        const len = Math.round(0.018 * sr * (1 - 0.5 * v.softness));
        const s0 = Math.round(syl.t0 * sr);
        for (let i = 0; i < len && s0 + i < out.length; i++) {
          out[s0 + i] += runBpf(tick, rng() * 2 - 1) * 0.35 * (1 - v.softness * 0.7) * (1 - i / len);
        }
      }
      // vowel blip
      const s0 = Math.round(vt0 * sr), len = Math.round(Math.max(0.05, Math.min(syl.t1 - vt0, vdur * 1.6)) * sr);
      const att = Math.round(0.006 * sr);
      let phase = 0;
      for (let i = 0; i < len && s0 + i < out.length; i++) {
        phase += f0 * (1 + (v.vibDepth / 100) * Math.sin(2 * Math.PI * v.vibRate * i / sr)) / sr;
        if (phase >= 1) phase -= 1;
        const w = 0.18;
        const src = (phase < w ? 0.5 - 0.5 * Math.cos(2 * Math.PI * phase / w) : 0) - w / 2;
        const env = (i < att ? i / att : 1) * Math.exp(-3 * i / len) * (1 - Math.pow(i / len, 8));
        out[s0 + i] += (runBpf(f1, src) + 0.7 * runBpf(f2, src)) * env * gain;
      }
    }
    return out;
  }
  const BURST_FALLBACK = { lab: [1100, 2200], den: [4500, 3000], alv: [4000, 2500], post: [3000, 1500], pal: [3200, 1500], vel: [2000, 900] };

  // ---------------------------------------------------------------- Pink Trombone
  // reduceTargetDiameters: lifted from pink-trombone-mod TractUi.reduceTargetDiametersByTouch (MIT).
  function reduceTarget(tract, shaper, index, diameter) {
    if (index < 2 || index >= tract.n || diameter >= 3) return;
    let width;
    if (index < 25) width = 10;
    else if (index >= tract.tipStart) width = 5;
    else width = 10 - 5 * (index - 25) / (tract.tipStart - 25);
    for (let i = -Math.ceil(width) - 1; i < width + 1; i++) {
      const p = Math.round(index) + i;
      if (p < 0 || p >= tract.n) continue;
      const relpos = Math.abs(p - index) - 0.5;
      let shrink;
      if (relpos <= 0) shrink = 0;
      else if (relpos > width) shrink = 1;
      else shrink = 0.5 * (1 - Math.cos(Math.PI * relpos / width));
      if (diameter < shaper.targetDiameter[p]) {
        shaper.targetDiameter[p] = diameter + (shaper.targetDiameter[p] - diameter) * shrink;
      }
    }
  }

  // `lite` swaps the 44-section waveguide for LiteTract; everything that drives it is shared.
  // Both scale formants by running the tract at rate x formantScale and resampling the
  // result (in Godot: just the AudioStreamWAV mix_rate).
  function renderTrombone(plan, fr, v, lite) {
    const R = lite ? Math.round(clamp((v.liteRate || 22050) * v.formantScale, 8000, 32000))
                   : Math.round(clamp(44100 * v.formantScale, 30000, 64000));
    const synth = lite ? new LiteSynth(R, v) : new globalThis.VoiceLabVendor.PinkTromboneSynthesizer(R);
    const { glottis, tract, tractShaper: shaper } = synth;
    glottis.isTouched = true;
    glottis.alwaysVoice = false;
    glottis.autoWobble = false;
    glottis.vibratoAmount = v.vibDepth / 100;
    glottis.vibratoFrequency = v.vibRate;
    let intensityTarget = 0;
    glottis.adjustIntensity = function () {
      const d = 0.3;
      this.intensity = this.intensity < intensityTarget ? Math.min(intensityTarget, this.intensity + d)
                                                        : Math.max(intensityTarget, this.intensity - d);
    };
    // Synthetic source: replace the LF glottal pulse with a plain wave. Saw and square are
    // band-limited with polyBLEP; the pulse is a narrow raised cosine (no edges to alias).
    const src = v.ptSource || "lf";
    if (src !== "lf") {
      const blep = (t, dt) => {
        if (t < dt) { t /= dt; return t + t - t * t - 1; }
        if (t > 1 - dt) { t = (t - 1) / dt; return t * t + t + t + 1; }
        return 0;
      };
      glottis.normalizedLFWaveform = function (t) {
        const dt = 1 / (this.waveformLength * this.sampleRate);
        let y;
        if (src === "pulse") {
          const w = 0.18;
          y = ((t < w ? 0.5 - 0.5 * Math.cos(2 * Math.PI * t / w) : 0) - w / 2) * 2;
        } else if (src === "saw") {
          y = 2 * t - 1 - blep(t, dt);
        } else {
          y = (t < 0.5 ? 1 : -1) + blep(t, dt) - blep((t + 0.5) % 1, dt);
        }
        return y * 0.6 * this.intensity * this.loudness;
      };
    }
    // Pure voice: the stock glottis mixes breath noise into every voiced sample. Keep it only
    // where the glottis is meant to be open (h, aspiration, voiceless consonants).
    if (v.ptPureVoice) {
      glottis.step = function (lambda) {
        if (this.timeInWaveform > this.waveformLength) {
          this.timeInWaveform -= this.waveformLength;
          this.setupWaveform(lambda);
        }
        let out = this.normalizedLFWaveform(this.timeInWaveform / this.waveformLength);
        if (this.targetTenseness < 0.2) {
          out += this.intensity * (1 - Math.sqrt(this.targetTenseness)) * this.getNoiseModulator() * this.aspirationNoiseSource() * 0.2;
        }
        this.sampleCount++;
        this.timeInWaveform += 1 / this.sampleRate;
        return out;
      };
    }
    if (!v.ptNatural) {
      // Pink Trombone always adds two simplex pitch wobbles (about ±6%) and drifts the
      // tenseness, even with autoWobble off. Strip both: only the lab's own vibrato remains.
      glottis.calculateVibrato = function (time) {
        return this.vibratoAmount * Math.sin(2 * Math.PI * time * this.vibratoFrequency);
      };
      glottis.calculateNewTenseness = function () {
        this.oldTenseness = this.newTenseness;
        this.newTenseness = this.targetTenseness;
      };
    }
    // The stock glottis slews pitch at 10% per 512 samples; stepped pitch wants jumps.
    glottis.calculateNewFrequency = function (time, delta) {
      const rate = 0.1 * delta * (1 + 19 * v.flatPitch);
      if (this.intensity == 0) this.smoothFrequency = this.targetFrequency;
      else if (this.targetFrequency > this.smoothFrequency) this.smoothFrequency = Math.min(this.smoothFrequency * (1 + rate), this.targetFrequency);
      else if (this.targetFrequency < this.smoothFrequency) this.smoothFrequency = Math.max(this.smoothFrequency / (1 + rate), this.targetFrequency);
      this.oldFrequency = this.newFrequency;
      this.newFrequency = Math.max(10, this.smoothFrequency * (1 + this.calculateVibrato(time)));
    };
    // Every release of a full closure fires this pressure pulse (stock strength 0.3);
    // it is the "slap" at word ends, so its strength is a control.
    shaper.addTransient = function (position) {
      if (v.ptClick <= 0) return;
      tract.transients.push({ position, startTime: tract.time, lifeTime: 0.2, strength: 0.3 * v.ptClick, exponent: 200 });
    };
    // Softness opens constrictions: stops and taps stop short of a full closure (so no
    // transient fires at all once the target diameter clears 0), fricatives widen toward 0.7
    // where Pink Trombone's turbulence fades out. Nasals stay closed; their release does not click.
    const softDiameter = (s, d) => {
      const soft = s.soft !== undefined ? s.soft : v.softness;
      if (soft <= 0) return d;
      switch (s.p.cls) {
        case "stop": case "affric": case "tap": case "trill": return lerp(d, 1.0, soft * 0.7);
        case "fric": case "approx": return lerp(d, 0.7, soft * 0.6);
        default: return d;
      }
    };
    shaper.movementSpeed = v.ptSpeed;

    const segs = plan.segments;
    // Tongue per segment: vowels/glides use their own, consonants borrow the next vowel's.
    const tongueOf = segs.map((s, k) => {
      if (s.p && s.p.pt.tongue) return s.p.pt.tongue;
      for (let j = k + 1; j < segs.length; j++) if (segs[j].p && segs[j].p.pt.tongue) return segs[j].p.pt.tongue;
      for (let j = k - 1; j >= 0; j--) if (segs[j].p && segs[j].p.pt.tongue) return segs[j].p.pt.tongue;
      return [20.7, 2.8];
    });
    const block = Math.round(R * fr.dt);
    const leadFrames = Math.max(0, Math.round((v.ptLead / 1000) / fr.dt));
    const rng = mulberry32(hashStr(String(v.seed)) ^ 0x7a11);
    const voicedTense = clamp(lerp(0.35, 0.95, v.tense) - v.breath * 0.3, 0.05, 1);

    const releaseAt = (s) => (s.p.cls === "stop" ? s.dur - Math.min(0.012, s.dur * 0.3) : s.dur * 0.45);
    const openNow = (s, local) => (s.p.cls === "stop" || s.p.cls === "affric") && local >= releaseAt(s);

    const total = fr.n * block;
    const raw = new Float32Array(total);
    const pre = new Float32Array(block);
    for (let i = 0; i < 8; i++) synth.synthesize(pre);   // settle with the glottis off

    let activeFricSeg = -1, activePoint = null;
    for (let f = 0; f < fr.n; f++) {
      const t = f * fr.dt;
      const kNow = fr.seg[f];
      const kLead = fr.seg[Math.min(fr.n - 1, f + leadFrames)];
      const cur = segs[kNow], ahead = segs[kLead];
      const local = t - cur.t0;

      // tongue: blend toward the lead segment's vowel
      const tg = tongueOf[kLead];
      shaper.tongueIndex = tg[0];
      shaper.tongueDiameter = tg[1];
      for (let i = 0; i < tract.n; i++) shaper.targetDiameter[i] = shaper.getRestDiameter(i);

      const applyCon = (s, isCur) => {
        if (!s.p || !s.p.pt.con) return;
        const [idx, d] = s.p.pt.con;
        if (isCur && openNow(s, local)) {
          if (s.p.cls === "affric") reduceTarget(tract, shaper, idx, 0.3);
          return;
        }
        let dd = d;
        if (s.p.cls === "trill") {
          const lt = isCur ? local : 0;
          dd = ((lt * 28) % 1) < 0.5 ? 0 : 0.9;
        }
        if (s.p.cls === "tap" && isCur && local > s.dur * 0.7) return;
        reduceTarget(tract, shaper, idx, Math.max(0, softDiameter(s, dd) - 0.3));
      };
      applyCon(cur, true);
      if (ahead !== cur) applyCon(ahead, false);
      for (const s of [cur, ahead]) {
        if (s.p && s.p.pt.lips) reduceTarget(tract, shaper, 41, Math.max(0, (s.p.pt.lipD || 1.0) - 0.3));
      }
      const nasal = (cur.p && cur.p.pt.nasal) || (ahead.p && ahead.p.pt.nasal);
      shaper.velumTarget = nasal ? shaper.velumOpenTarget : shaper.velumClosedTarget;

      // frication: a turbulence point for the life of a fricative (or affricate release)
      const fricNow = cur.p && (cur.p.cls === "fric" || cur.p.cls === "approx" || (cur.p.cls === "affric" && openNow(cur, local)));
      if (fricNow && activeFricSeg !== kNow) {
        if (activePoint) activePoint.endTime = tract.time;
        const [idx, d] = cur.p.pt.con;
        activePoint = { position: idx, diameter: softDiameter(cur, cur.p.cls === "affric" ? 0.6 : d), startTime: tract.time, endTime: NaN };
        tract.turbulencePoints.push(activePoint);
        activeFricSeg = kNow;
      } else if (!fricNow && activePoint) {
        activePoint.endTime = tract.time;
        activePoint = null;
        activeFricSeg = -1;
      }
      tract.turbulencePoints = tract.turbulencePoints.filter((p) => isNaN(p.endTime) || tract.time - p.endTime < 0.2);

      // glottis
      const voicing = fr.voicing[f], asp = fr.asp[f];
      if (asp > 0) { intensityTarget = 1; glottis.targetTenseness = 0.05; }
      else if (voicing > 0) { intensityTarget = Math.min(1, 0.4 + voicing); glottis.targetTenseness = voicedTense; }
      else if (fr.fric[f] > 0) { intensityTarget = 0.3; glottis.targetTenseness = 0; }
      else { intensityTarget = 0; glottis.targetTenseness = voicedTense; }
      const creak = fr.creak[f] > 0 && rng() < fr.creak[f] * 0.5;
      glottis.targetFrequency = fr.f0[f] * (1 + (v.jitter / 100) * (rng() * 2 - 1)) * (creak ? 0.55 : 1);

      const buf = raw.subarray(f * block, (f + 1) * block);
      synth.synthesize(buf);
      // Turbulence noise in the tract is quiet next to voicing; lift voiceless frication.
      const gainAt = (q) => (fr.sylAmp[q] * (fr.fric[q] > 0 && fr.voicing[q] === 0 ? Math.max(1, v.ptFricBoost * (1 - 0.6 * v.softness)) : 1)) || (fr.chop[q] ? 0 : 0.45);
      const g0 = gainAt(f), g1 = gainAt(Math.min(fr.n - 1, f + 1));
      const shim = 1 + (v.shimmer / 100) * (rng() * 2 - 1);
      for (let i = 0; i < block; i++) {
        const g = lerp(g0, g1, i / block);
        buf[i] *= (cur.p ? g : 1) * shim;
      }
    }
    return resample(raw, R / OUT_SR);
  }

  // ---------------------------------------------------------------- smoothing
  // Warmth: a 12 dB/oct low-pass from 12 kHz down to 2.5 kHz, taking the buzz off.
  // Chorus: two delay taps swept in opposite phase, detuned by +-cents (a modulated
  //   delay of amplitude A at rate r detunes by 2*pi*r*A).
  // Reverb: Freeverb-style, 4 damped combs into 2 all-passes, a small room.
  function smoothChain(buf, v, sr) {
    let out = buf;
    if (v.warmth > 0) {
      const cutoff = 12000 * Math.pow(2500 / 12000, v.warmth);
      const lp = biquad("lp", cutoff, 0.6, 0, sr);
      for (let i = 0; i < out.length; i++) out[i] = lp(out[i]);
    }
    if (v.chorusMix > 0) {
      const dry = Float32Array.from(out);
      const base = 0.018 * sr;
      const taps = [[0.8, 0], [1.1, Math.PI]];
      for (let i = 0; i < out.length; i++) {
        let wet = 0;
        for (const [rate, ph] of taps) {
          const A = (Math.pow(2, v.chorusDetune / 1200) - 1) / (2 * Math.PI * rate) * sr;
          const d = base + A * Math.sin(2 * Math.PI * rate * i / sr + ph);
          const x = i - d, j = Math.floor(x), a = x - j;
          wet += j >= 0 ? dry[j] * (1 - a) + (dry[j + 1] || 0) * a : 0;
        }
        out[i] = dry[i] * (1 - 0.5 * v.chorusMix) + wet * 0.5 * v.chorusMix;
      }
    }
    if (v.reverbMix > 0) {
      const tail = Math.round(0.6 * sr);
      const src = new Float32Array(out.length + tail);
      src.set(out);
      const wet = new Float32Array(src.length);
      for (const len of [1116, 1188, 1277, 1356]) {
        const line = new Float32Array(len);
        let p = 0, store = 0;
        for (let i = 0; i < src.length; i++) {
          const y = line[p];
          store = y * 0.6 + store * 0.4;                 // damping
          line[p] = src[i] + store * 0.72;               // feedback
          p = (p + 1) % len;
          wet[i] += y * 0.25;
        }
      }
      for (const len of [556, 441]) {
        const line = new Float32Array(len);
        let p = 0;
        for (let i = 0; i < wet.length; i++) {
          const b = line[p];
          line[p] = wet[i] + b * 0.5;
          wet[i] = b - wet[i];
          p = (p + 1) % len;
        }
      }
      for (let i = 0; i < src.length; i++) src[i] = src[i] * (1 - 0.5 * v.reverbMix) + wet[i] * v.reverbMix;
      out = src;
    }
    return out;
  }

  // ---------------------------------------------------------------- post chain
  function postProcess(buf, v) {
    const sr = OUT_SR;
    let out = buf;
    if (v.miiFx) {
      const hp = biquad("hp", 160, 0.707, 0, sr);
      const pk = biquad("peak", 1100, 1.4, 6, sr);
      const lp = biquad("lp", 5500, 0.707, 0, sr);
      let peak = 0;
      for (let i = 0; i < out.length; i++) peak = Math.max(peak, Math.abs(out[i]));
      const norm = peak > 0 ? 1 / peak : 1;
      const drive = 1 + v.miiDrive * 4;
      for (let i = 0; i < out.length; i++) {
        let x = lp(pk(hp(out[i] * norm)));
        const ring = Math.sin(2 * Math.PI * v.ringHz * i / sr);
        x *= (1 - v.ringMix) + v.ringMix * ring;
        out[i] = Math.tanh(drive * x) / Math.tanh(drive);
      }
    }
    if (v.lofi) {
      const hold = Math.max(1, Math.round(sr / v.lofiRate));
      const steps = Math.pow(2, v.lofiBits - 1);
      let held = 0;
      for (let i = 0; i < out.length; i++) {
        if (i % hold === 0) held = Math.round(out[i] * steps) / steps;
        out[i] = held;
      }
    }
    out = smoothChain(out, v, sr);
    let peak = 0;
    for (let i = 0; i < out.length; i++) if (isFinite(out[i])) peak = Math.max(peak, Math.abs(out[i])); else out[i] = 0;
    const g = peak > 0 ? 0.89 / peak : 1;
    const fade = Math.round(0.003 * sr);
    for (let i = 0; i < out.length; i++) {
      let e = 1;
      if (i < fade) e = i / fade;
      else if (i > out.length - fade) e = (out.length - i) / fade;
      out[i] *= g * e;
    }
    return out;
  }

  // ---------------------------------------------------------------- bank mode
  // Each syllable rendered once, alone, at a flat base pitch; the line is
  // then those clips placed at their planned times and resampled by
  // f0/base, exactly what AudioStreamPlayer.pitch_scale would do in Godot.
  function renderBank(engine, plan, fr, v) {
    const bank = new Map();
    for (const syl of plan.syllables) {
      if (bank.has(syl.key)) continue;
      const mp = miniPlan(syl.key.split(" "), v);
      const mf = buildFrames(mp, v, { monotone: true });
      bank.set(syl.key, ENGINES[engine].render(mp, mf, v));
    }
    const out = new Float32Array(Math.ceil((plan.duration + 0.15) * OUT_SR));
    const fade = Math.round(0.004 * OUT_SR);
    for (const syl of plan.syllables) {
      let nucT = (syl.t0 + syl.t1) / 2;
      for (let k = syl.i0; k < syl.i1; k++) {
        if (plan.segments[k].p.cls === "vowel") { nucT = plan.segments[k].t0 + plan.segments[k].dur * 0.4; break; }
      }
      const fi = Math.min(fr.n - 1, Math.round(nucT / fr.dt));
      const ratio = fr.f0[fi] / v.basePitch;
      let gain = 0, cnt = 0;
      for (let f = Math.floor(syl.t0 / fr.dt); f <= Math.floor(syl.t1 / fr.dt) && f < fr.n; f++) { gain += fr.sylAmp[f]; cnt++; }
      gain = cnt ? gain / cnt : 1;
      const clip = resample(bank.get(syl.key), ratio);
      const start = Math.round((syl.t0 - 0.02) * OUT_SR);
      for (let i = 0; i < clip.length; i++) {
        const j = start + i;
        if (j < 0 || j >= out.length) continue;
        let e = 1;
        if (i < fade) e = i / fade;
        else if (i > clip.length - fade) e = (clip.length - i) / fade;
        out[j] += clip[i] * gain * e;
      }
    }
    let samples22 = 0;
    for (const b of bank.values()) samples22 += b.length * 22050 / OUT_SR;
    return {
      buf: out,
      stats: { unique: bank.size, total: plan.syllables.length, kb16: samples22 * 2 / 1024, kbQoa: samples22 * 0.4 / 1024 },
    };
  }

  const ENGINES = {
    trombone: { name: "Pink Trombone", render: (p, f, v) => renderTrombone(p, f, v, false) },
    lite: { name: "Tract-lite", render: (p, f, v) => renderTrombone(p, f, v, true) },
    cheap: { name: "Cheap source-filter", render: renderCheap },
    blips: { name: "Vowel blips", render: renderBlips },
    klatt: { name: "KlattSyn", render: renderKlatt },
  };

  function renderLine(engine, plan, fr, v) {
    const t0 = performance.now();
    let buf, bankStats = null;
    // Each engine normalises on its own, so the bank clips are post-processed after mixing.
    if (v.bankMode) {
      const r = renderBank(engine, plan, fr, v);
      buf = r.buf; bankStats = r.stats;
    } else {
      buf = ENGINES[engine].render(plan, fr, v);
    }
    const synthMs = performance.now() - t0;
    buf = postProcess(buf, v);
    return { buf, synthMs, bankStats, sr: OUT_SR };
  }

  Object.assign(VL, { ENGINES, renderLine, postProcess, OUT_SR, resample });
})();
