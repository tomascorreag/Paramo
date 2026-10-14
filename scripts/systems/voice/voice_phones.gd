class_name VoicePhones
extends RefCounted

## Phoneme inventory for the coordinator's mumble voice. A straight port of
## voice_lab/js/phonemes.js; keep the two in step (the lab is where these were
## tuned by ear). Sources for the numbers are in that file's header:
## English vowels Hillenbrand et al. 1995 (men), Spanish F1/F2 Bradlow 1995,
## Pink Trombone tongue targets from zakaton's table, the rest approximations.
##
## A phone is a Dictionary:
##   cls      StringName  vowel glide liquid tap trill nasal stop fric affric aspirate approx
##   voiced   bool
##   place    StringName  lab den alv post pal vel, or &"" (h, schwa offglide)
##   F        Vector3     F1/F2/F3 in Hz, adult male; voices scale them
##   tongue   Vector2     Pink Trombone [index, diameter], vowels and glides only
##   con      Vector2     constriction [index, touch diameter], or Vector2(-1, 0) for none
##   lips     bool        add a rounding constriction; lip_d its touch diameter
##   nasal    bool        open the velum
##   fric     Vector3     noise band [centre Hz, bandwidth Hz, gain], or ZERO

const LOCI: Dictionary = {
	&"lab": Vector3(250, 900, 2200),
	&"den": Vector3(250, 1500, 2600),
	&"alv": Vector3(250, 1700, 2600),
	&"post": Vector3(250, 1900, 2500),
	&"pal": Vector3(250, 2200, 2900),
	&"vel": Vector3(250, 1900, 2300),
}

const PT_PLACE: Dictionary = {&"lab": 41, &"den": 38, &"alv": 36, &"post": 31, &"pal": 27, &"vel": 20}

## Release burst per place: [centre, bandwidth, gain].
const BURST: Dictionary = {
	&"lab": Vector3(1100, 2200, 0.55),
	&"den": Vector3(4500, 3000, 0.6),
	&"alv": Vector3(4000, 2500, 0.7),
	&"post": Vector3(3000, 1500, 0.75),
	&"pal": Vector3(3200, 1500, 0.7),
	&"vel": Vector3(2000, 900, 0.8),
}

## Base durations in ms at speed 1.
const DUR: Dictionary = {
	&"vowel": 95.0, &"glide": 55.0, &"liquid": 60.0, &"tap": 25.0, &"trill": 85.0, &"nasal": 65.0,
	&"stop": 70.0, &"fric": 85.0, &"affric": 95.0, &"aspirate": 60.0, &"approx": 50.0,
}

const VOWELS: Dictionary = {
	&"en": [&"iy", &"ih", &"ey", &"eh", &"ae", &"aa", &"ao", &"ah", &"uh", &"uw", &"ow", &"er", &"ax"],
	&"es": [&"a", &"e", &"i", &"o", &"u"],
}

const CONSONANTS: Dictionary = {
	&"es": [&"p", &"b", &"t", &"d", &"k", &"g", &"B", &"D", &"G", &"f", &"s", &"x", &"ch", &"m", &"n", &"ny", &"l", &"r", &"J"],
	&"en": [&"p", &"b", &"t", &"d", &"k", &"g", &"f", &"v", &"th", &"dh", &"s", &"z", &"sh", &"h", &"ch", &"jh", &"m", &"n", &"l", &"R", &"w"],
}

const NO_CON := Vector2(-1, 0)

static var _table: Dictionary = {}


static func get_phone(sym: StringName) -> Dictionary:
	if _table.is_empty():
		_build()
	return _table[sym]


static func has_phone(sym: StringName) -> bool:
	if _table.is_empty():
		_build()
	return _table.has(sym)


