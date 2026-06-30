// paramo-music.js — Paramo's in-game music director (one song, dynamic mix).
//
// On the first user interaction, plays a Strudel arrangement through the vendored
// engine, but it does NOT play the file's full stack verbatim. The director reads
// the layer list from the song's final stack(...), starts with the base layer
// alone, then folds one random instrument back into the mix every ADD_EVERY cycles
// until the whole arrangement is sounding. Each addition re-evaluates the song with
// a larger stack(...); the Cyclist scheduler swaps the pattern in place without
// resetting its clock, so layers enter seamlessly.
//
// SONG-AGNOSTIC: nothing about the arrangement is hardcoded. The song file, the
// base layer name, and the per-layer cadence are read from data-* attributes on
// the <script> tag (see CFG below); the layer set is parsed from the song itself.
// Cadence is counted in CYCLES via the scheduler, so it adapts to any tempo or
// song length with no seconds-per-cycle math. Defaults reproduce ojos_azules:
// base = "melody", one instrument added per cycle (1 cycle == one melody loop).
//
// The song file is never modified — only the final stack() it ends with is
// reconstructed here (see parseSong). Strudel's randomness is seeded by cycle
// position — not the wall clock — so each layer's content matches strudel.cc; only
// the build-up ORDER is randomized per session (Math.random()).
//
// The played file (ojos_azules.strudel.js by default) is a GENERATED copy of the
// matching source under music/ — keep it in sync with scripts/tools/sync_music.gd
// (see CLAUDE.md). Loaded by:
//   - Web export: the export head_include adds this script; same-origin fetch.
//   - Dev preview: docs/music/dev-music.html (serve docs/ over http).
//
// Requires strudel/web-sf-1.3.0.js (custom @strudel/web + soundfonts bundle;
// exposes window.initStrudel / setSoundfontUrl / registerSoundfonts).
//
// API facts (verified against @strudel/web 1.3.0):
//   - initStrudel(opts) returns a Promise resolving to the repl.
//   - repl.evaluate(code) transpiles + plays; the pattern loops. repl.stop() stops.
//   - Soundfonts fetch `${soundfontUrl}/<font>.js`; pointed at the vendored
//     ./soundfonts via setSoundfontUrl, so nothing is fetched cross-origin.

