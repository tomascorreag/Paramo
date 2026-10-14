class_name VoiceG2P
extends RefCounted

## Text -> phonemes for the mumble voice. A port of voice_lab/js/g2p.js; keep the
## two in step, tests/test_voice.gd compares this against a fixture the lab wrote.
##
## Spanish (es-CO) is close to rule-complete because its spelling is close to
## phonemic: seseo, ll/y -> ʝ, b/d/g lenite between vowels, unaccented i/u next to
## a vowel become glides. English (en-GB, non-rhotic) is a rough letter/digraph
## rule set plus a small dictionary: enough for babble that follows the text.
##
## No RegEx anywhere: the web export template is built without the regex module
## (engine/paramo_web.py), so every pattern is spelled out by hand.
##
## A token is a Dictionary:
##   word:  {type: &"word", text, phones: [{sym, ci, accent, soft}], ci, end, func, wh, last_letter, stress_hint}
##   punct: {type: &"punct", ch, ci}
## `ci` is the character index in the source text (drives a typewriter reveal).

const FUNC_WORDS: Dictionary = {
	&"en": ["a", "an", "the", "to", "of", "and", "or", "but", "in", "on", "at", "for", "with", "from", "by",
			"is", "are", "was", "were", "be", "been", "it", "its", "as", "that", "this", "i", "you", "he", "she",
			"we", "they", "me", "him", "her", "us", "them", "my", "your", "his", "our", "their", "do", "does",
			"did", "have", "has", "had", "will", "would", "can", "could", "should", "so", "if", "am"],
	&"es": ["el", "la", "los", "las", "un", "una", "unos", "unas", "de", "del", "y", "o", "e", "u", "en", "con",
			"por", "para", "que", "se", "me", "te", "lo", "le", "les", "nos", "mi", "mis", "tu", "tus", "su", "sus",
			"al", "a", "sin"],
}

const WH: Dictionary = {
	&"en": ["what", "where", "when", "why", "who", "whom", "whose", "which", "how"],
	&"es": ["qué", "quién", "quiénes", "cómo", "dónde", "adónde", "cuándo", "cuál", "cuáles", "cuánto",
			"cuánta", "cuántos", "cuántas", "por qué"],
}

const ACCENTED: Dictionary = {"á": "a", "é": "e", "í": "i", "ó": "o", "ú": "u", "ü": "u"}
const PUNCT: String = ".,;:!?¿¡…-—"

const EN_DICT: Dictionary = {
	"the": "dh ax", "a": "ax", "i": "aa j", "you": "j uw", "to": "t uw", "of": "ax v", "and": "ae n d",
	"is": "ih z", "are": "aa", "was": "w ao z", "what": "w ao t", "one": "w ah n", "two": "t uw",
	"have": "h ae v", "do": "d uw", "does": "d ah z", "said": "s eh d", "there": "dh eh aX",
	"their": "dh eh aX", "where": "w eh aX", "here": "h ih aX", "beautiful": "b j uw t ih f ax l", "my": "m aa j",
	"by": "b aa j", "he": "h iy", "she": "sh iy", "we": "w iy", "me": "m iy", "be": "b iy", "no": "n ax w",
	"go": "g ax w", "so": "s ax w", "oh": "ax w", "hello": "h ax l ax w", "water": "w ao t ax",
	"fire": "f aa j ax", "people": "p iy p ax l", "come": "k ah m", "some": "s ah m", "done": "d ah n",
	"love": "l ah v", "who": "h uw", "why": "w aa j", "how": "h aa w", "now": "n aa w", "know": "n ax w",
	"eye": "aa j", "could": "k uh d", "would": "w uh d", "should": "sh uh d", "put": "p uh t",
	"good": "g uh d", "look": "l uh k", "book": "b uh k", "any": "eh n iy", "many": "m eh n iy",
	"again": "ax g eh n", "very": "v eh R iy", "yes": "j eh s", "okay": "ax w k ey j", "ok": "ax w k ey j",
	"flower": "f l aa w ax", "flowers": "f l aa w ax z", "plant": "p l aa n t", "plants": "p l aa n t s",
	"mountain": "m aa w n t ax n", "rain": "R ey j n", "today": "t ax d ey j", "they": "dh ey j",
	"from": "f R ao m", "for": "f ao", "your": "j ao", "our": "aa w ax", "were": "w er", "been": "b iy n",
}
const EN_STRESS: Dictionary = {"hello": 1, "again": 1, "okay": 1, "ok": 1, "today": 1, "about": 1, "above": 1, "along": 1}
const DH_WORDS: Array[String] = ["the", "this", "that", "these", "those", "they", "them", "their", "there",
		"then", "than", "though", "thus", "with", "other", "mother", "father", "brother"]
