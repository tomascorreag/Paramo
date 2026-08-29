extends GutTest

# The sentence ActionInspect says when a plant is identified.
#
# Two things here are easy to get wrong and invisible until a player reads them:
#
#   Gender. Spanish articles agree with the noun, so a line interpolates a NOUN
#   PHRASE built from the species' authored name_gender ("una cortadera", "al
#   chusque") rather than the bare name. Mis-author the gender and it reads as
#   broken Spanish with nothing else complaining; test_localization guards that
#   the article words exist, this file guards what comes out of composing them.
#
#   Capitalisation. Spanish opens an exclamation with ¡, so upper-casing
#   character 0 would leave "¡un chusque!". _sentence_case walks to the first
#   LETTER instead, which is what lets a clause start with the placeholder.

const _KINDS: Array[StringName] = [
	&"frailejon", &"espeletia_hartwegiana", &"espeletia_barclayana",
	&"calamagrostis", &"chusquea", &"cortaderia", &"hypericum", &"arcytophyllum",
]

var _locale_before: String = ""


func before_all() -> void:
	_locale_before = TranslationServer.get_locale()


func after_all() -> void:
	TranslationServer.set_locale(_locale_before)


func _data(kind: StringName) -> PlantObjectData:
	return ObjectPainter.data_for(kind) as PlantObjectData


func test_every_species_reads_as_a_sentence_in_both_locales() -> void:
	var a := ActionInspect.new()
	for locale: String in ["en_GB", "es_CO"]:
		TranslationServer.set_locale(locale)
		for kind: StringName in _KINDS:
			for first_sighting: bool in [true, false]:
				var line := a.line_for(_data(kind), first_sighting)
				assert_false(line.contains("{0}"),
					"%s/%s left its placeholder unfilled" % [kind, locale])
				assert_false(line.contains("FLORA_") or line.contains("NARRATIVE_"),
					"%s/%s printed a raw key: %s" % [kind, locale, line])
				assert_gt(line.length(), 3, "%s/%s is not a sentence" % [kind, locale])


func test_spanish_articles_agree_with_the_noun() -> void:
	# The two feminine nouns in the set, both articles. Getting these wrong is
	# the whole reason name_gender is authored per species.
	var a := ActionInspect.new()
	TranslationServer.set_locale("es_CO")
	assert_eq(a.noun_phrase(_data(&"cortaderia"), 0), "una cortadera")
	assert_eq(a.noun_phrase(_data(&"calamagrostis"), 0), "una paja de páramo")
	assert_eq(a.noun_phrase(_data(&"chusquea"), 0), "un chusque")
	assert_eq(a.noun_phrase(_data(&"cortaderia"), 1), "a la cortadera")
	assert_eq(a.noun_phrase(_data(&"chusquea"), 1), "al chusque")


## The line the user asked for by name. Spanish contracts a+el into al, so the
## preposition rides on the article and the template omits it; English keeps the
## preposition in the template. If either side drifts this reads as "otra mirada
## el chusque" or "another look chusque".
func test_the_definite_line_contracts_in_spanish_and_not_in_english() -> void:
	var a := ActionInspect.new()
	TranslationServer.set_locale("es_CO")
	assert_eq(tr("NARRATIVE_INSPECT_KNOWN_3").format(
		[a.noun_phrase(_data(&"chusquea"), 1)]), "Otra mirada al chusque")
	assert_eq(tr("NARRATIVE_INSPECT_KNOWN_3").format(
		[a.noun_phrase(_data(&"cortaderia"), 1)]), "Otra mirada a la cortadera")
	TranslationServer.set_locale("en_GB")
	assert_eq(tr("NARRATIVE_INSPECT_KNOWN_3").format(
		[a.noun_phrase(_data(&"chusquea"), 1)]), "Another look at the chusque")


