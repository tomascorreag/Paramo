// paramo-music.js — the single source of truth for Paramo's in-game music.
//
// Defines window.ParamoMusic, driven by BOTH runtime paths:
//   - Web export:  MusicDirector.gd calls these methods via JavaScriptBridge.
//   - Editor dev:  dev-ws.js forwards MusicDirector.gd's WebSocket commands here.
//
// SPIKE 2a SCOPE: the real Ojos Azules melody/chords/bass via self-hosted GM
// soundfonts (gm_pan_flute / gm_acoustic_guitar_nylon / gm_acoustic_bass). The
// percussion layers (bombo/ticks/accents/sesq — sampled) are deferred to 2b, so
// the active stack here is stack(bass, chords, melody). Source of the pattern:
// music/ojos_azules.strudel.js (kept in sync by hand for now).
//
// Requires strudel/web-sf-1.3.0.js (custom bundle = @strudel/web + soundfonts;
// exposes window.initStrudel / setSoundfontUrl / registerSoundfonts).
//
// API facts (verified against @strudel/web 1.3.0 source):
//   - initStrudel(opts) returns a Promise resolving to the repl.
//   - repl.evaluate(codeString, autoplay=true) transpiles + plays (editor env:
//     setcpm, rand, .every, mini-notation all work). repl.stop() stops.
//   - Soundfonts fetch `${soundfontUrl}/<font>.js`; we point that at our vendored
//     ./soundfonts via setSoundfontUrl, so nothing is fetched cross-origin.

