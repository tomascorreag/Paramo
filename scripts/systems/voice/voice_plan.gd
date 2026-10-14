class_name VoicePlan
extends RefCounted

## Text -> utterance plan -> 5 ms control frames for the mumble voice. A port of
## voice_lab/js/plan.js (buildPlan + the buildFrames fields tract-lite reads);
## keep the two in step. The hash and the RNG are bit-exact ports, so the plan for
## a line (phones, syllables, stress, durations, pitch) matches the lab's exactly;
## tests/test_voice.gd checks that against tests/fixtures/voice_plan_fixture.json.
##
## Unity bridge: a plain C# data class built by a static factory; nothing here
## touches the scene tree, so it is safe to build on demand when a line is said.

const FRAME_DT: float = 0.005
const LEAD_IN: float = 0.06
const TAIL: float = 0.12
const PENTA: Array[int] = [0, 2, 4, 7, 9, 12]
const OBSTRUENT: Array[StringName] = [&"stop", &"affric", &"fric", &"tap", &"trill", &"approx", &"aspirate"]

## {sym, p (phone Dictionary, or {} for a pause), t0, dur, ci, phrase, syl, stressed, final, soft}
var segments: Array[Dictionary] = []
## {i0, i1, t0, t1, stressed, phrase, final, syms}
var syllables: Array[Dictionary] = []
## {type, pause, punct_ci, t0, t1, syl0, syl1, nuclear}
var phrases: Array[Dictionary] = []
## [time, characters revealed], ascending in time.
var reveal: Array[Vector2] = []
var duration: float = 0.0
var lang: StringName = &"es"

# Frames: one value per FRAME_DT.
var frame_count: int = 0
var f0 := PackedFloat32Array()
var voicing := PackedFloat32Array()
var asp := PackedFloat32Array()
var fric := PackedFloat32Array()
var syl_amp := PackedFloat32Array()
var creak := PackedFloat32Array()
var chop := PackedFloat32Array()
var seg := PackedInt32Array()


static func build(text: String, language: StringName, v: VoiceProfile) -> VoicePlan:
	var plan := VoicePlan.new()
	plan.lang = language
	plan._build_plan(text, v)
	plan._build_frames(v)
	return plan


# ---------------------------------------------------------------- rng
## FNV-1a over UTF-16 code units, as the lab's hashStr.
static func hash_str(s: String) -> int:
	var h: int = 2166136261
	for i in s.length():
		h ^= s.unicode_at(i)
		h = _imul(h, 16777619)
	return h


## Math.imul for unsigned 32-bit operands, result as unsigned 32-bit. Split so no
## intermediate product exceeds 2^48.
static func _imul(a: int, b: int) -> int:
	a &= 0xFFFFFFFF
	b &= 0xFFFFFFFF
	return ((a & 0xFFFF) * b + ((((a >> 16) * b) & 0xFFFF) << 16)) & 0xFFFFFFFF


## mulberry32, bit-exact with the lab's.
class Rng:
	var _a: int

	func _init(seed_value: int) -> void:
		_a = seed_value & 0xFFFFFFFF

	func next() -> float:
		_a = (_a + 0x6D2B79F5) & 0xFFFFFFFF
		var t: int = VoicePlan._imul(_a ^ (_a >> 15), 1 | _a)
		t = ((t + VoicePlan._imul(t ^ (t >> 7), 61 | t)) & 0xFFFFFFFF) ^ t
		return float((t ^ (t >> 14)) & 0xFFFFFFFF) / 4294967296.0