static func _def(sym: StringName, cls: StringName, voiced: bool, place: StringName, f: Vector3,
		tongue: Vector2 = Vector2.ZERO, con: Vector2 = NO_CON, lips: bool = false,
		nasal: bool = false, fric: Vector3 = Vector3.ZERO, lip_d: float = 1.0) -> void:
	if f == Vector3.ZERO and place != &"":
		f = LOCI[place]
	_table[sym] = {
		&"sym": sym, &"cls": cls, &"voiced": voiced, &"place": place, &"F": f,
		&"tongue": tongue, &"con": con, &"lips": lips, &"lip_d": lip_d, &"nasal": nasal, &"fric": fric,
	}


static func _vowel(sym: StringName, f: Vector3, tongue: Vector2, lips: bool) -> void:
	_def(sym, &"vowel", true, &"", f, tongue, NO_CON, lips)


static func _build() -> void:
	# English (ARPAbet-like names, so they never collide with the Spanish five).
	_vowel(&"iy", Vector3(342, 2322, 3000), Vector2(27.2, 2.2), false)
	_vowel(&"ih", Vector3(429, 2033, 2686), Vector2(26.11, 2.87), false)
	_vowel(&"ey", Vector3(476, 2089, 2691), Vector2(23.5, 2.9), false)
	_vowel(&"eh", Vector3(587, 1802, 2604), Vector2(19.4, 3.43), false)
	_vowel(&"ae", Vector3(591, 1930, 2595), Vector2(14.93, 2.78), false)
	_vowel(&"aa", Vector3(756, 1308, 2534), Vector2(12.75, 2.3), false)
	_vowel(&"ao", Vector3(655, 1023, 2521), Vector2(17.7, 2.05), true)
	_vowel(&"ah", Vector3(621, 1181, 2547), Vector2(17.8, 2.46), false)
	_vowel(&"uh", Vector3(469, 1122, 2434), Vector2(21.5, 2.45), true)
	_vowel(&"uw", Vector3(379, 992, 2355), Vector2(22.8, 2.05), true)
	_vowel(&"ow", Vector3(497, 910, 2459), Vector2(17.7, 2.2), true)
	_vowel(&"er", Vector3(474, 1379, 2400), Vector2(20.7, 2.8), false)
	_vowel(&"ax", Vector3(500, 1500, 2500), Vector2(20.7, 2.8), false)
	# Spanish.
	_vowel(&"a", Vector3(638, 1353, 2500), Vector2(13.5, 2.5), false)
	_vowel(&"e", Vector3(458, 1814, 2600), Vector2(23.0, 3.0), false)
	_vowel(&"i", Vector3(286, 2147, 2900), Vector2(27.2, 2.2), false)
	_vowel(&"o", Vector3(460, 1019, 2450), Vector2(17.7, 2.3), true)
	_vowel(&"u", Vector3(322, 992, 2350), Vector2(22.8, 2.05), true)
	# Centring offglide (en-GB "there", "here"): a schwa that does not make a syllable.
	_def(&"aX", &"glide", true, &"", Vector3(500, 1500, 2500), Vector2(20.7, 2.8))
	# Glides and liquids.
	_def(&"j", &"glide", true, &"pal", Vector3(280, 2250, 2900), Vector2(28, 2.0))
	_def(&"w", &"glide", true, &"lab", Vector3(300, 750, 2300), Vector2(22, 2.0), NO_CON, true, false, Vector3.ZERO, 0.85)
	_def(&"l", &"liquid", true, &"alv", Vector3(360, 1350, 2700), Vector2.ZERO, Vector2(33, 1.0))
	_def(&"R", &"liquid", true, &"post", Vector3(350, 1100, 1600), Vector2.ZERO, Vector2(30, 1.15), true)
	_def(&"r", &"tap", true, &"alv", Vector3.ZERO, Vector2.ZERO, Vector2(36, 0.2))
	_def(&"rr", &"trill", true, &"alv", Vector3.ZERO, Vector2.ZERO, Vector2(36, 0.3))
	# Nasals.
	_def(&"m", &"nasal", true, &"lab", Vector3(280, 1000, 2200), Vector2.ZERO, Vector2(41, 0), false, true)
	_def(&"n", &"nasal", true, &"alv", Vector3(280, 1700, 2600), Vector2.ZERO, Vector2(36, 0), false, true)
	_def(&"ny", &"nasal", true, &"pal", Vector3(280, 2200, 2900), Vector2.ZERO, Vector2(27, 0), false, true)
	_def(&"ng", &"nasal", true, &"vel", Vector3(280, 1900, 2300), Vector2.ZERO, Vector2(20, 0), false, true)
	# Stops.
	for row: Array in [[&"p", &"lab", false], [&"b", &"lab", true], [&"t", &"alv", false],
			[&"d", &"alv", true], [&"k", &"vel", false], [&"g", &"vel", true]]:
		_def(row[0], &"stop", row[2], row[1], Vector3.ZERO, Vector2.ZERO, Vector2(PT_PLACE[row[1]], 0))
	# Fricatives.
	_def(&"f", &"fric", false, &"lab", Vector3.ZERO, Vector2.ZERO, Vector2(41, 0.5), false, false, Vector3(4500, 6000, 0.28))
	_def(&"v", &"fric", true, &"lab", Vector3.ZERO, Vector2.ZERO, Vector2(41, 0.55), false, false, Vector3(4500, 6000, 0.18))
	_def(&"th", &"fric", false, &"den", Vector3.ZERO, Vector2.ZERO, Vector2(38, 0.5), false, false, Vector3(5500, 6000, 0.22))
	_def(&"dh", &"fric", true, &"den", Vector3.ZERO, Vector2.ZERO, Vector2(38, 0.6), false, false, Vector3(5500, 6000, 0.12))
	_def(&"s", &"fric", false, &"alv", Vector3.ZERO, Vector2.ZERO, Vector2(36, 0.6), false, false, Vector3(6500, 2500, 0.8))
	_def(&"z", &"fric", true, &"alv", Vector3.ZERO, Vector2.ZERO, Vector2(36, 0.6), false, false, Vector3(6500, 2500, 0.45))
	_def(&"sh", &"fric", false, &"post", Vector3.ZERO, Vector2.ZERO, Vector2(31, 0.6), true, false, Vector3(3000, 1600, 0.85))
	_def(&"zh", &"fric", true, &"post", Vector3.ZERO, Vector2.ZERO, Vector2(31, 0.6), true, false, Vector3(3000, 1600, 0.45))
	_def(&"x", &"fric", false, &"vel", Vector3.ZERO, Vector2.ZERO, Vector2(20, 0.5), false, false, Vector3(1700, 900, 0.5))
	_def(&"J", &"fric", true, &"pal", Vector3.ZERO, Vector2.ZERO, Vector2(27, 0.65), false, false, Vector3(3300, 1500, 0.2))
	_def(&"h", &"aspirate", false, &"", Vector3(500, 1500, 2500))
	# Affricates.
	_def(&"ch", &"affric", false, &"post", Vector3.ZERO, Vector2.ZERO, Vector2(31, 0), false, false, Vector3(3000, 1600, 0.85))
	_def(&"jh", &"affric", true, &"post", Vector3.ZERO, Vector2.ZERO, Vector2(31, 0), false, false, Vector3(3000, 1600, 0.45))
	# Spanish lenited b/d/g between vowels: voiced approximants.
	_def(&"B", &"approx", true, &"lab", Vector3.ZERO, Vector2.ZERO, Vector2(41, 0.9), false, false, Vector3(1500, 3000, 0.05))
	_def(&"D", &"approx", true, &"den", Vector3.ZERO, Vector2.ZERO, Vector2(38, 0.9), false, false, Vector3(4000, 4000, 0.05))
	_def(&"G", &"approx", true, &"vel", Vector3.ZERO, Vector2.ZERO, Vector2(20, 0.9), false, false, Vector3(1800, 1500, 0.05))
