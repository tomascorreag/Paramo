// paramo-music.js — Paramo's in-game music (MVP: play one song from a file).
//
// On the first user interaction, plays the arrangement in
// docs/music/ojos_azules.strudel.js verbatim through the vendored Strudel
// engine. No dynamics: the song is a static file, fetched and evaluated as-is
// (byte-identical to what you paste into strudel.cc). Strudel's randomness is
// seeded by cycle position — not the wall clock — so the file sounds the same
// here, in the dev preview, and on strudel.cc.
//
// The played file is a GENERATED copy of music/ojos_azules.strudel.js — keep it
// in sync with scripts/tools/sync_music.gd (see CLAUDE.md). Loaded by:
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
  var SELF = (document.currentScript && document.currentScript.src) || (function () {
    var ss = document.getElementsByTagName("script");
    for (var i = ss.length - 1; i >= 0; i--) {
      if (/paramo-music\.js(\?|$)/.test(ss[i].src)) return ss[i].src;
    }
    return "";
  })();
  var BASE = SELF ? SELF.slice(0, SELF.lastIndexOf("/") + 1) : "./";
  var SONG_URL = BASE + "ojos_azules.strudel.js";

  var repl = null;       // set once initStrudel resolves
  var songCode = null;   // set once the song file is fetched
  var wantPlaying = false;
  var playing = false;

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
      repl.evaluate(songCode);   // transpile + play; the pattern loops
      playing = true;
      updateDebug();
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
    var p = document.getElementById("playing");
    if (p) p.textContent = playing ? "yes" : "no";
  }

  // --- Control surface ---
  window.ParamoMusic = {
    start: function () { wantPlaying = true; play(); },
    stop: function () { wantPlaying = false; playing = false; if (repl) repl.stop(); updateDebug(); },
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