const EN_VOWEL_PAIRS: Dictionary = {
	"ee": "iy", "ea": "iy", "ie": "iy", "ei": "iy", "oo": "uw", "ai": "ey j", "ay": "ey j", "oi": "ao j",
	"oy": "ao j", "au": "ao", "aw": "ao", "oa": "ow w", "ue": "j uw", "ew": "j uw", "ui": "uw", "ou": "aa w",
	"ey": "ey j",
}
const EN_VOWEL_PAIRS_BEFORE_R: Dictionary = {"ea": "ih aX", "ee": "ih aX", "ai": "eh aX", "oo": "ao", "ou": "ao", "oa": "ao"}


static func tokenize(text: String, lang: StringName) -> Array[Dictionary]:
	var tokens: Array[Dictionary] = []
	var lower := text.to_lower()
	var i := 0
	var n := lower.length()
	while i < n:
		var c := lower[i]
		if _is_word_char(c):
			var start := i
			while i < n and _is_word_char(lower[i]):
				i += 1
			var raw := lower.substr(start, i - start).replace("'", "")
			if raw.is_empty():
				continue
			# English copy borrows Spanish words ("páramo"); its rules only know plain vowels.
			var phones := spanish_word(raw, start) if lang == &"es" else english_word(_fold_accents(raw), start)
			if phones.is_empty():
				continue
			tokens.append({
				&"type": &"word", &"text": raw, &"phones": phones, &"ci": start, &"end": i,
				&"func": raw in FUNC_WORDS[lang], &"wh": raw in WH[lang],
				&"last_letter": _base_letter(raw[raw.length() - 1]),
				&"stress_hint": english_stress_hint(raw) if lang == &"en" else {},
			})
			continue
		if PUNCT.contains(c):
			tokens.append({&"type": &"punct", &"ch": c, &"ci": i})
		i += 1
	# Spanish "por qué" is a two-word interrogative.
	for k in tokens.size() - 1:
		if tokens[k].get(&"text", "") == "por" and tokens[k + 1].get(&"text", "") == "qué":
			tokens[k][&"wh"] = true
	return tokens


# A letter is anything with case (covers á, ñ, ü); the apostrophe joins words.
static func _is_word_char(c: String) -> bool:
	return c == "'" or c.to_upper() != c.to_lower()


static func _base_letter(c: String) -> String:
	return ACCENTED.get(c, c)


static func _fold_accents(w: String) -> String:
	for c: String in ACCENTED:
		w = w.replace(c, ACCENTED[c])
	return w


static func _at(w: String, i: int) -> String:
	return w[i] if i >= 0 and i < w.length() else ""


static func _in(set: String, c: String) -> bool:
	return c != "" and set.contains(c)


static func _phone(sym: String, ci: int, accent: bool = false) -> Dictionary:
	return {&"sym": StringName(sym), &"ci": ci, &"accent": accent, &"soft": false}


