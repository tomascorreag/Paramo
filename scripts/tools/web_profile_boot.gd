extends Node2D

## Sits on scenes/main.tscn and does NOTHING unless asked. Its only job is to
## give scripts/tools/profile_web.gd a way in on a platform that has no command
## line: the web export boots `run/main_scene` and that is the whole interface.
##
##   web:      http://localhost:8000/?profile           (&fires=80&visitors=12)
##   desktop:  --path . --scene res://scenes/main.tscn -- --profile
##
## The harness attaches to the LIVE game rather than replacing the scene, so what
## it measures is the shipped build with the shipped map, not a synthetic rig.
##
## This is the one game-facing file the profiler touches. Keep it inert: an
## unflagged boot must not load the shader, the script, or anything else — a
## measurement tool that costs the player a frame has defeated itself.

const PROFILER := "res://scripts/tools/profile_web.gd"


func _ready() -> void:
	var q: Dictionary = _query()
	if not q.has("profile"):
		return
	var probe: Node = load(PROFILER).new()
	if q.has("fires"):
		probe.set(&"fires", int(q["fires"]))
	if q.has("visitors"):
		probe.set(&"visitors", int(q["visitors"]))
	# `seed` pins the map. level1 ships randomize_seed_on_ready = true, so two
	# runs generate two DIFFERENT mountains — measured at 2937 / 2939 / 3025
	# ground tiles across three runs, which is more variation than most of the
	# effects being measured. Any A/B that spans two runs is meaningless without
	# this.
	if q.has("seed"):
		probe.set(&"map_seed", int(q["seed"]))
	# `ysort=0` paints the ground layers with Y-sort DISABLED. It has to be a
	# boot flag rather than a block toggle because flipping y_sort_enabled after
	# the tiles are painted may not rebuild the layer's CanvasItems at all —
	# which is exactly why the in-run probe's answer could not be trusted.
	if q.has("ysort"):
		probe.set(&"ground_ysort", int(q["ysort"]) != 0)
	# Deferred: _ready runs while the map is still building its own tree, and the
	# harness starts by walking that tree.
	get_tree().root.add_child.call_deferred(probe)


## Flags from the URL on web, from the command line elsewhere, normalised to one
## dictionary so the harness has a single entry point on both. `?profile` and
## `?profile=1` both count — a bare key is the natural way to write it.
func _query() -> Dictionary:
	var out: Dictionary = {}
	var raw: String = ""
	if OS.has_feature("web"):
		raw = String(JavaScriptBridge.eval("location.search.slice(1)", true))
	else:
		var argv := OS.get_cmdline_user_args()
		var parts: PackedStringArray = []
		for a in argv:
			if a.begins_with("--"):
				parts.append(a.substr(2))
		raw = "&".join(parts)
	for pair in raw.split("&", false):
		var kv: PackedStringArray = pair.split("=", true, 1)
		out[kv[0]] = kv[1] if kv.size() > 1 else "1"
	return out
