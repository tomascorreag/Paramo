extends GutTest

# Guards the language selection: LocaleManager's persistence + fallback, the
# title gate's two boxes, and the one place a longer translation can break a
# fixed-size widget (the pause menu).
#
# LocaleManager is an autoload, so these tests mutate global state — the active
# locale and user://settings.cfg. Both are snapshotted and restored, or every
# suite that runs after this one inherits whichever language ran last.

const TITLE_SCENE: PackedScene = preload("res://scenes/ui/title_intro.tscn")
const PAUSE_SCENE: PackedScene = preload("res://scenes/ui/pause_menu.tscn")

var _locale_before: String = ""
var _saved_before: String = ""


func before_each() -> void:
	_locale_before = TranslationServer.get_locale()
	_saved_before = LocaleManager.saved_locale()


func after_each() -> void:
	if _saved_before.is_empty():
		DirAccess.remove_absolute(LocaleManager.CONFIG_PATH)
		LocaleManager._saved = ""
	else:
		LocaleManager.set_locale(_saved_before)
	TranslationServer.set_locale(_locale_before)


# --- LocaleManager -----------------------------------------------------------

func test_ships_spanish_colombia_and_british_english() -> void:
	var codes: Array[String] = []
	for entry: Dictionary in LocaleManager.SUPPORTED:
		codes.append(String(entry["code"]))
		assert_false(String(entry["native"]).is_empty(), "%s needs a native label" % entry["code"])
		var flag := load(String(entry["flag"])) as Texture2D
		assert_not_null(flag, "%s needs a loadable flag icon" % entry["code"])
	assert_has(codes, "es_CO")
	assert_has(codes, "en_GB")


func test_set_locale_applies_and_persists() -> void:
	LocaleManager.set_locale("es_CO")
	assert_eq(TranslationServer.get_locale(), "es_CO", "the locale must actually switch")
	assert_eq(LocaleManager.saved_locale(), "es_CO")

	# Read the file back rather than trusting the in-memory copy — the point of
	# the config is surviving a restart.
	var cfg := ConfigFile.new()
	assert_eq(cfg.load(LocaleManager.CONFIG_PATH), OK, "settings.cfg must be written")
	assert_eq(
		String(cfg.get_value(LocaleManager.CONFIG_SECTION, LocaleManager.CONFIG_KEY, "")),
		"es_CO")


func test_unsupported_locale_is_refused() -> void:
	LocaleManager.set_locale("en_GB")
	LocaleManager.set_locale("fr_FR")
	assert_eq(TranslationServer.get_locale(), "en_GB",
		"an unshipped locale must leave the active one alone")


func test_default_locale_prefers_the_saved_pick() -> void:
	LocaleManager.set_locale("es_CO")
	assert_eq(LocaleManager.default_locale(), "es_CO")
	LocaleManager.set_locale("en_GB")
	assert_eq(LocaleManager.default_locale(), "en_GB")


func test_default_locale_falls_back_when_nothing_is_saved() -> void:
	DirAccess.remove_absolute(LocaleManager.CONFIG_PATH)
	LocaleManager._saved = ""
	# With no saved pick the choice comes from the system language, and any system
	# we do not ship must land on the fallback rather than on an empty locale.
	var chosen := LocaleManager.default_locale()
	assert_true(LocaleManager.is_supported(chosen),
		"the boot locale must always be one we ship, got '%s'" % chosen)


# --- The title gate ----------------------------------------------------------

func test_gate_boxes_are_labelled_from_the_supported_list() -> void:
	# The scene authors the boxes so they render styled in the editor, but the
	# STRINGS come from LocaleManager.SUPPORTED — this is what stops the two
	# drifting apart when a locale is added or reordered.
	var title: CanvasLayer = TITLE_SCENE.instantiate()
	add_child_autofree(title)
	var choice := title.get_node("LanguageChoice") as HBoxContainer

	var visible_boxes: Array[Panel] = []
	for child in choice.get_children():
		if child is Panel and (child as Panel).visible:
			visible_boxes.append(child as Panel)
	assert_eq(visible_boxes.size(), LocaleManager.SUPPORTED.size(),
		"one box per shipped locale")

	for i: int in visible_boxes.size():
		var entry: Dictionary = LocaleManager.SUPPORTED[i]
		assert_eq((visible_boxes[i].get_node("Stack/Name") as Label).text,
			String(entry["native"]), "box %d name" % i)
		# The flag is compared by resource_path: the script assigns via load(), so
		# an equal path IS the same cached resource — and a mismatch names the
		# offending .tres in the failure message.
		var flag := (visible_boxes[i].get_node("Stack/Flag") as TextureRect).texture
		assert_not_null(flag, "box %d flag" % i)
		assert_eq(flag.resource_path, String(entry["flag"]), "box %d flag" % i)


func test_gate_box_labels_are_not_translation_keys() -> void:
	# Each box is written in the language it selects and must NOT follow the
	# active locale — otherwise picking English would hide the Spanish option
	# from the player who needs it.
	var title: CanvasLayer = TITLE_SCENE.instantiate()
	add_child_autofree(title)
	for entry: Dictionary in LocaleManager.SUPPORTED:
		var native := String(entry["native"])
		assert_eq(tr(native), native,
			"'%s' must be literal text, not a key with a translation" % native)


