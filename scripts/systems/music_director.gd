extends Node
## Autoload registered as "MusicDirector" in project.godot.
## Cannot use class_name — Godot disallows class_name matching an autoload name.

## Bridges game state to the vendored Strudel engine. The MUSIC lives once in
## docs/music/paramo-music.js (window.ParamoMusic); this node only forwards
## SeasonManager state changes to it. Two transports, picked by platform:
##
##   - Web export (OS.has_feature("web")): call window.ParamoMusic.<method>()
##     directly via JavaScriptBridge — same page, in-process.
##   - Editor / desktop: run a localhost WebSocket SERVER. A browser tab loading
##     docs/music/dev-music.html connects as a client and applies the commands,
##     so you hear the real Strudel engine while playing in the editor. (This is
##     the TidalCycles model: editor here, audio process there.)
##
## JS contract (window.ParamoMusic), identical for both transports:
##   setSeason(id: String)   # "dry" | "wet" — swap musical mood live
##   setPlanning(on: bool)   # duck/soften during the planning phase
##   stop()                  # run over
##
## See SeasonManager for the signal source and SeasonProfile.id for the values.

const WS_PORT: int = 8765  # must match PORT in docs/music/dev-ws.js

var _is_web: bool = false

# Web transport.
var _pm: JavaScriptObject = null

# Desktop transport (WebSocket server).
var _tcp: TCPServer = null
var _ws: WebSocketPeer = null
var _ws_was_open: bool = false

# Last state pushed, replayed to a sidecar tab that connects mid-run so it syncs.
var _have_state: bool = false
var _cur_season: String = ""
var _cur_planning: bool = false


func _ready() -> void:
	_is_web = OS.has_feature("web")
	if _is_web:
		_pm = JavaScriptBridge.get_interface("ParamoMusic")
	else:
		_tcp = TCPServer.new()
		var err: int = _tcp.listen(WS_PORT, "127.0.0.1")
		if err != OK:
			push_warning("MusicDirector: WS server failed to listen on %d (err %d); editor audio sidecar disabled" % [WS_PORT, err])
			_tcp = null
	SeasonManager.season_started.connect(_on_season_started)
	SeasonManager.planning_phase_entered.connect(_on_planning_entered)
	SeasonManager.planning_phase_exited.connect(_on_planning_exited)
	SeasonManager.run_completed.connect(_on_run_completed)


func _process(_delta: float) -> void:
	if _is_web or _tcp == null:
		return
	# Accept one client (the sidecar tab); a newer connection replaces the old.
	if _tcp.is_connection_available():
		var conn: StreamPeerTCP = _tcp.take_connection()
		var peer := WebSocketPeer.new()
		if peer.accept_stream(conn) == OK:
			_ws = peer
			_ws_was_open = false
	if _ws == null:
		return
	_ws.poll()
	var st: int = _ws.get_ready_state()
	var open: bool = st == WebSocketPeer.STATE_OPEN
	if open and not _ws_was_open:
		_on_peer_connected()
	_ws_was_open = open
	if st == WebSocketPeer.STATE_CLOSED:
		_ws = null
		_ws_was_open = false


## A freshly-opened sidecar tab gets the current run state so it doesn't sit
## silent until the next season boundary.
func _on_peer_connected() -> void:
	if _have_state:
		_ws_send("setSeason", [_cur_season])
		_ws_send("setPlanning", [_cur_planning])


func _on_season_started(_index: int, profile: SeasonProfile) -> void:
	if profile == null:
		return
	_cur_season = String(profile.id)
	_cur_planning = false
	_have_state = true
	_dispatch("setSeason", [_cur_season])


func _on_planning_entered(_next_index: int) -> void:
	_cur_planning = true
	_dispatch("setPlanning", [true])


func _on_planning_exited(_index: int) -> void:
	_cur_planning = false
	_dispatch("setPlanning", [false])


func _on_run_completed(_reason: StringName) -> void:
	_dispatch("stop", [])


# --- Transport ---

func _dispatch(method: String, args: Array) -> void:
	if _is_web:
		# JavaScriptObject forwards callv() to the underlying JS method.
		# (Verify on first web export — there is no editor path to test this.)
		var pm := _interface()
		if pm != null:
			pm.callv(method, args)
	else:
		_ws_send(method, args)


func _ws_send(method: String, args: Array) -> void:
	if _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify({"m": method, "a": args}))


## Re-fetch defensively; the head-include runs in <head> so it normally exists
## by _ready, but tolerate load ordering / editor hot-reload.
func _interface() -> JavaScriptObject:
	if _pm == null:
		_pm = JavaScriptBridge.get_interface("ParamoMusic")
	return _pm