# ---------------------------------------------------------------- Spanish
static func spanish_word(w: String, ci0: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var n := w.length()
	var i := 0
	while i < n:
		var c := w[i]
		var nx := _at(w, i + 1)
		var nx2 := _at(w, i + 2)
		if _in("aeiouáéíóúü", c):
			out.append(_phone(_base_letter(c), ci0 + i, ACCENTED.has(c) and c != "ü"))
			i += 1
			continue
		match c:
			"c":
				if nx == "h":
					out.append(_phone("ch", ci0 + i)); i += 1
				elif _in("eéií", nx):
					out.append(_phone("s", ci0 + i))
				else:
					out.append(_phone("k", ci0 + i))
			"q":
				out.append(_phone("k", ci0 + i))
				if nx == "u":
					i += 1
			"g":
				if _in("eéií", nx):
					out.append(_phone("x", ci0 + i))
				elif nx == "u" and _in("eéií", nx2):
					out.append(_phone("g", ci0 + i)); i += 1
				else:
					out.append(_phone("g", ci0 + i))
			"l":
				if nx == "l":
					out.append(_phone("J", ci0 + i)); i += 1
				else:
					out.append(_phone("l", ci0 + i))
			"r":
				var prev := _at(w, i - 1)
				if nx == "r":
					out.append(_phone("rr", ci0 + i)); i += 1
				elif i == 0 or _in("nls", prev):
					out.append(_phone("rr", ci0 + i))
				else:
					out.append(_phone("r", ci0 + i))
			"ñ": out.append(_phone("ny", ci0 + i))
			"j": out.append(_phone("x", ci0 + i))
			"z": out.append(_phone("s", ci0 + i))   # seseo
			"v": out.append(_phone("b", ci0 + i))
			"h": pass                               # silent
			"x":
				out.append(_phone("k", ci0 + i)); out.append(_phone("s", ci0 + i))
			"y":
				if n == 1 or i == n - 1:
					out.append(_phone("i", ci0 + i))  # "y", "hoy", "muy"
				else:
					out.append(_phone("J", ci0 + i))
			"w": out.append(_phone("w", ci0 + i))
			_:
				if _in("bdfkmnpst", c):
					out.append(_phone(c, ci0 + i))
		i += 1
	# Unaccented i/u next to another vowel become glides (diphthongs).
	for k in out.size():
		var p: Dictionary = out[k]
		if (p[&"sym"] != &"i" and p[&"sym"] != &"u") or p[&"accent"]:
			continue
		var nxp: Variant = out[k + 1] if k + 1 < out.size() else null
		var pvp: Variant = out[k - 1] if k > 0 else null
		if (_is_es_vowel(nxp) and nxp[&"sym"] != p[&"sym"]) or (_is_es_vowel(pvp) and pvp[&"sym"] != p[&"sym"]):
			p[&"sym"] = &"j" if p[&"sym"] == &"i" else &"w"
	# b/d/g lenite to approximants after anything but a nasal (and d after l).
	for k in range(1, out.size()):
		var pv: StringName = out[k - 1][&"sym"]
		if pv in [&"m", &"n", &"ny", &"ng"]:
			continue
		match out[k][&"sym"]:
			&"b": out[k][&"sym"] = &"B"
			&"g": out[k][&"sym"] = &"G"
			&"d":
				if pv != &"l":
					out[k][&"sym"] = &"D"
	# n before a labial or velar assimilates.
	for k in out.size() - 1:
		if out[k][&"sym"] != &"n":
			continue
		var nxs: StringName = out[k + 1][&"sym"]
		if nxs in [&"p", &"b", &"B", &"m"]:
			out[k][&"sym"] = &"m"
		elif nxs in [&"k", &"g", &"G", &"x"]:
			out[k][&"sym"] = &"ng"
	return out


static func _is_es_vowel(p: Variant) -> bool:
	return p != null and String(p[&"sym"]) in ["a", "e", "i", "o", "u"]


# ---------------------------------------------------------------- English
static func english_word(w: String, ci0: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if EN_DICT.has(w):
		for sym: String in EN_DICT[w].split(" "):
			out.append(_phone(sym, ci0))
		return out
	var n := w.length()
	# Silent final e: "make", "hope" (but not "he", "the", "be").
	var silent_e := n > 2 and w[n - 1] == "e" and not _in("aeiou", w[n - 2]) and w[n - 2] != "l"
	# Magic-e: V C e# lengthens V; also V C es# / V C ed#.
	var magic_idx := -1
	if n > 2:
		var start := -1
		if w.ends_with("e"):
			start = n - 3
		elif w.ends_with("es") or w.ends_with("ed"):
			start = n - 4
		if start >= 0 and _in("aeiou", w[start]) and not _in("aeiouwy", w[start + 1]) and w[start + 2] == "e":
			magic_idx = start
	var i := 0
	while i < n:
		var c := w[i]
		var nx := _at(w, i + 1)
		var nx2 := _at(w, i + 2)
		var pv := _at(w, i - 1)
		var rest := w.substr(i)
		# ---- multi-letter units first
		if rest.begins_with("tion") or rest.begins_with("sion"):
			out.append(_phone("sh", ci0 + i)); out.append(_phone("ax", ci0 + i + 1)); out.append(_phone("n", ci0 + i + 3))
			i += 4; continue
		if rest.begins_with("tch"):
			out.append(_phone("ch", ci0 + i)); i += 3; continue
		if rest.begins_with("dge"):
			out.append(_phone("jh", ci0 + i)); i += 3; continue
		if rest.begins_with("igh"):
			out.append(_phone("aa", ci0 + i)); out.append(_phone("j", ci0 + i)); i += 3; continue
		if rest.begins_with("ough"):
			out.append(_phone("ao", ci0 + i)); i += 4; continue
		if i == n - 2 and rest == "le" and n > 3 and not _in("aeiou", pv):
			out.append(_phone("ax", ci0 + i)); out.append(_phone("l", ci0 + i)); i += 2; continue
		if i == n - 2 and rest == "ed" and n > 3:
			var p := _last_sym(out)
			if p == "t" or p == "d":
				out.append(_phone("ih", ci0 + i)); out.append(_phone("d", ci0 + i + 1))
			elif p in ["p", "k", "f", "s", "sh", "ch", "th"]:
				out.append(_phone("t", ci0 + i + 1))
			else:
				out.append(_phone("d", ci0 + i + 1))
			i += 2; continue
		if c == "c" and nx == "h": out.append(_phone("ch", ci0 + i)); i += 2; continue
		if c == "s" and nx == "h": out.append(_phone("sh", ci0 + i)); i += 2; continue
		if c == "t" and nx == "h": out.append(_phone("dh" if w in DH_WORDS else "th", ci0 + i)); i += 2; continue
		if c == "p" and nx == "h": out.append(_phone("f", ci0 + i)); i += 2; continue
		if c == "w" and nx == "h": out.append(_phone("w", ci0 + i)); i += 2; continue
		if c == "c" and nx == "k": out.append(_phone("k", ci0 + i)); i += 2; continue
		if c == "q" and nx == "u":
			out.append(_phone("k", ci0 + i)); out.append(_phone("w", ci0 + i + 1)); i += 2; continue
		if i == 0 and c == "w" and nx == "r": out.append(_phone("R", ci0 + i)); i += 2; continue
		if i == 0 and c == "k" and nx == "n": out.append(_phone("n", ci0 + i)); i += 2; continue
		if c == "g" and nx == "h": i += 2; continue
		if c == "n" and nx == "g" and not _in("aeiou", nx2): out.append(_phone("ng", ci0 + i)); i += 2; continue
		if c == "n" and nx == "k": out.append(_phone("ng", ci0 + i)); i += 1; continue

		# ---- vowels (r-colouring dropped: en-GB is non-rhotic)
		if _in("aeiou", c) or (c == "y" and i > 0):
			if c == "e" and i == n - 1 and silent_e:
				i += 1; continue
			if c == "e" and i == n - 1 and n <= 3:
				out.append(_phone("iy", ci0 + i)); i += 1; continue
			var two := c + nx
			var vv: String = EN_VOWEL_PAIRS.get(two, "")
			if two == "ow":
				vv = "ow w" if (i + 2 == n and n > 3) else "aa w"
			if vv != "" and c != "y":
				var after_r := _at(w, i + 2) == "r" and not _is_vy(_at(w, i + 3), i + 3)
				if after_r:
					var rv: String = EN_VOWEL_PAIRS_BEFORE_R.get(two, vv)
					for s: String in rv.split(" "):
						out.append(_phone(s, ci0 + i))
					i += 3; continue
				for s: String in vv.split(" "):
					out.append(_phone(s, ci0 + i))
				i += 2; continue
			# r-coloured single vowel
			if nx == "r" and not _is_vy(nx2, i + 2):
				var rv1: String = {"a": "aa", "e": "er", "i": "er", "o": "ao", "u": "er", "y": "er"}[c]
				out.append(_phone(rv1, ci0 + i))
				i += 2; continue
			if c == "y":
				# word-final y: "happy" -> iy, "my/fly/sky" (one vowel letter) -> aa j
				if i == n - 1:
					var other_vowel := false
					for k in i:
						if _in("aeiou", w[k]):
							other_vowel = true
					if other_vowel:
						out.append(_phone("iy", ci0 + i))
					else:
						out.append(_phone("aa", ci0 + i)); out.append(_phone("j", ci0 + i))
				elif not _in("aeiou", pv) and i > 0:
					out.append(_phone("ih", ci0 + i))
				else:
					out.append(_phone("j", ci0 + i))
				i += 1; continue
			if i == magic_idx:
				for s: String in {"a": "ey j", "e": "iy", "i": "aa j", "o": "ax w", "u": "j uw"}[c].split(" "):
					out.append(_phone(s, ci0 + i))
				i += 1; continue
			if c == "a" and (rest.begins_with("all") or rest.begins_with("alk") or _last_sym(out) == "w"):
				out.append(_phone("ao", ci0 + i)); i += 1; continue
			out.append(_phone({"a": "ae", "e": "eh", "i": "ih", "o": "ao", "u": "ah"}[c], ci0 + i))
			i += 1; continue

		# ---- single consonants
		if c == pv and not _in("aeiou", c):
			i += 1; continue  # doubled consonant
		match c:
			"c": out.append(_phone("s" if _in("eiy", nx) else "k", ci0 + i))
			"g":
				out.append(_phone("jh" if (nx == "e" and i == n - 2) else "g", ci0 + i))
			"j": out.append(_phone("jh", ci0 + i))
			"x":
				out.append(_phone("k", ci0 + i)); out.append(_phone("s", ci0 + i))
			"y": out.append(_phone("j", ci0 + i))
			"r": out.append(_phone("R", ci0 + i))
			"s":
				var prev_sym := _last_sym(out)
				var voiced_prev := prev_sym != "" and not prev_sym in ["p", "t", "k", "f", "th", "s", "sh", "ch"]
				if (i == n - 1 and voiced_prev and n > 2) or (_in("aeiou", pv) and _in("aeiou", nx) and i > 0):
					out.append(_phone("z", ci0 + i))
				else:
					out.append(_phone("s", ci0 + i))
			_:
				if _in("bdfhklmnptvwz", c):
					out.append(_phone(c, ci0 + i))
		i += 1
	return out


static func _is_vy(c: String, i: int) -> bool:
	return _in("aeiou", c) or (c == "y" and i > 0)


static func _last_sym(out: Array[Dictionary]) -> String:
	return String(out[-1][&"sym"]) if not out.is_empty() else ""


## Where English stress falls: {index} from the start, or {from_end} syllables back.
static func english_stress_hint(w: String) -> Dictionary:
	if EN_STRESS.has(w):
		return {&"index": EN_STRESS[w]}
	for suffix: String in ["tion", "sion", "cian", "ic", "ical"]:
		if w.ends_with(suffix):
			return {&"from_end": 2 if w.ends_with("ical") else 1}
	if w.ends_with("ity") or w.ends_with("ety"):
		return {&"from_end": 2}
	if w.length() > 4:
		for prefix: String in ["be", "de", "re", "un", "ex", "con", "com", "pre", "a"]:
			if w.begins_with(prefix) and w.length() > prefix.length() and not _in("aeiou", w[prefix.length()]):
				return {&"index": 1}
	return {&"index": 0}
