// dev-ws.js — EDITOR-ONLY transport. Connects the sidecar browser tab to the
// localhost WebSocket server that MusicDirector.gd runs on desktop/editor builds,
// and forwards each command to window.ParamoMusic. NOT included in the web export
// (there, MusicDirector calls ParamoMusic directly via JavaScriptBridge).
//
// Message shape (JSON text): { "m": "setSeason", "a": ["dry"] }

(function () {
  "use strict";

  var PORT = 8765; // must match WS_PORT in MusicDirector.gd
  var ws = null;

  function setStatus(s) {
    var el = document.getElementById("ws-status");
    if (el) el.textContent = s;
  }

  function connect() {
    ws = new WebSocket("ws://localhost:" + PORT);
    ws.onopen = function () { setStatus("connected to Godot"); };
    ws.onclose = function () {
      setStatus("disconnected — retrying…");
      setTimeout(connect, 1000); // survive editor restarts
    };
    ws.onerror = function () { /* onclose fires next; it handles retry */ };
    ws.onmessage = function (ev) {
      try {
        var msg = JSON.parse(ev.data);
        var fn = window.ParamoMusic && window.ParamoMusic[msg.m];
        if (typeof fn === "function") fn.apply(window.ParamoMusic, msg.a || []);
      } catch (e) {
        console.warn("[paramo dev-ws] bad message:", ev.data, e);
      }
    };
  }

  connect();
})();