func test_gate_marks_the_saved_locale_without_choosing_it() -> void:
	LocaleManager.set_locale("es_CO")
	var title: CanvasLayer = TITLE_SCENE.instantiate()
	add_child_autofree(title)

	assert_eq(title._preselected, 0, "es_CO is the first shipped locale")
	# Marked, not committed: the gate must still be waiting for a real pick.
	assert_true(title.is_awaiting_click(),
		"a saved locale must not skip the question")


# --- Fixed-size widgets vs longer copy ---------------------------------------

func test_pause_menu_buttons_fit_their_text_in_every_locale() -> void:
	# Spanish runs ~25% longer and these buttons are pinned to exact pixel sizes,
	# so a translation that does not fit is clipped with no error. ResumeBtn is
	# the tight one: it is anchored to a 48px width, not sized to its content.
	var pause: CanvasLayer = PAUSE_SCENE.instantiate()
	add_child_autofree(pause)

	var buttons: Array[Button] = []
	for path: String in ["Center/Panel/Margin/Stack/Confirm/ConfirmRow/YesBtn",
			"Center/Panel/Margin/Stack/Confirm/ConfirmRow/CancelBtn",
			"Center/Panel/ResumeBtn"]:
		var btn := pause.get_node(path) as Button
		assert_not_null(btn, path)
		buttons.append(btn)

	for locale: String in ["en_GB", "es_CO"]:
		TranslationServer.set_locale(locale)
		for btn: Button in buttons:
			var text := tr(btn.text)
			assert_ne(text, btn.text, "%s has no %s translation" % [btn.text, locale])
			var font: Font = btn.get_theme_font(&"font")
			var w: float = font.get_string_size(
				text, HORIZONTAL_ALIGNMENT_CENTER, -1,
				btn.get_theme_font_size(&"font_size")).x
			# The button's own width if it is anchored to one, else the minimum it
			# was authored with. Whichever applies, the glyphs have to sit inside
			# it with the theme's horizontal padding to spare.
			var available: float = maxf(btn.size.x, btn.custom_minimum_size.x)
			var padding: float = btn.get_theme_stylebox(&"normal").get_margin(SIDE_LEFT) \
				+ btn.get_theme_stylebox(&"normal").get_margin(SIDE_RIGHT)
			assert_lte(w + padding, available,
				"%s: '%s' needs %.0fpx (+%.0f padding) in a %.0fpx button"
					% [locale, text, w, padding, available])


func test_fullscreen_button_fits_both_of_its_labels_in_every_locale() -> void:
	# This one stretches to the Settings column rather than carrying a minimum
	# size, so its budget is the panel's inner width, and it has to hold BOTH of
	# the keys it swaps between (see PauseMenu._refresh_fullscreen_label) — the
	# label the player never sees at boot is the one that silently clips.
	var pause: CanvasLayer = PAUSE_SCENE.instantiate()
	add_child_autofree(pause)
	var btn := pause.get_node(
		"Center/Panel/Margin/Stack/Main/Settings/FullscreenBtn") as Button
	assert_not_null(btn)

	var panel := pause.get_node("Center/Panel") as Panel
	var margin := pause.get_node("Center/Panel/Margin") as MarginContainer
	var available: float = panel.custom_minimum_size.x \
		- margin.get_theme_constant(&"margin_left") \
		- margin.get_theme_constant(&"margin_right")
	var padding: float = btn.get_theme_stylebox(&"normal").get_margin(SIDE_LEFT) \
		+ btn.get_theme_stylebox(&"normal").get_margin(SIDE_RIGHT)
	var font: Font = btn.get_theme_font(&"font")
	var font_size: int = btn.get_theme_font_size(&"font_size")

	for locale: String in ["en_GB", "es_CO"]:
		TranslationServer.set_locale(locale)
		for key: String in ["UI_FULLSCREEN", "UI_WINDOWED"]:
			var text := tr(key)
			assert_ne(text, key, "%s has no %s translation" % [key, locale])
			var w: float = font.get_string_size(
				text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size).x
			assert_lte(w + padding, available,
				"%s: '%s' needs %.0fpx (+%.0f padding) in a %.0fpx row"
					% [locale, text, w, padding, available])


func test_pause_panel_is_tall_enough_for_its_settings() -> void:
	# The Panel does NOT grow to its content: the MarginContainer is anchored to
	# the panel rect rather than being a container child, so custom_minimum_size
	# IS the content box and anything that overflows is drawn outside the frame
	# with no error. Adding a settings row means raising that number.
	var pause: CanvasLayer = PAUSE_SCENE.instantiate()
	add_child_autofree(pause)
	await get_tree().process_frame
	await get_tree().process_frame

	var panel := pause.get_node("Center/Panel") as Panel
	var margin := pause.get_node("Center/Panel/Margin") as MarginContainer
	var stack := pause.get_node("Center/Panel/Margin/Stack") as VBoxContainer
	var available: float = panel.size.y \
		- margin.get_theme_constant(&"margin_top") \
		- margin.get_theme_constant(&"margin_bottom")
	assert_lte(stack.get_combined_minimum_size().y, available,
		"the main view needs %.0fpx in a %.0fpx panel"
			% [stack.get_combined_minimum_size().y, available])
