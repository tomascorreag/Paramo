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


func test_fullscreen_row_fits_its_label_and_checkbox_in_every_locale() -> void:
	# The row is a Button holding an HBox: the setting's name on the left and the
	# checkbox on the right. Its budget is the panel's inner width MINUS the box,
	# the HBox separation and the row's own inset, so the Spanish label ("pantalla
	# completa", 17 characters) is measured against what is actually left.
	var pause: CanvasLayer = PAUSE_SCENE.instantiate()
	add_child_autofree(pause)
	var row_path := "Center/Panel/Margin/Stack/Main/Settings/FullscreenBtn/Row"
	var label := pause.get_node(row_path + "/Label") as Label
	var check := pause.get_node(row_path + "/Check") as Panel
	var row := pause.get_node(row_path) as HBoxContainer
	assert_not_null(label)
	assert_not_null(check)

	var panel := pause.get_node("Center/Panel") as Panel
	var margin := pause.get_node("Center/Panel/Margin") as MarginContainer
	var available: float = panel.custom_minimum_size.x 		- margin.get_theme_constant(&"margin_left") 		- margin.get_theme_constant(&"margin_right") 		- absf(row.offset_left) - absf(row.offset_right) 		- check.custom_minimum_size.x 		- row.get_theme_constant(&"separation")
	var font: Font = label.get_theme_font(&"font")
	var font_size: int = label.get_theme_font_size(&"font_size")

	for locale: String in ["en_GB", "es_CO"]:
		TranslationServer.set_locale(locale)
		var text := tr(label.text)
		assert_ne(text, label.text, "%s has no %s translation" % [label.text, locale])
		var w: float = font.get_string_size(
			text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		assert_lte(w, available,
			"%s: '%s' needs %.0fpx in a %.0fpx row" % [locale, text, w, available])


func test_fullscreen_checkbox_shows_the_window_mode() -> void:
	# The fill IS the state readout — the row's words no longer change — so a
	# fill that does not follow the window mode is a silently wrong setting.
	var pause: CanvasLayer = PAUSE_SCENE.instantiate()
	add_child_autofree(pause)
	var fill := pause.get_node(
		"Center/Panel/Margin/Stack/Main/Settings/FullscreenBtn/Row/Check/CheckFill") as Panel
	assert_not_null(fill)

	var mode := DisplayServer.window_get_mode()
	var fullscreen: bool = mode == DisplayServer.WINDOW_MODE_FULLSCREEN 		or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	pause.call(&"_refresh_fullscreen_toggle")
	assert_eq(fill.visible, fullscreen,
		"the checkbox fill must match the actual window mode")


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


# --- The about view ----------------------------------------------------------

const ABOUT_PATH: String = "Center/Panel/Margin/Stack/About"

func _about_view(pause: CanvasLayer) -> VBoxContainer:
	return pause.get_node(ABOUT_PATH) as VBoxContainer


func test_about_button_opens_the_about_view() -> void:
	var pause: CanvasLayer = PAUSE_SCENE.instantiate()
	add_child_autofree(pause)
	var about := _about_view(pause)
	assert_false(about.visible, "the about view starts hidden")

	(pause.get_node("Center/Panel/Margin/Stack/Main/Info/AboutBtn") as Button).pressed.emit()
	assert_true(about.visible, "pressing about must show it")
	assert_false((pause.get_node("Center/Panel/Margin/Stack/Main") as VBoxContainer).visible,
		"and hide the settings column")
	assert_eq((pause.get_node("Center/Panel/Margin/Stack/Title") as Label).text, "UI_ABOUT",
		"the header names the view")

	var back := pause.get_node("Center/Panel/BackBtn") as Button
	assert_true(back.visible, "a submenu must offer the way out")
	back.pressed.emit()
	assert_false(about.visible, "back returns to the main view")
	assert_false(back.visible, "and the arrow goes with the submenu")


func test_about_links_point_at_the_licence_documents() -> void:
	# The section exists so the licences are reachable from inside the game; a
	# link that does not resolve to the document defeats it. Paths are checked
	# against the files that are actually in the repo.
	assert_true(PauseMenu.LICENCE_URL.ends_with("/LICENSE"))
	assert_true(PauseMenu.NOTICES_URL.ends_with("/THIRD-PARTY-NOTICES.md"))
	for path: String in ["res://LICENSE", "res://THIRD-PARTY-NOTICES.md"]:
		assert_true(FileAccess.file_exists(path), "%s must exist to be linked" % path)
	for url: String in [PauseMenu.REPO_URL, PauseMenu.LICENCE_URL, PauseMenu.NOTICES_URL]:
		assert_true(url.begins_with("https://"), "%s must be https" % url)


func test_about_view_fits_the_panel() -> void:
	# Same trap as the main view: the MarginContainer is anchored to the panel
	# rect rather than sized by it, so a view taller than the panel is drawn
	# outside the frame with no error. The panel holds the TALLEST view.
	var pause: CanvasLayer = PAUSE_SCENE.instantiate()
	add_child_autofree(pause)
	(pause.get_node("Center/Panel/Margin/Stack/Main/Info/AboutBtn") as Button).pressed.emit()
	await get_tree().process_frame
	await get_tree().process_frame

	var panel := pause.get_node("Center/Panel") as Panel
	var margin := pause.get_node("Center/Panel/Margin") as MarginContainer
	var stack := pause.get_node("Center/Panel/Margin/Stack") as VBoxContainer
	var available: float = panel.size.y 		- margin.get_theme_constant(&"margin_top") 		- margin.get_theme_constant(&"margin_bottom")
	assert_lte(stack.get_combined_minimum_size().y, available,
		"the about view needs %.0fpx in a %.0fpx panel"
			% [stack.get_combined_minimum_size().y, available])


func test_about_rows_fit_their_text_in_every_locale() -> void:
	# Every row in the about column stretches to the panel's inner width, so its
	# budget is that width — including the two labels, which are literal text
	# (a name and a URL) rather than translations.
	var pause: CanvasLayer = PAUSE_SCENE.instantiate()
	add_child_autofree(pause)

	var panel := pause.get_node("Center/Panel") as Panel
	var margin := pause.get_node("Center/Panel/Margin") as MarginContainer
	var available: float = panel.custom_minimum_size.x 		- margin.get_theme_constant(&"margin_left") 		- margin.get_theme_constant(&"margin_right")

	var rows: Array[Control] = []
	for name: String in ["Author", "SourceBtn", "LicenceBtn", "NoticesBtn", "Url"]:
		var row := pause.get_node(ABOUT_PATH + "/" + name) as Control
		assert_not_null(row, name)
		rows.append(row)

	for locale: String in ["en_GB", "es_CO"]:
		TranslationServer.set_locale(locale)
		for row: Control in rows:
			# Button and Label both carry `text`, but neither is Control.text —
			# fetch it dynamically rather than branching on the node type twice.
			var text := tr(String(row.get(&"text")))
			var font: Font = row.get_theme_font(&"font")
			var font_size: int = row.get_theme_font_size(&"font_size")
			var w: float = font.get_string_size(
				text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size).x
			var padding: float = 0.0
			if row is Button:
				var box: StyleBox = (row as Button).get_theme_stylebox(&"normal")
				padding = box.get_margin(SIDE_LEFT) + box.get_margin(SIDE_RIGHT)
			assert_lte(w + padding, available,
				"%s: '%s' needs %.0fpx (+%.0f padding) in a %.0fpx row"
					% [locale, text, w, padding, available])


func test_author_line_translates_its_preposition_and_keeps_the_name() -> void:
	# "by Tomás Correa" / "por Tomás Correa": the preposition is copy and comes
	# from the CSV, the name is a proper noun and is capitalised, which is why the
	# line is composed in code instead of being one CSV row (a capitalised row
	# would fail the lowercase-chrome check in test_localization.gd).
	#
	# The locale is switched through TranslationServer rather than LocaleManager
	# on purpose: composed text does not follow a locale change on its own, and
	# NOTIFICATION_TRANSLATION_CHANGED is the only thing that refreshes it.
	var pause: CanvasLayer = PAUSE_SCENE.instantiate()
	add_child_autofree(pause)
	var author := pause.get_node(ABOUT_PATH + "/Author") as Label

	for locale: String in ["en_GB", "es_CO"]:
		TranslationServer.set_locale(locale)
		await get_tree().process_frame
		assert_eq(author.text, "%s %s" % [tr("UI_ABOUT_BY"), PauseMenu.AUTHOR],
			"the %s line must use that locale's preposition" % locale)
		assert_true(author.text.contains("Tomás Correa"),
			"the name is a proper noun and stays capitalised")


func test_about_labels_are_literal_not_keys() -> void:
	# The author line and the URL are proper nouns, not copy: nothing to
	# translate, and a key-shaped literal here would fail the CSV scan instead.
	var pause: CanvasLayer = PAUSE_SCENE.instantiate()
	add_child_autofree(pause)
	for name: String in ["Author", "Url"]:
		var label := pause.get_node(ABOUT_PATH + "/" + name) as Label
		assert_eq(tr(label.text), label.text,
			"'%s' must be literal text, not a translation key" % label.text)
	assert_eq((pause.get_node(ABOUT_PATH + "/Url") as Label).text.to_lower(),
		(pause.get_node(ABOUT_PATH + "/Url") as Label).text,
		"the URL follows the lowercase-chrome convention")


# --- The in-run language dropdown --------------------------------------------

const LANG_ROW: String = "Center/Panel/Margin/Stack/Main/Settings/LanguageBtn"

func _language_button(pause: CanvasLayer) -> Button:
	return pause.get_node(LANG_ROW) as Button


func _language_value(pause: CanvasLayer) -> Label:
	return pause.get_node(LANG_ROW + "/Row/Value") as Label


func _language_options(pause: CanvasLayer) -> Array[Button]:
	var out: Array[Button] = []
	for child: Node in pause.get_node("Center/Panel/LangPopup/Options").get_children():
		out.append(child as Button)
	return out


func test_language_row_names_the_language_in_use() -> void:
	# The dropdown states what is ACTIVE (the old toggle stated what a press
	# would switch TO). Written in that language, so it is readable to a player
	# who cannot read the one currently on screen.
	var pause: CanvasLayer = PAUSE_SCENE.instantiate()
	add_child_autofree(pause)

	for entry: Dictionary in LocaleManager.SUPPORTED:
		LocaleManager.set_locale(String(entry["code"]))
		assert_eq(_language_value(pause).text, String(entry["native"]),
			"the row must name the active language")


func test_language_dropdown_lists_every_shipped_locale() -> void:
	# Built from LocaleManager.SUPPORTED at runtime, so a third locale needs no
	# edit here or in the scene.
	var pause: CanvasLayer = PAUSE_SCENE.instantiate()
	add_child_autofree(pause)
	var options := _language_options(pause)
	assert_eq(options.size(), LocaleManager.SUPPORTED.size(),
		"one row per shipped locale")
	for i: int in LocaleManager.SUPPORTED.size():
		assert_eq(options[i].text, String(LocaleManager.SUPPORTED[i]["native"]))
		assert_not_null(options[i].icon, "each row carries its flag")


func test_language_labels_are_literal_not_keys() -> void:
	# Same rule as the title gate's boxes: translating these would hide the
	# option from the only player who needs it.
	var pause: CanvasLayer = PAUSE_SCENE.instantiate()
	add_child_autofree(pause)
	var labels: Array[String] = [_language_value(pause).text]
	for option: Button in _language_options(pause):
		labels.append(option.text)
	for text: String in labels:
		assert_eq(tr(text), text,
			"'%s' must be literal text, not a translation key" % text)


func test_language_dropdown_opens_and_dismisses() -> void:
	var pause: CanvasLayer = PAUSE_SCENE.instantiate()
	add_child_autofree(pause)
	var popup := pause.get_node("Center/Panel/LangPopup") as Panel
	assert_false(popup.visible, "the list starts closed")

	_language_button(pause).pressed.emit()
	assert_true(popup.visible, "the row opens it")
	_language_button(pause).pressed.emit()
	assert_false(popup.visible, "and closes it again")

	# Leaving the view must take the list with it, or it hangs over the submenu.
	_language_button(pause).pressed.emit()
	pause.call(&"_set_view", 2)
	assert_false(popup.visible, "a view swap dismisses the list")


func test_language_option_switches_and_persists_the_locale() -> void:
	var pause: CanvasLayer = PAUSE_SCENE.instantiate()
	add_child_autofree(pause)
	LocaleManager.set_locale("en_GB")

	for option: Button in _language_options(pause):
		if option.text == "español":
			option.pressed.emit()
	assert_eq(TranslationServer.get_locale(), "es_CO", "picking a row switches")
	assert_eq(LocaleManager.saved_locale(), "es_CO", "and is remembered")
	assert_false((pause.get_node("Center/Panel/LangPopup") as Panel).visible,
		"picking closes the list")


func test_language_row_fits_its_label_value_and_chevron() -> void:
	# Three things share this row: the translated word "language", the active
	# language's native name and the dropdown chevron. Only the first two vary by
	# locale, and the pair has to fit next to a fixed-width glyph.
	var pause: CanvasLayer = PAUSE_SCENE.instantiate()
	add_child_autofree(pause)
	var row := pause.get_node(LANG_ROW + "/Row") as HBoxContainer
	var label := pause.get_node(LANG_ROW + "/Row/Label") as Label
	# A plain Control wrapping the glyph: a Container resets a child's rotation
	# every layout pass, so the rotated TextureRect cannot be the row's child.
	var chevron := pause.get_node(LANG_ROW + "/Row/Chevron") as Control
	assert_not_null(chevron)
	assert_ne(
		(pause.get_node(LANG_ROW + "/Row/Chevron/Glyph") as TextureRect).rotation, 0.0,
		"the dropdown glyph is the back chevron, turned to point down")

	var panel := pause.get_node("Center/Panel") as Panel
	var margin := pause.get_node("Center/Panel/Margin") as MarginContainer
	var available: float = panel.custom_minimum_size.x 		- margin.get_theme_constant(&"margin_left") 		- margin.get_theme_constant(&"margin_right") 		- absf(row.offset_left) - absf(row.offset_right) 		- chevron.custom_minimum_size.x 		- 2.0 * row.get_theme_constant(&"separation")
	var font: Font = label.get_theme_font(&"font")
	var font_size: int = label.get_theme_font_size(&"font_size")

	for locale: String in ["en_GB", "es_CO"]:
		TranslationServer.set_locale(locale)
		for entry: Dictionary in LocaleManager.SUPPORTED:
			var text := "%s%s" % [tr(label.text), String(entry["native"])]
			var w: float = font.get_string_size(
				text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			assert_lte(w, available,
				"%s: '%s' needs %.0fpx in a %.0fpx row"
					% [locale, text, w, available])
