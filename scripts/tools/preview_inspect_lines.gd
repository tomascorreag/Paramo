extends SceneTree

# Print every line ActionInspect can say, per species, in both locales.
#
#   $G --path . --headless --script res://scripts/tools/preview_inspect_lines.gd
#
# Copy review, not a test: the assertions live in tests/test_inspect_lines.gd.
# Read this when editing the phrasings — an article that disagrees or a sentence
# that lands oddly is obvious here and invisible in an assert.
#
# The work is in _process, not _initialize: LocaleManager is an autoload and its
# _ready runs AFTER a --script tool's _initialize, so a locale set there is
# silently overwritten before anything prints.

const _KINDS: Array[StringName] = [
	&"frailejon", &"espeletia_hartwegiana", &"espeletia_barclayana",
	&"calamagrostis", &"chusquea", &"cortaderia", &"hypericum", &"arcytophyllum",
]

var _done: bool = false


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	var action := ActionInspect.new()
	for locale: String in ["es_CO", "en_GB"]:
		TranslationServer.set_locale(locale)
		print("\n=== %s ===" % locale)
		for kind: StringName in _KINDS:
			var data := ObjectPainter.data_for(kind) as PlantObjectData
			print("\n  %s  (%s)" % [kind, tr(String(data.name_key))])
			for first_sighting: bool in [true, false]:
				var seen: Dictionary[String, bool] = {}
				for i in 200:
					seen[action.line_for(data, first_sighting)] = true
				var label := "found " if first_sighting else "again "
				for line: String in seen:
					print("    %s %s" % [label, line])
					label = "      "
	return true
