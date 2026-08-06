extends Node

## Autoload. Owns the game's language: which locales exist, which one is active,
## and remembering the player's pick across sessions.
##
## Why an autoload rather than something the title screen owns: the FIRST player-
## facing text is the loading overlay's status line, drawn while the world
## generates — long before the title gate accepts a click. The locale therefore
## has to be applied in _ready, before any scene builds UI, and has to survive the
## full scene reload the pause menu's restart performs.
##
## Godot does the re-rendering for us. TranslationServer.set_locale() sends
## NOTIFICATION_TRANSLATION_CHANGED down the whole tree (SceneTree propagates it
## unconditionally), and Control re-translates its text and queue_redraw()s on
## receipt. So switching locale at runtime updates every Label/Button already on
## screen with no bookkeeping here — see the note in journal_known_set.gd for the
## one case that needs a hand (a translated string cached outside _draw).
##
## Unity bridge: no LocalizationSettings asset, no per-locale StringTable. One
## UTF-8 CSV (assets/translations/paramo.csv) imports to one .translation binary
## per column, registered in project.godot; TranslationServer is a global
## singleton closer to a swappable Dictionary than to Unity's Localization package.

signal locale_changed(code: String)

## The locales the game ships, in the order the title gate shows them. `native`
## is the label printed on that language's box — deliberately written IN that
## language, so it needs no translation. `region` is the subtitle under it.
const SUPPORTED: Array[Dictionary] = [
	{"code": "es_CO", "native": "español", "region": "colombia"},
	{"code": "en_GB", "native": "english", "region": "uk"},
]

const FALLBACK_LOCALE: String = "en_GB"

const CONFIG_PATH: String = "user://settings.cfg"
const CONFIG_SECTION: String = "locale"
const CONFIG_KEY: String = "code"

# Empty until the player has picked once. The title gate reads this to
# pre-highlight the previous choice; it is NOT the same as the active locale
# (a first-time player has an active locale but no saved one).
var _saved: String = ""


func _ready() -> void:
	_saved = _read_saved()
	# Apply immediately: the loading overlay's first status string is drawn
	# before any scene the player can interact with.
	TranslationServer.set_locale(default_locale())


## The locale the player chose last session, or "" if they never have.
func saved_locale() -> String:
	return _saved


## What to start in: the saved pick, else the system language if we ship it,
## else English. OS.get_locale_language() collapses es_419/es_ES/es_CO to "es",
## which is what we want — any Spanish system gets the Spanish build.
func default_locale() -> String:
	if is_supported(_saved):
		return _saved
	var lang: String = OS.get_locale_language()
	for entry: Dictionary in SUPPORTED:
		if String(entry["code"]).begins_with(lang):
			return String(entry["code"])
	return FALLBACK_LOCALE


func is_supported(code: String) -> bool:
	for entry: Dictionary in SUPPORTED:
		if entry["code"] == code:
			return true
	return false


## Switch language and remember it. Safe to call with the current locale.
func set_locale(code: String) -> void:
	if not is_supported(code):
		push_warning("LocaleManager: unsupported locale '%s', ignoring." % code)
		return
	_saved = code
	_write_saved(code)
	TranslationServer.set_locale(code)
	locale_changed.emit(code)


func _read_saved() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return ""
	var code := String(cfg.get_value(CONFIG_SECTION, CONFIG_KEY, ""))
	return code if is_supported(code) else ""


# On web, user:// is an IDBFS mount: the write reaches IndexedDB a frame or two
# after save() returns, flushed by the engine automatically (no force_fs_sync
# needed). It can fail outright in private browsing — a lost preference is
# harmless here, since the gate asks every launch anyway.
func _write_saved(code: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(CONFIG_PATH)  # Preserve other sections; ERR on a missing file is fine.
	cfg.set_value(CONFIG_SECTION, CONFIG_KEY, code)
	var err := cfg.save(CONFIG_PATH)
	if err != OK:
		push_warning("LocaleManager: could not save locale (%d)." % err)
