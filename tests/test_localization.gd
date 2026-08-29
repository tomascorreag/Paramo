extends GutTest

# Guards the es_CO / en_GB localization: that every shipped locale actually
# resolves, that the CSV covers every key the game asks for, and that the keys
# used in scenes/scripts exist in the CSV.
#
# The failure this exists to catch is silent: tr() on a missing key returns the
# KEY, so a typo'd or unlisted string ships as "UI_RESUME" printed on a button
# rather than as an error. Nothing at runtime complains.
#
# It reads the CSV rather than the imported .translation binaries, then checks
# the two against each other — so a CSV edited without re-importing fails here
# instead of at runtime.

const CSV_PATH: String = "res://assets/translations/paramo.csv"

# Where translation keys are used. Scene files are scanned for `text = "KEY"` /
# `title = "KEY"`; scripts for bare "KEY" string literals. Both rely on keys
# being UPPER_SNAKE, which is the reason for that convention.
const SCENE_DIRS: Array[String] = ["res://scenes/ui"]
const SCRIPT_DIRS: Array[String] = ["res://scripts/ui", "res://scripts/tools", "res://scripts/systems"]
# Data resources that carry keys. WorldObjectData.name_key is what ActionInspect
# prints when it identifies a plant, and it is authored per species .tres — so
# the .tres files are as much a source of copy as a scene is.
const RESOURCE_DIRS: Array[String] = ["res://resources/objects"]

# A QUOTED UPPER_SNAKE literal — the shape a translation key has in both .tscn
# and .gd. Unquoted GDScript constants look the same but never match.
const QUOTED_UPPER_SNAKE: String = "\"([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)\""

# Only these prefixes are treated as translation keys. Other quoted UPPER_SNAKE
# strings exist (feature tags, shader defines), so without this the scan would
# report them as missing translations.
const KEY_PREFIXES: Array[String] = [
	"UI_", "JOURNAL_", "LOADING_", "SEASON_", "TUTORIAL_", "NARRATIVE_", "FLORA_",
]

# The lowercase-chrome convention covers UI copy. CLAUDE.md puts in-world
# narrative copy out of its scope, and this prefix is what marks it: NARRATIVE_*
# is prose in the park's voice, written in sentence case.
const SENTENCE_CASE_PREFIX: String = "NARRATIVE_"

var _csv: Dictionary = {}      # key -> {locale: value}
var _locales: PackedStringArray = PackedStringArray()


func before_all() -> void:
	_load_csv()


func _load_csv() -> void:
	var f := FileAccess.open(CSV_PATH, FileAccess.READ)
	assert_not_null(f, "%s must exist" % CSV_PATH)
	if f == null:
		return
	var header := f.get_csv_line()
	# Column 0 is the key column; its heading is ignored by Godot's importer.
	for i in range(1, header.size()):
		_locales.append(header[i])
	while not f.eof_reached():
		var row := f.get_csv_line()
		if row.size() < 2 or row[0].is_empty():
			continue
		var entry: Dictionary = {}
		for i in range(1, mini(row.size(), header.size())):
			entry[header[i]] = row[i]
		_csv[row[0]] = entry
	f.close()


# --- The CSV itself ---------------------------------------------------------

func test_csv_ships_both_locales() -> void:
	assert_true(_locales.has("en_GB"), "CSV must have an en_GB column")
	assert_true(_locales.has("es_CO"), "CSV must have an es_CO column")


func test_every_key_is_filled_in_every_locale() -> void:
	assert_gt(_csv.size(), 0, "CSV must contain keys")
	for key: String in _csv:
		for locale: String in _locales:
			var value := String(_csv[key].get(locale, ""))
			assert_false(value.strip_edges().is_empty(),
				"%s has no %s translation" % [key, locale])


func test_ui_copy_is_lowercase() -> void:
	# The project's UI copy convention (CLAUDE.md) is lowercase chrome, in every
	# language. Checked on the CSV because that is now where the copy lives.
	for key: String in _csv:
		if key.begins_with(SENTENCE_CASE_PREFIX):
			continue
		for locale: String in _locales:
			var value := String(_csv[key][locale])
			assert_eq(value, value.to_lower(),
				"%s/%s must be lowercase UI copy" % [key, locale])


# --- CSV vs the imported binaries -------------------------------------------

func test_locales_are_registered_and_resolve() -> void:
	var registered: PackedStringArray = ProjectSettings.get_setting(
		"internationalization/locale/translations", PackedStringArray())
	assert_gt(registered.size(), 0,
		"internationalization/locale/translations must list the .translation files")

	var previous := TranslationServer.get_locale()
	for locale: String in _locales:
		TranslationServer.set_locale(locale)
		for key: String in _csv:
			assert_eq(tr(key), String(_csv[key][locale]),
				"tr(%s) in %s must match the CSV (re-run --headless --import?)"
					% [key, locale])
	TranslationServer.set_locale(previous)


# --- Keys used in the project vs the CSV ------------------------------------

func test_every_key_used_in_scenes_and_scripts_exists() -> void:
	var missing: Array[String] = []
	for path: String in _collect_files(SCENE_DIRS, ["tscn"]) 			+ _collect_files(SCRIPT_DIRS, ["gd"]) 			+ _collect_files(RESOURCE_DIRS, ["tres"]):
		for key: String in _keys_in(path):
			if not _csv.has(key):
				missing.append("%s: %s" % [path, key])
	assert_eq(missing, [] as Array[String],
		"translation keys used but not defined in the CSV")


## Every plant in the object registry must be nameable: ActionInspect prints
## `name_key`, and an unnamed species identifies into the journal silently.
func test_every_plant_has_a_name_key() -> void:
	for path: String in _collect_files(RESOURCE_DIRS, ["tres"]):
		var data: Resource = load(path)
		if not (data is PlantObjectData):
			continue
		var key := String((data as PlantObjectData).name_key)
		assert_true(_csv.has(key),
			"%s: name_key '%s' must be a CSV key" % [path, key])


func _keys_in(path: String) -> Array[String]:
	var text := FileAccess.get_file_as_string(path)
	var out: Array[String] = []
	var re := RegEx.new()
	re.compile(QUOTED_UPPER_SNAKE)
	for m: RegExMatch in re.search_all(text):
		var key := m.get_string(1)
		if _is_key_prefix(key):
			out.append(key)
	return out


func _is_key_prefix(key: String) -> bool:
	for prefix: String in KEY_PREFIXES:
		if key.begins_with(prefix):
			return true
	return false


func _collect_files(dirs: Array[String], extensions: Array[String]) -> Array[String]:
	var out: Array[String] = []
	for dir: String in dirs:
		_walk(dir, extensions, out)
	return out


func _walk(path: String, extensions: Array[String], out: Array[String]) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := path.path_join(name)
		if dir.current_is_dir():
			_walk(full, extensions, out)
		elif extensions.has(name.get_extension()):
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()
