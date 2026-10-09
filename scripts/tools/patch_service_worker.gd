@tool
extends SceneTree
## Patches the service worker a Godot 4.6 web export generates, so a returning
## player can never run one build's index.js against another build's index.wasm.
## CI runs it on every deploy (.github/workflows/deploy.yml):
##
##   godot --headless --path . --script res://scripts/tools/patch_service_worker.gd -- build/web/index.service.worker.js
##
## The stock worker caches index.js at install but index.wasm / index.pck only when
## a page it controls later fetches them, and checks that its cache is complete for
## the HTML request alone. A cache holding an old index.js and no wasm therefore
## serves new HTML from the network, the old index.js from the cache, and the new
## wasm from the network: "Aborted(Assertion failed: missing Wasm export ...)".
##
## After the patch:
##   - install caches every file (cache.addAll is all-or-nothing), so each worker
##     version holds exactly one complete build;
##   - the completeness check runs for every request, not just the HTML, so a
##     partial cache never mixes with the network;
##   - only an OK response is cached, and the offline page only answers a navigation.
##
## Workers already installed in players' browsers keep the old behaviour until this
## one replaces them; the stale-build guard in the export's head_include covers that
## window (dev-notes/web-engine.md).
##
## Every replacement must match exactly once, so a Godot upgrade that changes the
## generated file fails the deploy here instead of shipping an unpatched worker.
## Running it twice is a no-op. Exit 1 on any mismatch.

const MARKER := "// PATCHED by scripts/tools/patch_service_worker.gd"

const REPLACEMENTS: Array[Array] = [
	[
		"event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(CACHED_FILES)));",
		"event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(FULL_CACHE)));",
	],
	[
		"\tif (isCacheable) {\n\t\t// And update the cache\n\t\tcache.put(event.request, response.clone());",
		"\tif (isCacheable && response.ok) {\n\t\t// And update the cache\n\t\tcache.put(event.request, response.clone());",
	],
	[
		"\t\t\t\tif (isNavigate) {\n\t\t\t\t\t// Check if we have full cache during HTML page request.",
		"\t\t\t\t{\n\t\t\t\t\t// Check if we have full cache on EVERY request, not only the HTML page.",
	],
	[
		"\t\t\t\t\t\t\treturn caches.match(OFFLINE_URL);",
		"\t\t\t\t\t\t\tif (!isNavigate) {\n\t\t\t\t\t\t\t\tthrow e;\n\t\t\t\t\t\t\t}\n\t\t\t\t\t\t\treturn caches.match(OFFLINE_URL);",
	],
]


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		push_error("patch_service_worker: pass the path to index.service.worker.js after --")
		quit(1)
		return
	var path: String = args[0]
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("patch_service_worker: cannot read %s" % path)
		quit(1)
		return
	if text.begins_with(MARKER):
		print("patch_service_worker: %s already patched" % path)
		quit(0)
		return
	for pair in REPLACEMENTS:
		var count := text.count(pair[0])
		if count != 1:
			push_error("patch_service_worker: expected 1 match, found %d, for:\n%s" % [count, pair[0]])
			quit(1)
			return
		text = text.replace(pair[0], pair[1])
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("patch_service_worker: cannot write %s" % path)
		quit(1)
		return
	f.store_string(MARKER + "\n" + text)
	f.close()
	print("patch_service_worker: patched %s" % path)
	quit(0)