static func _smooth(t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


static func _is_vowel(p: Dictionary) -> bool:
	return not p.is_empty() and p[&"cls"] == &"vowel"


static func _is_sonorant(p: Dictionary) -> bool:
	return not p.is_empty() and p[&"cls"] in [&"vowel", &"glide", &"liquid"]


# ---------------------------------------------------------------- syllables
static func syllabify(phones: Array[Dictionary]) -> Array[Vector2i]:
	var nuclei: Array[int] = []
	for i in phones.size():
		if _is_vowel(VoicePhones.get_phone(phones[i][&"sym"])):
			nuclei.append(i)
	if nuclei.is_empty():
		return [Vector2i(0, phones.size())]
	var bounds: Array[int] = [0]
	for k in range(1, nuclei.size()):
		var a := nuclei[k - 1]
		var b := nuclei[k]
		var between := b - a - 1
		var cut: int
		if between <= 1:
			cut = b - between
		else:
			var c1 := VoicePhones.get_phone(phones[b - 2][&"sym"])
			var c2 := VoicePhones.get_phone(phones[b - 1][&"sym"])
			var obstruent_liquid: bool = (c1[&"cls"] == &"stop" or c1[&"sym"] == &"f" or c1[&"cls"] == &"approx") \
					and c2[&"sym"] in [&"l", &"r", &"R"]
			var cons_glide: bool = c2[&"cls"] == &"glide" and c1[&"cls"] != &"glide"
			cut = b - 2 if (obstruent_liquid or cons_glide) else b - 1
		bounds.append(cut)
	var out: Array[Vector2i] = []
	for k in bounds.size():
		out.append(Vector2i(bounds[k], bounds[k + 1] if k + 1 < bounds.size() else phones.size()))
	return out


static func _stress_index(word: Dictionary, phones: Array[Dictionary], sylls: Array[Vector2i], language: StringName) -> int:
	var n := sylls.size()
	if language == &"es":
		for s in n:
			for i in range(sylls[s].x, sylls[s].y):
				if phones[i][&"accent"]:
					return s
		if n == 1:
			return 0
		return n - 2 if "aeiouns".contains(String(word[&"last_letter"])) else n - 1
	var hint: Dictionary = word[&"stress_hint"]
	if hint.has(&"from_end"):
		return clampi(n - 1 - int(hint[&"from_end"]), 0, n - 1)
	return clampi(int(hint.get(&"index", 0)), 0, n - 1)


static func _scramble(word: Dictionary, amount: float, seed_hash: int, language: StringName) -> Array[Dictionary]:
	var phones: Array[Dictionary] = []
	for ph: Dictionary in word[&"phones"]:
		phones.append(ph.duplicate())
	if amount <= 0.0:
		return phones
	var rng := Rng.new(hash_str(word[&"text"]) ^ seed_hash)
	for i in phones.size():
		if rng.next() >= amount:
			continue
		var p := VoicePhones.get_phone(phones[i][&"sym"])
		var pool: Array = VoicePhones.VOWELS[language] if p[&"cls"] == &"vowel" else VoicePhones.CONSONANTS[language]
		phones[i][&"sym"] = pool[floori(rng.next() * pool.size())]
	return phones


static func _final_consonants(phones: Array[Dictionary], mode: VoiceProfile.FinalConsonants) -> Array[Dictionary]:
	if mode == VoiceProfile.FinalConsonants.KEEP:
		return phones
	var cut := phones.size()
	while cut > 0 and VoicePhones.get_phone(phones[cut - 1][&"sym"])[&"cls"] in OBSTRUENT:
		cut -= 1
	if cut == phones.size() or cut == 0:
		return phones
	if mode == VoiceProfile.FinalConsonants.DROP:
		var kept: Array[Dictionary] = []
		for i in cut:
			kept.append(phones[i])
		return kept
	for i in range(cut, phones.size()):
		phones[i][&"soft"] = true
	return phones


# ---------------------------------------------------------------- plan
func _new_phrase() -> Dictionary:
	return {&"words": [], &"type": &"statement", &"pause": 0.3, &"punct_ci": -1}


func _build_plan(text: String, v: VoiceProfile) -> void:
	var seed_hash := hash_str(v.seed)
	var tokens := VoiceG2P.tokenize(text, lang)

	# Group words into phrases at punctuation. The open phrase lives in a one-slot
	# array: a GDScript lambda captures locals by value, so it could not reassign `cur`.
	var cur: Array[Dictionary] = [_new_phrase()]
	var close := func(type: StringName, pause: float, ci: int) -> void:
		if not cur[0][&"words"].is_empty():
			cur[0][&"type"] = type
			cur[0][&"pause"] = pause
			cur[0][&"punct_ci"] = ci
			phrases.append(cur[0])
		cur[0] = _new_phrase()
	for tok: Dictionary in tokens:
		if tok[&"type"] == &"word":
			cur[0][&"words"].append(tok)
			continue
		match tok[&"ch"]:
			",", ";", ":", "-", "—": close.call(&"continue", 0.14, tok[&"ci"])
			".", "…": close.call(&"statement", 0.34, tok[&"ci"])
			"!": close.call(&"exclaim", 0.34, tok[&"ci"])
			"?":
				var wh := false
				var words: Array = cur[0][&"words"]
				if lang == &"es":
					for w: Dictionary in words:
						wh = wh or w[&"wh"]
				elif not words.is_empty():
					wh = words[0][&"wh"]
				close.call(&"wh" if wh else &"yesno", 0.36, tok[&"ci"])
			"¿", "¡": close.call(&"continue", 0.14, -1)
	close.call(&"statement", 0.3, -1)

	var rng_dur := Rng.new(seed_hash ^ 0x9e3779b9)
	var t := LEAD_IN
	var speed := v.speed
	for pi in phrases.size():
		var ph: Dictionary = phrases[pi]
		ph[&"t0"] = t
		ph[&"syl0"] = syllables.size()
		var words: Array = ph[&"words"]
		var last_word := words.size() - 1
		for wi in words.size():
			var w: Dictionary = words[wi]
			var phones := _final_consonants(_scramble(w, v.scramble, seed_hash, lang), v.final_consonants)
			var sylls := syllabify(phones)
			var lone := words.size() == 1
			var stressed := -1 if (w[&"func"] and not lone) else _stress_index(w, phones, sylls, lang)
			# English reduces unstressed short vowels to schwa: "banana" -> b ax n ae n ax.
			if lang == &"en" and sylls.size() > 1:
				for si in sylls.size():
					if si == stressed:
						continue
					for i in range(sylls[si].x, sylls[si].y):
						if phones[i][&"sym"] in [&"ae", &"eh", &"ah", &"ao"]:
							phones[i][&"sym"] = &"ax"
			for si in sylls.size():
				var final_syl := wi == last_word and si == sylls.size() - 1
				var syl := {&"i0": segments.size(), &"t0": t, &"stressed": si == stressed, &"phrase": pi,
						&"final": final_syl, &"syms": []}
				for i in range(sylls[si].x, sylls[si].y):
					var p := VoicePhones.get_phone(phones[i][&"sym"])
					var cls: StringName = p[&"cls"]
					# Speech-rhythm stretches; even_rhythm pulls them toward 1.
					var mod := 1.0
					if cls == &"vowel":
						mod *= 1.25 if syl[&"stressed"] else 0.8
						if w[&"func"]:
							mod *= 0.8
					if final_syl:
						mod *= 1.45 if cls == &"vowel" else 1.15
					if ph[&"type"] == &"exclaim" and syl[&"stressed"]:
						mod *= 1.1
					mod *= 1.0 + (rng_dur.next() - 0.5) * 0.12
					var soft: float = 1.0 if phones[i][&"soft"] else v.softness
					var cons_shorten := 1.0 if cls in [&"vowel", &"glide"] else lerpf(1.0, 0.65, soft)
					var ms: float = VoicePhones.DUR[cls] * pow(mod, 1.0 - v.even_rhythm) * cons_shorten
					var dur := ms / 1000.0 / speed
					segments.append({&"sym": p[&"sym"], &"p": p, &"t0": t, &"dur": dur, &"ci": phones[i][&"ci"],
							&"phrase": pi, &"soft": soft, &"syl": syllables.size(), &"stressed": syl[&"stressed"],
							&"final": final_syl})
					reveal.append(Vector2(t, int(phones[i][&"ci"]) + 1))
					syl[&"syms"].append(p[&"sym"])
					t += dur
				syl[&"i1"] = segments.size()
				syl[&"t1"] = t
				syllables.append(syl)
			reveal.append(Vector2(t, w[&"end"]))
			if wi < last_word and v.word_gap_ms > 0.0:
				segments.append(_pause(t, v.word_gap_ms / 1000.0 / speed, pi))
				t += v.word_gap_ms / 1000.0 / speed
		ph[&"syl1"] = syllables.size()
		ph[&"t1"] = t
		if int(ph[&"punct_ci"]) >= 0:
			reveal.append(Vector2(t, int(ph[&"punct_ci"]) + 1))
		var pause: float = TAIL if pi == phrases.size() - 1 else float(ph[&"pause"]) / sqrt(speed)
		segments.append(_pause(t, pause, pi))
		t += pause
	# Nuclear (last stressed) syllable per phrase.
	for ph: Dictionary in phrases:
		ph[&"nuclear"] = -1
		for s in range(int(ph[&"syl1"]) - 1, int(ph[&"syl0"]) - 1, -1):
			if syllables[s][&"stressed"]:
				ph[&"nuclear"] = s
				break
		if ph[&"nuclear"] < 0:
			ph[&"nuclear"] = int(ph[&"syl1"]) - 1
	duration = t


static func _pause(t0: float, dur: float, phrase: int) -> Dictionary:
	return {&"sym": &"_", &"p": {}, &"t0": t0, &"dur": dur, &"phrase": phrase, &"syl": -1,
			&"soft": 0.0, &"stressed": false, &"final": false, &"ci": -1}


# ---------------------------------------------------------------- frames
static func quantize(s: float, mode: VoiceProfile.Quantize) -> float:
	match mode:
		VoiceProfile.Quantize.SEMITONE:
			# Math.round: half rounds up, unlike roundf's half-away-from-zero.
			return floorf(s + 0.5)
		VoiceProfile.Quantize.PENTATONIC:
			var octave := floorf(s / 12.0)
			var best := 0.0
			var best_d := INF
			for d in PENTA:
				var c := octave * 12.0 + d
				if absf(c - s) < best_d:
					best_d = absf(c - s)
					best = c
			return best
	return s


func _build_frames(v: VoiceProfile) -> void:
	var n := ceili(duration / FRAME_DT) + 1
	frame_count = n
	f0.resize(n)
	voicing.resize(n)
	asp.resize(n)
	fric.resize(n)
	syl_amp.resize(n)
	creak.resize(n)
	chop.resize(n)
	seg.resize(n)
	voicing.fill(0.0)
	asp.fill(0.0)
	fric.fill(0.0)
	syl_amp.fill(0.0)
	creak.fill(0.0)
	chop.fill(0.0)

	# ---- pitch contour in semitones above base, built per phrase
	var st := PackedFloat32Array()
	st.resize(n)
	st.fill(0.0)
	var rng := Rng.new(hash_str(v.seed) ^ 0x51ed27)
	var ph1 := rng.next() * 6.28
	var ph2 := rng.next() * 6.28
	for ph: Dictionary in phrases:
		var pt0: float = ph[&"t0"]
		var pt1: float = ph[&"t1"]
		var span := maxf(0.05, pt1 - pt0)
		var type: StringName = ph[&"type"]
		var accents: Array[Vector3] = []   # centre, width, amplitude
		for s in range(int(ph[&"syl0"]), int(ph[&"syl1"])):
			var syl: Dictionary = syllables[s]
			if not syl[&"stressed"]:
				continue
			var amp_st := v.accent_st * (1.15 if s == ph[&"nuclear"] else 0.8)
			if type == &"exclaim":
				amp_st *= 1.6
			if type == &"wh" and s == ph[&"syl0"]:
				amp_st *= 1.2
			if type == &"yesno" and s == ph[&"nuclear"]:
				amp_st = -0.4 * v.accent_st   # low nuclear accent before the rise
			var c: float = (float(syl[&"t0"]) + float(syl[&"t1"])) / 2.0
			for k in range(int(syl[&"i0"]), int(syl[&"i1"])):
				if _is_vowel(segments[k][&"p"]):
					c = float(segments[k][&"t0"]) + float(segments[k][&"dur"]) * 0.4
			accents.append(Vector3(c, maxf(0.045, (float(syl[&"t1"]) - float(syl[&"t0"])) * 0.45), amp_st))
		var last_syl: Dictionary = syllables[int(ph[&"syl1"]) - 1]
		var nuc: Dictionary = syllables[int(ph[&"nuclear"])]
		var k0 := maxi(0, floori(pt0 / FRAME_DT))
		var k1 := mini(n - 1, ceili(pt1 / FRAME_DT))
		for k in range(k0, k1 + 1):
			var t := k * FRAME_DT
			var u := clampf((t - pt0) / span, 0.0, 1.0)
			var s := v.declination * (0.6 - 1.6 * u)
			if type == &"exclaim":
				s += 2.0
			for a: Vector3 in accents:
				s += a.z * exp(-0.5 * pow((t - a.x) / a.y, 2.0))
			var last_u := _smooth((t - float(last_syl[&"t0"])) / maxf(0.03, float(last_syl[&"t1"]) - float(last_syl[&"t0"])))
			match type:
				&"statement": s -= v.fall_st * last_u
				&"wh": s -= v.fall_st * 1.2 * last_u
				&"exclaim": s -= v.fall_st * 1.4 * last_u
				&"continue": s += v.rise_st * 0.4 * last_u
				&"yesno":
					var nuc_c := (float(nuc[&"t0"]) + float(nuc[&"t1"])) / 2.0
					s += v.rise_st * _smooth((t - nuc_c) / maxf(0.05, pt1 - nuc_c))
			s += v.wander * (0.6 * sin(TAU * 1.3 * t + ph1) + 0.4 * sin(TAU * 3.1 * t + ph2))
			st[k] = s
			creak[k] = v.creak * (1.0 if u > 0.7 else 0.25)
	# Hold pitch through pauses: carry the last phrase value forward.
	var last := 0.0
	for k in n:
		var t := k * FRAME_DT
		var in_phrase := false
		for ph: Dictionary in phrases:
			if t >= float(ph[&"t0"]) and t <= float(ph[&"t1"]):
				in_phrase = true
				break
		if in_phrase:
			last = st[k]
		else:
			st[k] = last
	# Stepped pitch: one held note per syllable, sampled at the vowel (at its end on a
	# phrase-final syllable, so a question's rise survives).
	if v.flat_pitch > 0.0:
		for syl: Dictionary in syllables:
			var at: float = (float(syl[&"t0"]) + float(syl[&"t1"])) / 2.0
			for q in range(int(syl[&"i0"]), int(syl[&"i1"])):
				var sg: Dictionary = segments[q]
				if _is_vowel(sg[&"p"]):
					at = float(sg[&"t0"]) + float(sg[&"dur"]) * (0.95 if syl[&"final"] else 0.4)
			var note := quantize(st[mini(n - 1, roundi(at / FRAME_DT))], v.quantize)
			var q0 := maxi(0, floori(float(syl[&"t0"]) / FRAME_DT))
			var q1 := mini(n - 1, floori(float(syl[&"t1"]) / FRAME_DT))
			for q in range(q0, q1 + 1):
				st[q] = lerpf(st[q], note, v.flat_pitch)

	# ---- per-frame segment walk
	var k := 0
	for f in n:
		var t := f * FRAME_DT
		while k < segments.size() - 1 and t >= float(segments[k][&"t0"]) + float(segments[k][&"dur"]):
			k += 1
		var s: Dictionary = segments[k]
		var p: Dictionary = s[&"p"]
		seg[f] = k
		f0[f] = v.base_pitch * pow(2.0, st[f] / 12.0)
		if p.is_empty() or t < float(s[&"t0"]):
			continue
		var syl: Dictionary = syllables[int(s[&"syl"])]
		var ph: Dictionary = phrases[int(s[&"phrase"])]
		var amp := 1.0 if s[&"stressed"] else 0.72
		if ph[&"type"] == &"exclaim":
			amp *= 1.2
		if s[&"final"]:
			amp *= lerpf(1.0, 0.7, _smooth((t - float(syl[&"t0"])) / maxf(0.03, float(syl[&"t1"]) - float(syl[&"t0"]))))
		amp = lerpf(amp, 1.0, v.even_rhythm)
		syl_amp[f] = amp
		# Chop: a short silence at the end of every syllable.
		if v.chop_ms > 0.0 and t > float(syl[&"t1"]) - v.chop_ms / 1000.0 / v.speed:
			chop[f] = 1.0
			syl_amp[f] = 0.0
			continue
		var vo := 1.0
		var a := 0.0
		var fr := 0.0
		var local := t - float(s[&"t0"])
		var soft: float = s[&"soft"]
		var cls: StringName = p[&"cls"]
		var band: Vector3 = p[&"fric"]
		match cls:
			&"approx": fr = band.z * (1.0 - 0.7 * soft)
			&"aspirate":
				vo = 0.0; a = 0.7
			&"fric":
				vo = 0.5 if p[&"voiced"] else 0.0
				fr = band.z * (1.0 - 0.7 * soft)
			&"stop", &"affric":
				var dur: float = s[&"dur"]
				var rel_at := dur - minf(0.012, dur * 0.3) if cls == &"stop" else dur * 0.45
				if local < rel_at:
					vo = lerpf((0.3 if lang == &"es" else 0.12) if p[&"voiced"] else 0.0, 0.6, soft)
				else:
					vo = lerpf(0.5 if p[&"voiced"] else 0.0, 0.6, soft)
					if cls == &"affric":
						fr = band.z * (1.0 - 0.7 * soft)
		# Voice onset time after a voiceless stop or affricate.
		if _is_sonorant(p) and k > 0:
			var pv: Dictionary = segments[k - 1][&"p"]
			if not pv.is_empty() and pv[&"cls"] in [&"stop", &"affric"] and not pv[&"voiced"]:
				var vot := (0.012 if lang == &"es" else (0.05 if s[&"stressed"] else 0.025)) / v.speed
				if local < vot:
					vo = soft
					a = 0.6 * (1.0 - soft)
		voicing[f] = vo
		asp[f] = a * amp
		fric[f] = fr * amp