## A discovery lands as a statement or an exclamation, at random; re-reading a
## note never shouts. The Spanish exclamation must carry its opening mark.
func test_discoveries_vary_their_punctuation_and_re_reads_do_not() -> void:
	var a := ActionInspect.new()
	for locale: String in ["en_GB", "es_CO"]:
		TranslationServer.set_locale(locale)
		var new_endings: Dictionary[String, bool] = {}
		for i in 200:
			var line := a.line_for(_data(&"chusquea"), true)
			new_endings[line.right(1)] = true
			if line.ends_with("!") and locale == "es_CO":
				assert_true(line.begins_with("¡"),
					"a Spanish exclamation needs its opening mark: %s" % line)
		assert_true(new_endings.has("."), "%s: discoveries should sometimes end in a full stop" % locale)
		assert_true(new_endings.has("!"), "%s: discoveries should sometimes end in an exclamation" % locale)
		for i in 200:
			var known := a.line_for(_data(&"chusquea"), false)
			assert_true(known.ends_with("."), "a re-read should not shout: %s" % known)


func test_the_leading_letter_is_capitalised_past_spanish_punctuation() -> void:
	var a := ActionInspect.new()
	TranslationServer.set_locale("es_CO")
	# NEW_1 is the bare phrase; wrapped as an exclamation it opens with ¡, so
	# the letter to raise sits at index 1, not 0.
	var seen: Array[String] = []
	for i in 40:
		seen.append(a.line_for(_data(&"chusquea"), true))
	assert_true(seen.has("¡Un chusque!"),
		"expected the exclamation variant capitalised past the opening mark, got %s"
			% [seen])
	for line: String in seen:
		assert_false(line.begins_with("¡un") or line.begins_with("un "),
			"line starts lower-case: %s" % line)


## The toast draws with `draw_string`-style semantics: no wrap, no ellipsis, it
## just runs off the screen. Spanish is ~25% longer than English and the longest
## line here is Spanish, so measure rather than eyeball. 480 is the narrowest
## logical viewport the display path produces (1080p at the 4x integer upscale).
func test_no_line_overflows_the_narrowest_viewport() -> void:
	const VIEWPORT_W: float = 480.0
	var theme: Theme = load("res://resources/ui/paramo_theme.tres")
	var font: Font = theme.get_font(&"font", &"Label")
	var size: int = theme.get_font_size(&"font_size", &"Label")
	if font == null:
		font = ThemeDB.fallback_font
	if size <= 0:
		size = ThemeDB.fallback_font_size
	var a := ActionInspect.new()
	for locale: String in ["en_GB", "es_CO"]:
		TranslationServer.set_locale(locale)
		for kind: StringName in _KINDS:
			for first_sighting: bool in [true, false]:
				for i in 30:
					var line := a.line_for(_data(kind), first_sighting)
					var w: float = font.get_string_size(
						line, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
					assert_lt(w, VIEWPORT_W,
						"%s runs off the screen at %.0f px: %s" % [locale, w, line])


func test_a_line_never_repeats_twice_running() -> void:
	# The player inspects the same tussock over and over; the same phrasing back
	# to back is what makes a canned line feel canned.
	var a := ActionInspect.new()
	TranslationServer.set_locale("en_GB")
	var previous := ""
	for i in 60:
		var line := a.line_for(_data(&"frailejon"), false)
		assert_ne(line, previous, "phrasing repeated on consecutive inspections")
		previous = line


func test_first_sighting_and_re_reading_say_different_things() -> void:
	var a := ActionInspect.new()
	TranslationServer.set_locale("en_GB")
	var new_lines: Dictionary[String, bool] = {}
	var known_lines: Dictionary[String, bool] = {}
	for i in 80:
		new_lines[a.line_for(_data(&"hypericum"), true)] = true
		known_lines[a.line_for(_data(&"hypericum"), false)] = true
	assert_gt(new_lines.size(), 1, "a first sighting should have variations")
	assert_gt(known_lines.size(), 1, "re-reading should have variations")
	for line: String in new_lines:
		assert_false(known_lines.has(line),
			"'%s' is used for both a discovery and a re-read" % line)