(function () {
  "use strict";

  // Derive the music/ base URL from THIS script's own src so the song file and
  // soundfonts resolve whether the host is the dev preview (docs/music/) or the
  // exported index.html — paramo-music.js sits in music/ in both.
  var SELF_EL = document.currentScript || (function () {
    var ss = document.getElementsByTagName("script");
    for (var i = ss.length - 1; i >= 0; i--) {
      if (/paramo-music\.js(\?|$)/.test(ss[i].src)) return ss[i];
    }
    return null;
  })();
  var SELF = SELF_EL ? SELF_EL.src : "";
  var BASE = SELF ? SELF.slice(0, SELF.lastIndexOf("/") + 1) : "./";

  // Per-deployment config via data-* attributes on the <script> tag, so a
  // different song drops in without editing this file. Defaults reproduce the
  // ojos_azules behavior. Example:
  //   <script src=".../paramo-music.js"
  //           data-song="other.strudel.js" data-add-every="2" data-base-layer="lead">
  // Timing is expressed in CYCLES (not seconds): the build-up counts the
  // scheduler's cycle position, so it adapts to any tempo/song length on its own —
  // no cycle-length-in-seconds is ever needed. ADD_EVERY is "cycles per added
  // layer" (= one melody loop for ojos, where 1 cycle == the whole loop).
  var CFG = (SELF_EL && SELF_EL.dataset) || {};
  var SONG_URL = BASE + (CFG.song || "ojos_azules.strudel.js");
  var BASE_LAYER = CFG.baseLayer || "melody";
  var ADD_EVERY = (function () {
    var n = parseFloat(CFG.addEvery);
    return (isFinite(n) && n > 0) ? n : 1;   // cycles between layer additions
  })();

  var repl = null;       // set once initStrudel resolves
  var songCode = null;   // set once the song file is fetched
  var wantPlaying = false;
  var playing = false;

  // --- Music director: progressive instrument layering ---
  // The song's final stack(...) lists every layer (parsed, not hardcoded). We
  // don't play it verbatim; instead we start with the base layer alone and fold
  // one random instrument back in every ADD_EVERY cycles until the full mix is
  // sounding. Re-evaluating with a larger stack is seamless: the Strudel scheduler
  // (Cyclist) swaps the pattern in place without resetting its clock, so layers
  // enter without a restart/click.
  var layers = null;       // [name,...] parsed from the song's final stack(); null until parsed
  var defs = null;         // song code with that final stack(...) removed (the const defs)
  var revealOrder = null;  // [base, <shuffled rest>] — the build-up order this session
  var revealIndex = 0;     // count of layers currently in the stack
  var nextAt = 0;          // next cycle position at which to add a layer
  var pollTimer = null;    // setInterval handle driving the build-up
  var POLL_MS = 80;        // build-up poll period (tight so the lead estimate stays small)

  function reportError(msg) {
    console.error("[paramo-music] " + msg);
    var el = document.getElementById("error");
    if (el) el.textContent = msg;
  }

  // 1) Boot the engine and prebake the sample/soundfont registry.
  var initRet;
  try {
    initRet = window.initStrudel({
      prebake: function () {
        window.setSoundfontUrl(BASE + "soundfonts");
        window.registerSoundfonts();
        // Drum samples for the percussion layers. Mirrors strudel.cc's default
        // kit so sound("bd"/"oh"/"rd"/"cr"/"sh") resolve UNBANKED exactly as in
        // the editor (uzu-drumkit), plus AkaiMPC60 from tidal-drum-machines for
        // the bombo's .bank(). allSettled: a missing pack must not block init.
        //
        // PRODUCTION CAVEAT: these load cross-origin from the Strudel CDN — fine
        // in the dev preview, but the COEP-isolated web export may block them, so
        // percussion can drop in the deployed build until these packs are
        // vendored locally. The gm_* soundfont layers (vendored) always play.
        var S = window.strudel;
        return Promise.allSettled([
          S.samples(
            "https://strudel.b-cdn.net/uzu-drumkit.json",
            "https://strudel.b-cdn.net/uzu-drumkit/",
            { tag: "drum-machines" }
          ),
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

  // 2) Fetch the song text in parallel with engine init (same-origin).
  var songRet = fetch(SONG_URL).then(function (r) {
    if (!r.ok) throw new Error("HTTP " + r.status + " fetching " + SONG_URL);
    return r.text();
  });

  Promise.all([Promise.resolve(initRet), songRet]).then(function (vals) {
    repl = vals[0];
    songCode = vals[1];
    if (!repl || typeof repl.evaluate !== "function") {
      reportError("no repl returned from initStrudel()");
      return;
    }
    updateDebug();
    if (wantPlaying) play();   // unlocked before we were ready
  }).catch(function (e) {
    reportError("init/song load failed: " + e.message +
      " (the dev preview must be served over http, not file://)");
  });

  function play() {
    if (!repl || songCode == null) return;   // not ready; start() set wantPlaying
    try {
      resumeAudio();
      if (layers === null) parseSong();       // parse the layer list once

      if (!layers) {                          // parse failed: play the song verbatim
        repl.evaluate(songCode);
        playing = true;
        updateDebug();
        return;
      }

      // Fresh build-up: base layer first, the remaining instruments in random
      // order. Base = the configured layer if the song has it, else the first
      // layer listed in the stack (so unknown songs still start with one layer).
      var base = (layers.indexOf(BASE_LAYER) !== -1) ? BASE_LAYER : layers[0];
      var rest = layers.filter(function (n) { return n !== base; });
      revealOrder = [base].concat(shuffled(rest));
      revealIndex = 1;
      evalActive();                           // start with the base layer alone

      // Schedule the first addition on the next cycle boundary so layers enter
      // aligned to the start of a melody loop.
      nextAt = Math.ceil((currentCycle() + 0.001) / ADD_EVERY) * ADD_EVERY;
      startPoll();

      playing = true;
      updateDebug();
    } catch (e) {
      reportError("evaluate failed: " + e.message);
    }
  }

  // Split the song into its layer names + the definitions block. The playback
  // stack is the file's LAST top-level stack(...) — a bare identifier list with no
  // nested parens, end-anchored. (sesq's inner stack(...) is mid-file and has
  // nested sound() calls, so the end-anchored, paren-free pattern can't match it.)
  function parseSong() {
    var m = songCode.match(/stack\(\s*([^()]*?)\s*\)\s*;?\s*$/);
    if (!m) return;                           // leaves layers === null -> verbatim fallback
    var names = m[1].split(",").map(function (s) { return s.trim(); }).filter(Boolean);
    if (names.length === 0) return;           // empty stack -> verbatim fallback
    layers = names;
    defs = songCode.slice(0, m.index);        // everything before the final stack(...)
  }

  // Fisher-Yates; returns a new array (random per session -> "random instrument").
  function shuffled(arr) {
    var a = arr.slice();
    for (var i = a.length - 1; i > 0; i--) {
      var j = Math.floor(Math.random() * (i + 1));
      var t = a[i]; a[i] = a[j]; a[j] = t;
    }
    return a;
  }

  // Re-evaluate the song with the currently-revealed layers as the final mix.
  function evalActive() {
    var active = revealOrder.slice(0, revealIndex);
    repl.evaluate(defs + "\nstack(" + active.join(", ") + ")\n");
  }

  // Current cycle position from the scheduler (float). 0 if unavailable.
  function currentCycle() {
    try {
      if (repl && repl.scheduler && typeof repl.scheduler.now === "function") {
        return repl.scheduler.now();
      }
    } catch (e) { /* fall through */ }
    return 0;
  }

  // Read a numeric scheduler field (cps, latency) with a fallback.
  function schedNum(prop, dflt) {
    try {
      var v = repl && repl.scheduler && repl.scheduler[prop];
      if (typeof v === "number" && isFinite(v)) return v;
    } catch (e) { /* fall through */ }
    return dflt;
  }

  // How far (in cycles) BEFORE a boundary we must swap the pattern so the new
  // layer's downbeat is queried from the larger stack. The Cyclist commits haps
  // ~latency seconds ahead (default 0.1) and we only notice the boundary up to one
  // poll late; convert that wall-time window to cycles via the live cps so it holds
  // at any tempo. Clamped below ADD_EVERY so we never skip a layer.
  function leadCycles() {
    var cps = schedNum("cps", 0.5);
    var sec = schedNum("latency", 0.1) + (POLL_MS / 1000) + 0.05;   // +margin
    return Math.min(sec * cps, ADD_EVERY * 0.5);
  }

  function startPoll() {
    stopPoll();
    pollTimer = setInterval(tick, POLL_MS);
  }

  function stopPoll() {
    if (pollTimer != null) { clearInterval(pollTimer); pollTimer = null; }
  }

  function tick() {
    if (!revealOrder || revealIndex >= revealOrder.length) { stopPoll(); return; }
    // Add a layer once we're within leadCycles() of its boundary — swapping just
    // BEFORE the boundary (not after) is what keeps the new layer's first beat.
    // The loop also catches up if several boundaries elapsed between polls (a
    // throttled background tab); we re-evaluate once for the final state.
    var lead = leadCycles();
    var added = false;
    while (revealIndex < revealOrder.length && currentCycle() >= nextAt - lead) {
      revealIndex++;
      nextAt += ADD_EVERY;
      added = true;
    }
    if (added) {
      evalActive();
      updateDebug();
    }
    if (revealIndex >= revealOrder.length) stopPoll();   // full mix reached
  }

  function resumeAudio() {
    try {
      var getCtx = (window.strudel && window.strudel.getAudioContext) || window.getAudioContext;
      var ctx = (typeof getCtx === "function") ? getCtx() : null;
      if (ctx && ctx.state === "suspended") ctx.resume();
    } catch (e) { /* initStrudel's first-click handler also resumes */ }
  }

  function updateDebug() {
    var p = document.getElementById("playing");
    if (!p) return;
    if (playing && revealOrder) {
      p.textContent = "yes (" + revealIndex + "/" + revealOrder.length + " layers)";
    } else {
      p.textContent = playing ? "yes" : "no";
    }
  }

  // --- Control surface ---
  window.ParamoMusic = {
    start: function () { wantPlaying = true; play(); },
    stop: function () { wantPlaying = false; playing = false; stopPoll(); revealOrder = null; if (repl) repl.stop(); updateDebug(); },
    _ready: function () { return repl != null && songCode != null; },
  };

  // Autoplay: unlock + start on the first interaction anywhere on the page.
  function unlock() {
    window.removeEventListener("pointerdown", unlock);
    window.removeEventListener("keydown", unlock);
    window.ParamoMusic.start();
  }
  window.addEventListener("pointerdown", unlock);
  window.addEventListener("keydown", unlock);
})();
