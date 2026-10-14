// Dashboard wiring: controls -> voice params -> plan -> one render per engine -> play.
(function () {
  "use strict";
  const VL = globalThis.VL;
  const $ = (id) => document.getElementById(id);

  const PARAMS = [
    // group, key, label, min, max, step, unit
    ["voice", "basePitch", "base pitch", 60, 420, 1, "Hz"],
    ["voice", "formantScale", "tract scale", 0.8, 1.4, 0.01, "×"],
    ["voice", "speed", "speed", 0.5, 2.2, 0.01, "×"],
    ["voice", "tense", "tenseness", 0, 1, 0.01, ""],
    ["voice", "breath", "breathiness", 0, 1, 0.01, ""],
    ["prosody", "accentSt", "accent", 0, 8, 0.1, "st"],
    ["prosody", "riseSt", "? rise", 0, 10, 0.1, "st"],
    ["prosody", "fallSt", "final fall", 0, 8, 0.1, "st"],
    ["prosody", "declination", "declination", 0, 4, 0.1, "st"],
    ["prosody", "wander", "pitch wander", 0, 2, 0.05, "st"],
    ["prosody", "wordGap", "word gap", 0, 120, 1, "ms"],
    ["prosody", "coartic", "coarticulation", 5, 90, 1, "ms"],
    ["prosody", "scramble", "scramble", 0, 1, 0.01, ""],
    ["flat", "flatPitch", "stepped pitch", 0, 1, 0.01, ""],
    ["flat", "evenRhythm", "even rhythm", 0, 1, 0.01, ""],
    ["flat", "chop", "syllable chop", 0, 40, 1, "ms"],
    ["flat", "softness", "consonant softness", 0, 1, 0.01, ""],
    ["smooth", "warmth", "warmth", 0, 1, 0.01, ""],
    ["smooth", "chorusMix", "chorus", 0, 1, 0.01, ""],
    ["smooth", "chorusDetune", "chorus detune", 0, 30, 0.5, "¢"],
    ["smooth", "reverbMix", "reverb", 0, 0.6, 0.01, ""],
    ["texture", "jitter", "jitter", 0, 5, 0.05, "%"],
    ["texture", "shimmer", "shimmer", 0, 15, 0.1, "%"],
    ["texture", "vibRate", "vibrato rate", 0, 9, 0.1, "Hz"],
    ["texture", "vibDepth", "vibrato depth", 0, 4, 0.05, "%"],
    ["texture", "creak", "creak", 0, 1, 0.01, ""],
    ["mii", "ringHz", "ring freq", 5, 200, 1, "Hz"],
    ["mii", "ringMix", "ring mix", 0, 0.6, 0.01, ""],
    ["mii", "miiDrive", "drive", 0, 1, 0.01, ""],
    ["lofi", "lofiRate", "rate", 4000, 22050, 50, "Hz"],
    ["lofi", "lofiBits", "bits", 3, 16, 1, ""],
    ["engine", "klattFricDb", "klatt noise", -10, 30, 0.5, "dB"],
    ["engine", "ptSpeed", "trombone tract speed", 10, 80, 1, ""],
    ["engine", "ptLead", "trombone lead", 0, 50, 1, "ms"],
    ["engine", "ptFricBoost", "trombone frication", 0.5, 5, 0.05, "×"],
    ["engine", "ptClick", "trombone plosive click", 0, 1, 0.01, "×"],
    ["engine", "liteSegs", "lite sections", 8, 16, 1, ""],
    ["engine", "liteDamping", "lite damping", 0.985, 0.999, 0.0005, ""],
  ];

  const BASE = {
    basePitch: 200, formantScale: 1.15, speed: 1.05, tense: 0.55, breath: 0.25,
    accentSt: 3, riseSt: 5, fallSt: 3, declination: 1.5, wander: 0.3, wordGap: 0, coartic: 40, scramble: 0,
    jitter: 0.8, shimmer: 3, vibRate: 5.5, vibDepth: 0.4, creak: 0,
    ringHz: 60, ringMix: 0, miiDrive: 0.3, lofiRate: 16000, lofiBits: 12,
    klattFricDb: 14, ptSpeed: 35, ptLead: 15, ptFricBoost: 2.5,
    miiFx: false, lofi: false, cheapSource: "rosenberg",
    flatPitch: 0, evenRhythm: 0, chop: 0, quantize: "off", ptNatural: true,
    softness: 0, finalCons: "keep", ptClick: 1,
    ptSource: "lf", ptPureVoice: false, warmth: 0, chorusMix: 0, chorusDetune: 10, reverbMix: 0,
    liteSegs: 11, liteDamping: 0.996, liteRate: 16000,
  };
  const PRESETS = {
    // The coordinator's voice as shipped (resources/voices/coordinator.tres): the exported
    // voice_visitor-1.json, played by tract-lite at 16 kHz with lo-fi off, as in the game.
    "coordinator (exported)": {
      basePitch: 200, formantScale: 1.1, speed: 1.35, tense: 0, breath: 0, accentSt: 3, riseSt: 6, fallSt: 3,
      declination: 1.5, wander: 1.25, wordGap: 5, coartic: 25, scramble: 0.05, jitter: 1.5, shimmer: 3,
      vibRate: 5.5, vibDepth: 1, creak: 0.05, ringHz: 60, ringMix: 0, miiDrive: 0.3, lofiRate: 16000, lofiBits: 16,
      klattFricDb: 1, ptSpeed: 35, ptLead: 15, ptFricBoost: 2.5, miiFx: false, lofi: false, cheapSource: "saw",
      flatPitch: 1, evenRhythm: 0.75, chop: 0, quantize: "semitone", ptNatural: true, softness: 0.75,
      finalCons: "soften", ptClick: 1, ptSource: "lf", ptPureVoice: true, warmth: 0.1, chorusMix: 0,
      chorusDetune: 10, reverbMix: 0.05, liteSegs: 11, liteDamping: 0.996, liteRate: 16000,
    },
    "coordinator (adult, higher)": {},
    "flat gibberish (trombone)": { basePitch: 210, formantScale: 1.18, speed: 1.35, tense: 0.7, breath: 0.05,
                                   accentSt: 2, riseSt: 4, fallSt: 1.5, declination: 0.3, wander: 0, coartic: 20,
                                   jitter: 0, shimmer: 0, vibDepth: 0, creak: 0, flatPitch: 1, evenRhythm: 0.8,
                                   chop: 12, quantize: "semitone", ptNatural: false, ptSpeed: 55, ptLead: 10,
                                   softness: 0.6, finalCons: "soften", ptClick: 0.1,
                                   ptSource: "pulse", ptPureVoice: true, warmth: 0.4, chorusMix: 0.35,
                                   chorusDetune: 10, reverbMix: 0.15 },
    "visitor (adult, lower)": { basePitch: 115, formantScale: 1.0, speed: 1.0, tense: 0.6, breath: 0.15, accentSt: 2.5,
                                riseSt: 4, jitter: 1, shimmer: 4, vibRate: 5, vibDepth: 0.3, creak: 0.1 },
    "kid": { basePitch: 270, formantScale: 1.3, speed: 1.2, tense: 0.5, breath: 0.2, accentSt: 4.5, riseSt: 6, wander: 0.6 },
    "old campesino": { basePitch: 105, formantScale: 0.97, speed: 0.8, tense: 0.45, breath: 0.45, accentSt: 2, riseSt: 3,
                       declination: 2, wander: 0.4, jitter: 2.5, shimmer: 8, vibRate: 5, vibDepth: 1.5, creak: 0.5 },
    "mii-ish": { basePitch: 190, formantScale: 1.12, speed: 1.15, tense: 0.75, breath: 0, accentSt: 4, riseSt: 6, fallSt: 4,
                 jitter: 0, shimmer: 0, vibDepth: 0, wander: 0.1, miiFx: true, ringMix: 0.15, ringHz: 60, lofi: true,
                 lofiRate: 16000, lofiBits: 12 },
    "critter (animalese-ish)": { basePitch: 330, formantScale: 1.35, speed: 1.9, tense: 0.7, breath: 0.1, accentSt: 5,
                                 scramble: 0.6, coartic: 15, jitter: 0.5 },
  };
  const EXAMPLES = {
    es: ["Hola, ¿cómo estás? ¡Qué chévere el páramo!", "¿Quieres plantar frailejones?", "¿Dónde está el agua?",
         "No pises las plantas, por favor.", "¡Se está quemando el monte!", "Mañana va a llover en la montaña."],
    en: ["Hello there! Would you like to plant some flowers?", "Where is the water?", "Please don't step on the plants.",
         "Is it going to rain today?", "Fire! The mountain is burning!", "What a beautiful mountain."],
  };
  // cost: GDScript time per 1 s of 22.05 kHz speech, measured with Godot 4.6.1 on an
  // M1 (desktop). Web/wasm is expected to be 1.5-3x slower (not measured).
  const ENGINE_INFO = {
    trombone: { color: "var(--trombone)", cost: "GDScript ≈ 490+ ms per 1 s of speech: not realtime, reference only",
                desc: "Pink Trombone (MIT): 44-segment waveguide tract plus nose, two steps per sample. The plan becomes tongue, constriction, velum and glottis targets." },
    lite: { color: "var(--lite)", cost: "GDScript ≈ 45 ms per 1 s of speech: realtime candidate",
            desc: "Pink Trombone's glottis and tract shaping over an 11-section waveguide stepped once per sample, no nose tube (nasals are a murmur). Same acoustic length, ~1/10 the work." },
    cheap: { color: "var(--cheap)", cost: "GDScript ≈ 28 ms per 1 s of speech: realtime candidate",
             desc: "Pulse, glottal pulse or saw through 4 parallel band-pass formants, filtered noise for s/sh/f and bursts. Coefficients every 32 samples." },
    blips: { color: "var(--blips)", cost: "GDScript ≈ 10 ms per 1 s of speech: realtime candidate",
             desc: "One blip per syllable: a soft pulse at the syllable's pitch through the vowel's F1/F2, plus a noise tick for a stop or fricative onset. Animalese with real vowels." },
    klatt: { color: "var(--klatt)", cost: "GDScript ≈ 40–45 ms per 1 s of speech (Klatt-shaped loop, not a full port): realtime-capable, but the biggest port",
             desc: "KlattSyn (MIT): Klatt 1980 cascade/parallel formant synth with a natural glottal source and nasal pole/zero." },
  };

  const v = Object.assign({}, BASE, { seed: "visitor-1", lang: "es", bankMode: false });
  const results = {};
  let plan = null;
  let audio = null;
  let playing = null;    // { src, engine, start, dur }
  let lastEngine = "cheap";
  let renderTimer = 0;

  // ---------------------------------------------------------------- controls
  const ctlEls = {};
  function buildControls() {
    const groups = { smooth: "smoothCtl", flat: "flatCtl", voice: "voiceCtl", prosody: "prosodyCtl", texture: "textureCtl", mii: "miiCtl", lofi: "lofiCtl", engine: "engineCtl" };
    for (const [group, key, label, min, max, step, unit] of PARAMS) {
      const row = document.createElement("div");
      row.className = "ctl";
      row.innerHTML = `<label for="c_${key}">${label}</label><input type="range" id="c_${key}" min="${min}" max="${max}" step="${step}"><output></output>`;
      const input = row.querySelector("input"), out = row.querySelector("output");
      const show = () => { out.textContent = (+input.value).toFixed(step < 0.1 ? 2 : step < 1 ? 1 : 0) + unit; };
      input.addEventListener("input", () => { v[key] = +input.value; show(); scheduleRender(); });
      ctlEls[key] = { input, show };
      $(groups[group]).appendChild(row);
    }
    $("quantize").addEventListener("change", () => { v.quantize = $("quantize").value; scheduleRender(); });
    $("finalCons").addEventListener("change", () => { v.finalCons = $("finalCons").value; scheduleRender(); });
    $("ptSource").addEventListener("change", () => { v.ptSource = $("ptSource").value; scheduleRender(); });
    $("liteRate").addEventListener("change", () => { v.liteRate = +$("liteRate").value; scheduleRender(); });
    for (const id of ["miiFx", "lofi", "bankMode", "ptNatural", "ptPureVoice"]) {
      $(id).addEventListener("change", () => { v[id] = $(id).checked; scheduleRender(); });
    }
    $("cheapSource").addEventListener("change", () => { v.cheapSource = $("cheapSource").value; scheduleRender(); });
    $("seed").addEventListener("input", () => { v.seed = $("seed").value; scheduleRender(); });
    $("text").addEventListener("input", scheduleRender);
    $("lang").addEventListener("change", () => { v.lang = $("lang").value; buildExamples(); scheduleRender(); });

    for (const name of Object.keys(PRESETS)) {
      const o = document.createElement("option");
      o.value = name; o.textContent = name;
      $("preset").appendChild(o);
    }
    $("preset").addEventListener("change", () => applyPreset($("preset").value));
  }

  function applyPreset(name) {
    Object.assign(v, BASE, PRESETS[name]);
    syncControls();
    scheduleRender();
  }

  function syncControls() {
    for (const [key, el] of Object.entries(ctlEls)) { el.input.value = v[key]; el.show(); }
    $("miiFx").checked = v.miiFx; $("lofi").checked = v.lofi; $("cheapSource").value = v.cheapSource;
    $("quantize").value = v.quantize; $("ptNatural").checked = v.ptNatural; $("finalCons").value = v.finalCons;
    $("ptSource").value = v.ptSource; $("ptPureVoice").checked = v.ptPureVoice;
    $("liteRate").value = String(v.liteRate);
  }

  function buildExamples() {
    const box = $("examples");
    box.innerHTML = "";
    for (const lang of ["es", "en"]) {
      for (const text of EXAMPLES[lang]) {
        const b = document.createElement("button");
        b.textContent = `${lang} · ${text}`;
        b.addEventListener("click", () => {
          $("text").value = text; $("lang").value = lang; v.lang = lang; scheduleRender();
        });
        box.appendChild(b);
      }
    }
  }

  // ---------------------------------------------------------------- engine cards
  function buildCards() {
    const box = $("engines");
    for (const [key, eng] of Object.entries(VL.ENGINES)) {
      const info = ENGINE_INFO[key];
      const card = document.createElement("div");
      card.className = "card";
      card.style.setProperty("--c", info.color);
      card.innerHTML = `
        <div class="head"><b>${eng.name}</b><span class="desc">${info.desc}</span></div>
        <div class="note">${info.cost}</div>
        <div class="row">
          <button class="play">▶ play</button>
          <button class="wav">⤓ wav</button>
          <span class="stats"></span>
        </div>
        <canvas></canvas>
        <div class="row rating"><span class="note">score for this language:</span></div>`;
      card.querySelector(".play").addEventListener("click", () => play(key));
      card.querySelector(".wav").addEventListener("click", () => downloadWav(key));
      const rating = card.querySelector(".rating");
      for (let s = 1; s <= 5; s++) {
        const b = document.createElement("button");
        b.textContent = s;
        b.addEventListener("click", () => { localStorage.setItem(`vl_score_${key}_${v.lang}`, s); paintRatings(); });
        rating.appendChild(b);
      }
      results[key] = { card, canvas: card.querySelector("canvas"), stats: card.querySelector(".stats"), rating };
      box.appendChild(card);
    }
    paintRatings();
  }

  function paintRatings() {
    for (const key of Object.keys(results)) {
      const s = +localStorage.getItem(`vl_score_${key}_${v.lang}`) || 0;
      results[key].rating.querySelectorAll("button").forEach((b, i) => b.classList.toggle("on", i + 1 <= s));
    }
  }

  // ---------------------------------------------------------------- render
  function scheduleRender() {
    clearTimeout(renderTimer);
    renderTimer = setTimeout(renderAll, 120);
  }

  function renderAll() {
    const text = $("text").value.trim();
    if (!text) return;
    plan = VL.buildPlan(text, v.lang, v);
    const frames = VL.buildFrames(plan, v);
    for (const key of Object.keys(VL.ENGINES)) {
      let r;
      try {
        r = VL.renderLine(key, plan, frames, v);
      } catch (e) {
        console.error(e);
        results[key].stats.textContent = "error: " + e.message;
        continue;
      }
      const dur = r.buf.length / r.sr;
      Object.assign(results[key], r, { dur });
      let s = `synth ${r.synthMs.toFixed(0)} ms · ${(dur * 1000 / Math.max(1, r.synthMs)).toFixed(0)}× real time · ${dur.toFixed(2)} s`;
      if (r.bankStats) {
        const b = r.bankStats;
        s += ` · bank: ${b.unique} clips for ${b.total} syllables, ${b.kb16.toFixed(0)} KB 16-bit / ~${b.kbQoa.toFixed(0)} KB QOA @22 kHz`;
      }
      results[key].stats.textContent = s;
      drawCanvas(key);
    }
    paintTranscript();
    paintTypewriter(Infinity);
    paintRatings();
  }

  function paintTranscript() {
    const el = $("transcript");
    const words = plan.words.map((w) => {
      const sylls = w.sylls.map((s) => {
        const ipa = s.syms.map((sym) => VL.PHONES[sym].ipa).join("");
        return `<span class="${s.stressed ? "st" : "s"}">${s.stressed ? "ˈ" : ""}${ipa}</span>`;
      }).join("<span class=ph>.</span>");
      return `<span class="w">${sylls}</span>`;
    }).join("");
    const types = plan.phrases.map((p) => p.type).join(" → ");
    el.innerHTML = `${words}<br><span class="ph">phrases: ${types} · ${plan.syllables.length} syllables · ${plan.duration.toFixed(2)} s</span>`;
  }

  function paintTypewriter(elapsed) {
    const text = $("text").value;
    const el = $("typewriter");
    if (!plan || !$("typeSync").checked || elapsed === Infinity) { el.textContent = text; return; }
    let shown = 0;
    for (const [t, n] of plan.reveal) if (t <= elapsed) shown = Math.max(shown, n);
    const a = document.createElement("span"), b = document.createElement("span");
    a.textContent = text.slice(0, shown);
    b.textContent = text.slice(shown);
    b.className = "ghost";
    el.replaceChildren(a, b);
  }

  // ---------------------------------------------------------------- canvas
  function fft(re, im) {
    const n = re.length;
    for (let i = 1, j = 0; i < n; i++) {
      let bit = n >> 1;
      for (; j & bit; bit >>= 1) j ^= bit;
      j ^= bit;
      if (i < j) { [re[i], re[j]] = [re[j], re[i]]; [im[i], im[j]] = [im[j], im[i]]; }
    }
    for (let len = 2; len <= n; len <<= 1) {
      const ang = -2 * Math.PI / len;
      for (let i = 0; i < n; i += len) {
        for (let k = 0; k < len / 2; k++) {
          const wr = Math.cos(ang * k), wi = Math.sin(ang * k);
          const ur = re[i + k], ui = im[i + k];
          const xr = re[i + k + len / 2] * wr - im[i + k + len / 2] * wi;
          const xi = re[i + k + len / 2] * wi + im[i + k + len / 2] * wr;
          re[i + k] = ur + xr; im[i + k] = ui + xi;
          re[i + k + len / 2] = ur - xr; im[i + k + len / 2] = ui - xi;
        }
      }
    }
  }

  function drawCanvas(key, playhead) {
    const r = results[key];
    const c = r.canvas;
    const dpr = window.devicePixelRatio || 1;
    const W = Math.floor(c.clientWidth * dpr), H = Math.floor(c.clientHeight * dpr);
    if (c.width !== W || c.height !== H) { c.width = W; c.height = H; r.image = null; }
    const g = c.getContext("2d");
    if (!r.image) {
      const img = g.createImageData(W, H);
      const buf = r.buf, N = 1024, sr = r.sr;
      const waveH = Math.floor(H * 0.28), specH = H - waveH;
      const maxBin = Math.floor(8000 / (sr / N));
      const re = new Float32Array(N), im = new Float32Array(N);
      const win = new Float32Array(N).map((_, i) => 0.5 - 0.5 * Math.cos(2 * Math.PI * i / N));
      for (let x = 0; x < W; x++) {
        const center = Math.floor((x / W) * buf.length);
        for (let i = 0; i < N; i++) { re[i] = (buf[center - N / 2 + i] || 0) * win[i]; im[i] = 0; }
        fft(re, im);
        for (let y = 0; y < specH; y++) {
          const bin = Math.floor((1 - y / specH) * maxBin);
          const mag = Math.sqrt(re[bin] ** 2 + im[bin] ** 2);
          const dbv = Math.max(0, Math.min(1, (20 * Math.log10(mag + 1e-9) + 30) / 60));
          const o = ((waveH + y) * W + x) * 4;
          img.data[o] = 255 * Math.pow(dbv, 1.2);
          img.data[o + 1] = 210 * Math.pow(dbv, 2.2);
          img.data[o + 2] = 120 * Math.pow(dbv, 0.8);
          img.data[o + 3] = 255;
        }
        // waveform column: min/max over the pixel's samples
        const s0 = Math.floor((x / W) * buf.length), s1 = Math.floor(((x + 1) / W) * buf.length);
        let mn = 0, mx = 0;
        for (let i = s0; i < s1; i++) { if (buf[i] < mn) mn = buf[i]; if (buf[i] > mx) mx = buf[i]; }
        const y0 = Math.floor(waveH / 2 - mx * waveH / 2), y1 = Math.ceil(waveH / 2 - mn * waveH / 2);
        for (let y = 0; y < waveH; y++) {
          const o = (y * W + x) * 4;
          const on = y >= y0 && y <= y1;
          img.data[o] = on ? 220 : 14; img.data[o + 1] = on ? 215 : 15; img.data[o + 2] = on ? 205 : 18; img.data[o + 3] = 255;
        }
      }
      r.image = img;
    }
    g.putImageData(r.image, 0, 0);
    if (playhead !== undefined) {
      const x = (playhead / r.dur) * W;
      g.fillStyle = "#e0b25a";
      g.fillRect(x, 0, 2 * dpr, H);
    }
  }

  // ---------------------------------------------------------------- audio
  function ensureAudio() {
    if (!audio) audio = new AudioContext();
    if (audio.state === "suspended") audio.resume();
    return audio;
  }

  function stop() {
    if (playing) {
      try { playing.src.stop(); } catch (_) { /* already ended */ }
      drawCanvas(playing.engine);
      playing = null;
    }
    paintTypewriter(Infinity);
  }

  function play(key, onEnded) {
    const r = results[key];
    if (!r || !r.buf) return;
    stop();
    lastEngine = key;
    const ctx = ensureAudio();
    const ab = ctx.createBuffer(1, r.buf.length, r.sr);
    ab.copyToChannel(r.buf, 0);
    const src = ctx.createBufferSource();
    src.buffer = ab;
    src.connect(ctx.destination);
    const start = ctx.currentTime + 0.03;
    src.start(start);
    const me = { src, engine: key, start, dur: r.dur };
    playing = me;
    src.onended = () => {
      if (playing === me) { playing = null; drawCanvas(key); paintTypewriter(Infinity); }
      if (onEnded) onEnded();
    };
    const tick = () => {
      if (playing !== me) return;
      const t = ctx.currentTime - start;
      drawCanvas(key, Math.max(0, t));
      paintTypewriter(t);
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }

  function playAll() {
    const keys = Object.keys(VL.ENGINES);
    let i = 0;
    const next = () => {
      if (i >= keys.length) return;
      const k = keys[i++];
      play(k, () => setTimeout(() => { if (!playing) next(); }, 350));
    };
    next();
  }

  function downloadWav(key) {
    const r = results[key];
    if (!r || !r.buf) return;
    const n = r.buf.length;
    const dv = new DataView(new ArrayBuffer(44 + n * 2));
    const str = (o, s) => { for (let i = 0; i < s.length; i++) dv.setUint8(o + i, s.charCodeAt(i)); };
    str(0, "RIFF"); dv.setUint32(4, 36 + n * 2, true); str(8, "WAVEfmt ");
    dv.setUint32(16, 16, true); dv.setUint16(20, 1, true); dv.setUint16(22, 1, true);
    dv.setUint32(24, r.sr, true); dv.setUint32(28, r.sr * 2, true); dv.setUint16(32, 2, true); dv.setUint16(34, 16, true);
    str(36, "data"); dv.setUint32(40, n * 2, true);
    for (let i = 0; i < n; i++) dv.setInt16(44 + i * 2, Math.max(-1, Math.min(1, r.buf[i])) * 32767, true);
    const a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob([dv], { type: "audio/wav" }));
    a.download = `voice_${key}_${v.lang}${v.bankMode ? "_bank" : ""}.wav`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }

  // ---------------------------------------------------------------- settings file
  // Every key in BASE plus the seed. Language and bank mode are viewing choices, not voice.
  const SETTINGS_FORMAT = "paramo-voice-lab";
  function exportSettings() {
    const settings = { seed: v.seed };
    for (const key of Object.keys(BASE)) settings[key] = v[key];
    const json = JSON.stringify({ format: SETTINGS_FORMAT, version: 1, preset: $("preset").value, settings }, null, 2);
    const a = document.createElement("a");
    a.href = URL.createObjectURL(new Blob([json], { type: "application/json" }));
    const name = String(v.seed).replace(/[^\w-]+/g, "_") || "voice";
    a.download = `voice_${name}.json`;
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }

  function importSettings(file) {
    file.text().then((text) => {
      let data;
      try { data = JSON.parse(text); } catch (e) { alert("not JSON: " + e.message); return; }
      if (!data || data.format !== SETTINGS_FORMAT || !data.settings) { alert("not a voice lab settings file"); return; }
      // Start from BASE so a file from an older version leaves new controls at their defaults.
      const next = Object.assign({}, BASE);
      const unknown = [];
      for (const [key, val] of Object.entries(data.settings)) {
        if (key === "seed") continue;
        if (!(key in BASE)) { unknown.push(key); continue; }
        if (typeof val !== typeof BASE[key]) continue;
        next[key] = val;
      }
      Object.assign(v, next);
      if (data.settings.seed !== undefined) { v.seed = String(data.settings.seed); $("seed").value = v.seed; }
      syncControls();
      scheduleRender();
      if (unknown.length) console.warn("voice lab: ignored unknown settings", unknown);
    });
  }

  // ---------------------------------------------------------------- boot
  buildControls();
  buildCards();
  buildExamples();
  // Open on the exported coordinator voice.
  Object.assign(v, BASE, PRESETS["coordinator (exported)"]);
  syncControls();
  $("playAll").addEventListener("click", playAll);
  $("stop").addEventListener("click", stop);
  $("exportVoice").addEventListener("click", exportSettings);
  $("importVoice").addEventListener("click", () => $("importFile").click());
  $("importFile").addEventListener("change", () => {
    const f = $("importFile").files[0];
    if (f) importSettings(f);
    $("importFile").value = "";
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      clearTimeout(renderTimer);
      renderAll();
      if (e.shiftKey) playAll(); else play(lastEngine);
    }
  });
  window.addEventListener("resize", () => { for (const k of Object.keys(results)) { results[k].image = null; if (results[k].buf) drawCanvas(k); } });
  renderAll();
})();