(function () {
  "use strict";

  // Derive the music/ base URL from THIS script's own src, so soundfont/sample
  // paths resolve identically whether the page is the dev sidecar (docs/music/)
  // or the exported index.html (docs/). paramo-music.js lives at music/ in both.
  var SELF = (document.currentScript && document.currentScript.src) || (function () {
    var ss = document.getElementsByTagName("script");
    for (var i = ss.length - 1; i >= 0; i--) {
      if (/paramo-music\.js(\?|$)/.test(ss[i].src)) return ss[i].src;
    }
    return "";
  })();
  var BASE = SELF ? SELF.slice(0, SELF.lastIndexOf("/") + 1) : "./";

  var repl = null;
  var ready = false;
  var state = { season: "wet", planning: false, playing: false };

  function reportError(msg) {
    console.error("[paramo-music] " + msg);
    var el = document.getElementById("error");
    if (el) el.textContent = msg;
  }

  var initRet;
  try {
    initRet = window.initStrudel({
      prebake: function () {
        window.setSoundfontUrl(BASE + "soundfonts");
        window.registerSoundfonts();
        // DEV-ONLY: load the default percussion from the Strudel CDN (the same
        // sources strudel.cc uses) so the full file plays in the sidecar. This is
        // NOT COEP-safe; spike 2b vendors these locally for the web export.
        var S = window.strudel;
        // allSettled: a missing/renamed pack must NOT block init (which would
        // silence the soundfont layers too). Whatever resolves, plays.
        return Promise.allSettled([
          S.samples("github:tidalcycles/Dirt-Samples"),
          S.samples(
            "https://strudel.b-cdn.net/tidal-drum-machines.json",
            "https://strudel.b-cdn.net/tidal-drum-machines/machines/",
            { tag: "drum-machines" }
          ),
        ]);
      },
    });
  } catch (e) {
    reportError("initStrudel threw: " + e.message);
  }
  Promise.resolve(initRet).then(function (r) {
    repl = r;
    if (!repl || typeof repl.evaluate !== "function") {
      reportError("no repl returned from initStrudel()");
      return;
    }
    ready = true;
    applyState();
  }).catch(function (e) { reportError("init failed: " + e.message); });

  // The FULL Ojos Azules arrangement (music/ojos_azules.strudel.js) as a
  // transpiler-ready code string, verbatim except: (a) the dead
  // `samples('bubo:waveforms')` line is dropped (no consumer; throws unknown-
  // alias and would kill the whole evaluation), (b) a master .gain duck during
  // planning is appended. Percussion samples come from the CDN via prebake (dev
  // only). \` escapes the mini-notation backticks inside this template.
  function songCode() {
    var g = state.planning ? 0.5 : 1.0;

    return [
      "setcpm(72 / 22)",
      "const melodyNotes = note(\`",
      "  e5@2 e5@2 e5@2 g5@2   e5@4 d5@2 e5@2   c5@4 c5@2 d5@1 e5@3 e5@2   d5@4 b4@2 c5@2   a4@8",
      "  c5@2 c5@2 c5@2 a4@2   g4@4 c5@2 d5@2   e5@4 c5@2 d5@1 e5@3 e5@2   d5@4 b4@2 c5@2   a4@8",
      "\`)",
      "const melody = melodyNotes",
      "  .degradeBy(0.11).every(4, x => melodyNotes)",
      "  .sound(\"gm_pan_flute\").gain(0.4).attack(0.005).release(0.2).room(0.35).add(note(rand.range(-12.2, -11.8)))",
      "const chords = note(\`",
      "  a3@2 c4@1 e4@1   a3@2 c4@1 e4@1",
      "  e3@2 gs3@1 b3@1   e3@2 gs3@1 b3@1",
      "  a3@2 c4@1 e4@1   a3@2 c4@1 e4@1   c4@2 e4@1 g4@1",
      "  e3@2 gs3@1 b3@1   e3@2 gs3@1 b3@1",
      "  a3@2 c4@1 e4@1   a3@2 c4@1 e4@1",
      "  a3@2 c4@1 e4@1   a3@2 c4@1 e4@1",
      "  g3@2 b3@1 d4@1   g3@2 b3@1 d4@1",
      "  c4@2 e4@1 g4@1   c4@2 e4@1 g4@1   c4@2 e4@1 g4@1",
      "  e3@2 gs3@1 b3@1   e3@2 gs3@1 b3@1",
      "  a3@2 c4@1 e4@1   a3@2 c4@1 e4@1",
      "\`).sound(\"gm_acoustic_guitar_nylon\").gain(0.25).attack(0.001).release(0.14).resonance(8).room(0.5).add(note(12))",
      "const bass = note(\`",
      "  a2@8   e2@8   a2@8 c3@4   e2@8   a2@8",
      "  a2@8   g2@8   c3@12   e2@8   a2@8",
      "\`).sound(\"gm_acoustic_bass\").gain(0.75).attack(0.005).decay(2).sustain(0).release(0.4).add(note(-12))",
      "const bombo = sound(\"bd\").bank(\"AkaiMPC60\").fast(11).speed(0.9).gain(rand.range(0.3, 0.5)).room(0.2)",
      "const ticks = sound(\"~ bd bd\").fast(22).gain(rand.range(0.15, 0.2)).speed(rand.range(0.94, 1.08)).room(0.15)",
      "const accents = sound(\`",
      "  cr@8 oh@8 oh@12 rd@8 rd@8",
      "  oh@8 oh@8 oh@12 rd@8 rd@4 bd@2 bd@2",
      "\`).gain(rand.range(0.05, 0.1)).room(0.3)",
      // sesq uses plain sound(\"sh\"); no default pack has a top-level \"sh\", so
      // bank it to RolandTR808 (the same drum-machines pack bombo already uses).
      "const sesq = stack(",
      "  sound(\"sh*3\").gain(rand.range(0.1, 0.2)).speed(rand.range(0.96, 1.06)).octave(2),",
      "  sound(\"sh*2\").gain(rand.range(0.2, 0.4)).speed(rand.range(1.15, 1.25))",
      ").fast(22).room(0.2).bank(\"RolandTR808\").degradeBy(\"<0.125 0.25 0.75 0>\")",
      "stack(bass, chords, melody, bombo, ticks, accents, sesq).gain(" + g + ")",
    ].join("\n");
  }

  function applyState() {
    updateDebug();
    if (!ready || !repl) return;
    try {
      if (!state.playing) { repl.stop(); return; }
      repl.evaluate(songCode());   // transpile + play; replaces the active pattern
    } catch (e) {
      reportError("evaluate failed: " + e.message);
    }
  }

  function resumeAudio() {
    try {
      var getCtx = (window.strudel && window.strudel.getAudioContext) || window.getAudioContext;
      var ctx = (typeof getCtx === "function") ? getCtx() : null;
      if (ctx && ctx.state === "suspended") ctx.resume();
    } catch (e) { /* initStrudel's first-click handler also resumes */ }
  }

  function updateDebug() {
    var s = document.getElementById("season");
    var p = document.getElementById("playing");
    if (s) s.textContent = state.season;
    if (p) p.textContent = state.playing ? "yes" : "no";
  }

  // --- Control surface (the contract MusicDirector.gd targets) ---
  window.ParamoMusic = {
    start: function () { state.playing = true; resumeAudio(); applyState(); },
    stop: function () { state.playing = false; applyState(); },
    setSeason: function (id) { state.season = (id === "dry") ? "dry" : "wet"; applyState(); },
    setPlanning: function (on) { state.planning = !!on; applyState(); },
    _state: state,
    _ready: function () { return ready; },
  };

  // Autoplay policy: unlock + start on the first interaction anywhere on the page.
  function unlock() {
    window.removeEventListener("pointerdown", unlock);
    window.removeEventListener("keydown", unlock);
    window.ParamoMusic.start();
  }
  window.addEventListener("pointerdown", unlock);
  window.addEventListener("keydown", unlock);
})();
