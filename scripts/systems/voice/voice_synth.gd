class_name VoiceSynth
extends RefCounted

## Tract-lite: Pink Trombone's glottis and tract shaping over a small waveguide,
## streamed block by block from a VoicePlan. A port of voice_lab/js/engines.js
## (LiteTract, LiteSynth, renderTrombone's driver, the reverb in smoothChain) and
## of the parts of pink-trombone-mod's Glottis.js / TractShaper.js it reuses
## (MIT, Copyright 2017 Neil Thapen; modular port by Christian d'Heureuse).
##
## Why it is cheap enough to run live: Pink Trombone runs 44 sections twice per
## sample. A tube's first resonance is about rate / (4 * sections), so
## VoiceProfile.tract_sections() sections stepped ONCE per sample at the synth rate
## is the same acoustic length: 8 sections at 16 kHz. Measured on an M1 (desktop,
## Godot 4.6.1): ~45 ms of GDScript per second of speech at 22 kHz / 11 sections,
## less at 16 kHz. Formant scale is the tract's sample rate: the generator plays
## the stream back at VoiceProfile.tract_rate().
##
## Usage: start(plan, profile), then fill() as many samples as the output wants
## until is_finished().

const LIP_START := 39
const TIP_START := 32
const BLADE_START := 10
const NOSE_START := 17
const N := 44                       # Pink Trombone's control points
const VELUM_OPEN := 0.4
const VELUM_CLOSED := 0.01
const REVERB_TAIL := 0.6

var _v: VoiceProfile
var _plan: VoicePlan
var _rate: float
var _inv_rate: float
var _block: int
var _frame: int = 0
var _finished: bool = true
var _tail_left: int = 0

# Output block being drained.
var _buf := PackedFloat32Array()
var _buf_pos: int = 0

# ---- glottis (Glottis.js)
var _g_sample_count: int = 0
var _g_intensity: float = 0.0
var _g_loudness: float = 1.0
var _g_smooth_freq: float = 140.0
var _g_time_in_wave: float = 0.0
var _g_new_tense: float = 0.6
var _g_old_tense: float = 0.6
var _g_new_freq: float = 140.0
var _g_old_freq: float = 140.0
var _g_wave_len: float = 1.0 / 140.0
var _g_alpha: float
var _g_e0: float
var _g_epsilon: float
var _g_shift: float
var _g_delta: float
var _g_te: float
var _g_omega: float
var _g_target_tense: float = 0.6
var _g_target_freq: float = 140.0
var _g_intensity_target: float = 0.0
var _noise := FastNoiseLite.new()
var _asp_bpf := PackedFloat64Array([0, 0, 0, 0, 0, 0, 0, 0])   # b0 b2 a1 a2 x1 x2 y1 y2

# ---- tract shaper (TractShaper.js), on 44 control points
var _diameter := PackedFloat64Array()
var _target := PackedFloat64Array()
var _nose0: float = VELUM_CLOSED      # noseDiameter[0], the velum
var _velum_target: float = VELUM_CLOSED
var _tongue_index: float = 12.9
var _tongue_diameter: float = 2.43
var _last_obstruction: int = -1

# ---- lite waveguide
var _m: int
var _R := PackedFloat64Array()
var _L := PackedFloat64Array()
var _jR := PackedFloat64Array()
var _jL := PackedFloat64Array()
var _refl := PackedFloat64Array()
var _new_refl := PackedFloat64Array()
var _area := PackedFloat64Array()
var _t_count: int = 0
var _t_time: float = 0.0
var _nasal: float = 0.0
var _murmur: float = 0.0
var _murmur_a: float
var _fric_bpf := PackedFloat64Array([0, 0, 0, 0, 0, 0, 0, 0])
var _transients: Array[Vector4] = []        # position, start, strength, exponent (lifetime 0.2 s)
var _turbulence: Array[Vector4] = []        # position, diameter, start, end (NAN while active)
var _active_fric_seg: int = -1
var _active_point: int = -1

# ---- driver
var _tongue_of: Array[Vector2] = []
var _lead_frames: int
var _voiced_tense: float
var _rng := RandomNumberGenerator.new()

# ---- post
var _combs: Array[PackedFloat32Array] = []
var _comb_pos := PackedInt32Array()
var _comb_store := PackedFloat32Array()
var _allpass: Array[PackedFloat32Array] = []
var _allpass_pos := PackedInt32Array()
var _warm := PackedFloat64Array()   # low-pass b0 b1 b2 a1 a2 x1 x2 y1 y2, empty when off


func start(plan: VoicePlan, v: VoiceProfile) -> void:
	_v = v
	_plan = plan
	_rate = v.tract_rate()
	_inv_rate = 1.0 / _rate
	_block =roundi(_rate * VoicePlan.FRAME_DT)
	_m = v.tract_sections()
	_frame = 0
	_finished = false
	_tail_left = roundi(REVERB_TAIL * _rate) if v.reverb_mix > 0.0 else 0
	_buf.resize(_block)
	_buf_pos = _block
	_rng.seed = VoicePlan.hash_str(v.seed) ^ 0x7a11
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.frequency = 1.0
	_noise.seed = _rng.randi()
	_reset_glottis()
	_reset_tract()
	_reset_post()
	_prepare_driver()
	# Settle with the glottis off, as the lab does, then drop it.
	for i in 8:
		_synth_block()


func is_finished() -> bool:
	return _finished


func stop() -> void:
	_finished = true


## Append up to `count` mono samples to `out`. Returns how many were written; fewer
## than `count` only once the line (and its reverb tail) is over.
func fill(out: PackedFloat32Array, count: int) -> int:
	var written := 0
	while written < count and not _finished:
		if _buf_pos >= _buf.size():
			if not _next_block():
				break
		var take := mini(count - written, _buf.size() - _buf_pos)
		for i in take:
			out.append(_buf[_buf_pos + i])
		_buf_pos += take
		written += take
	return written


# ---------------------------------------------------------------- per block
func _next_block() -> bool:
	if _frame < _plan.frame_count:
		_drive(_frame)
		_synth_block()
		_shape_block(_frame)
		_frame += 1
	elif _tail_left > 0:
		_buf.fill(0.0)
		_tail_left -= _buf.size()
	else:
		_finished = true
		return false
	_post_block()
	_buf_pos = 0
	return true


func _prepare_driver() -> void:
	var segs := _plan.segments
	_tongue_of.clear()
	for k in segs.size():
		_tongue_of.append(_tongue_for(segs, k))
	_lead_frames = maxi(0, roundi((_v.tract_lead_ms / 1000.0) / VoicePlan.FRAME_DT))
	_voiced_tense = clampf(lerpf(0.35, 0.95, _v.tense) - _v.breath * 0.3, 0.05, 1.0)
	_active_fric_seg = -1
	_active_point = -1


# Vowels and glides use their own tongue; consonants borrow the next vowel's.
static func _tongue_for(segs: Array[Dictionary], k: int) -> Vector2:
	var own: Dictionary = segs[k][&"p"]
	if not own.is_empty() and own[&"tongue"] != Vector2.ZERO:
		return own[&"tongue"]
	for j in range(k + 1, segs.size()):
		var p: Dictionary = segs[j][&"p"]
		if not p.is_empty() and p[&"tongue"] != Vector2.ZERO:
			return p[&"tongue"]
	for j in range(k - 1, -1, -1):
		var p: Dictionary = segs[j][&"p"]
		if not p.is_empty() and p[&"tongue"] != Vector2.ZERO:
			return p[&"tongue"]
	return Vector2(20.7, 2.8)


func _release_at(s: Dictionary) -> float:
	var dur: float = s[&"dur"]
	return dur - minf(0.012, dur * 0.3) if s[&"p"][&"cls"] == &"stop" else dur * 0.45


func _open_now(s: Dictionary, local: float) -> bool:
	var cls: StringName = s[&"p"][&"cls"]
	return (cls == &"stop" or cls == &"affric") and local >= _release_at(s)


# Softness opens constrictions: stops and taps stop short of a full closure, so no
# release transient fires; fricatives widen toward 0.7, where turbulence fades out.
static func _soft_diameter(s: Dictionary, d: float) -> float:
	var soft: float = s[&"soft"]
	if soft <= 0.0:
		return d
	match s[&"p"][&"cls"]:
		&"stop", &"affric", &"tap", &"trill":
			return lerpf(d, 1.0, soft * 0.7)
		&"fric", &"approx":
			return lerpf(d, 0.7, soft * 0.6)
	return d


func _drive(f: int) -> void:
	var segs := _plan.segments
	var t := f * VoicePlan.FRAME_DT
	var k_now := _plan.seg[f]
	var k_lead := _plan.seg[mini(_plan.frame_count - 1, f + _lead_frames)]
	var cur: Dictionary = segs[k_now]
	var ahead: Dictionary = segs[k_lead]
	var local := t - float(cur[&"t0"])

	var tg := _tongue_of[k_lead]
	_tongue_index = tg.x
	_tongue_diameter = tg.y
	for i in N:
		_target[i] = _rest_diameter(i)
	_apply_con(cur, true, local)
	if k_lead != k_now:
		_apply_con(ahead, false, local)
	for s: Dictionary in [cur, ahead]:
		var p: Dictionary = s[&"p"]
		if not p.is_empty() and p[&"lips"]:
			_reduce_target(41.0, maxf(0.0, float(p[&"lip_d"]) - 0.3))
	var nasal: bool = (not cur[&"p"].is_empty() and cur[&"p"][&"nasal"]) \
			or (not ahead[&"p"].is_empty() and ahead[&"p"][&"nasal"])
	_velum_target = VELUM_OPEN if nasal else VELUM_CLOSED

	# Frication: one turbulence point for the life of a fricative (or affricate release).
	var p_now: Dictionary = cur[&"p"]
	var fric_now: bool = not p_now.is_empty() and (p_now[&"cls"] == &"fric" or p_now[&"cls"] == &"approx" \
			or (p_now[&"cls"] == &"affric" and _open_now(cur, local)))
	if fric_now and _active_fric_seg != k_now:
		if _active_point >= 0:
			_turbulence[_active_point].w = _t_time
		var con: Vector2 = p_now[&"con"]
		var d := _soft_diameter(cur, 0.6 if p_now[&"cls"] == &"affric" else con.y)
		_turbulence.append(Vector4(con.x, d, _t_time, NAN))
		_active_point = _turbulence.size() - 1
		_active_fric_seg = k_now
	elif not fric_now and _active_point >= 0:
		_turbulence[_active_point].w = _t_time
		_active_point = -1
		_active_fric_seg = -1
	for i in range(_turbulence.size() - 1, -1, -1):
		var e := _turbulence[i].w
		if not is_nan(e) and _t_time - e >= 0.2:
			_turbulence.remove_at(i)
			if _active_point > i:
				_active_point -= 1

	# Glottis targets.
	var vo := _plan.voicing[f]
	if _plan.asp[f] > 0.0:
		_g_intensity_target = 1.0
		_g_target_tense = 0.05
	elif vo > 0.0:
		_g_intensity_target = minf(1.0, 0.4 + vo)
		_g_target_tense = _voiced_tense
	elif _plan.fric[f] > 0.0:
		_g_intensity_target = 0.3
		_g_target_tense = 0.0
	else:
		_g_intensity_target = 0.0
		_g_target_tense = _voiced_tense
	var creak_on := _plan.creak[f] > 0.0 and _rng.randf() < _plan.creak[f] * 0.5
	_g_target_freq = _plan.f0[f] * (1.0 + (_v.jitter / 100.0) * (_rng.randf() * 2.0 - 1.0)) * (0.55 if creak_on else 1.0)


func _apply_con(s: Dictionary, is_cur: bool, local: float) -> void:
	var p: Dictionary = s[&"p"]
	if p.is_empty():
		return
	var con: Vector2 = p[&"con"]
	if con.x < 0.0:
		return
	if is_cur and _open_now(s, local):
		if p[&"cls"] == &"affric":
			_reduce_target(con.x, 0.3)
		return
	var dd := con.y
	if p[&"cls"] == &"trill":
		var lt := local if is_cur else 0.0
		dd = 0.0 if fmod(lt * 28.0, 1.0) < 0.5 else 0.9
	if p[&"cls"] == &"tap" and is_cur and local > float(s[&"dur"]) * 0.7:
		return
	_reduce_target(con.x, maxf(0.0, _soft_diameter(s, dd) - 0.3))


# Output gain per frame: syllable loudness, voiceless frication lifted, chop silent.
func _gain_at(q: int) -> float:
	var g := _plan.syl_amp[q]
	if _plan.fric[q] > 0.0 and _plan.voicing[q] == 0.0:
		g *= maxf(1.0, _v.fric_boost * (1.0 - 0.6 * _v.softness))
	if g == 0.0:
		return 0.0 if _plan.chop[q] > 0.0 else 0.45
	return g


func _shape_block(f: int) -> void:
	var g0 := _gain_at(f)
	var g1 := _gain_at(mini(_plan.frame_count - 1, f + 1))
	var shim := 1.0 + (_v.shimmer / 100.0) * (_rng.randf() * 2.0 - 1.0)
	var is_pause: bool = _plan.segments[_plan.seg[f]][&"p"].is_empty()
	var n := _buf.size()
	for i in n:
		var g := 1.0 if is_pause else lerpf(g0, g1, float(i) / n)
		_buf[i] *= g * shim


# ---------------------------------------------------------------- glottis
func _reset_glottis() -> void:
	_g_sample_count = 0
	_g_intensity = 0.0
	_g_loudness = 1.0
	_g_smooth_freq = _v.base_pitch
	_g_new_freq = _v.base_pitch
	_g_old_freq = _v.base_pitch
	_g_time_in_wave = 0.0
	_g_new_tense = 0.6
	_g_old_tense = 0.6
	_g_target_tense = 0.6
	_g_target_freq = _v.base_pitch
	_g_intensity_target = 0.0
	_set_bpf(_asp_bpf, 500.0, 0.5)
	_setup_waveform(0.0)


func _glottis_adjust(dt: float) -> void:
	var delta := dt * _rate / 512.0
	var new_time := _g_sample_count / _rate + dt
	# Intensity: straight to the driver's target at 0.3 per block (the lab's override).
	if _g_intensity < _g_intensity_target:
		_g_intensity = minf(_g_intensity_target, _g_intensity + 0.3)
	else:
		_g_intensity = maxf(_g_intensity_target, _g_intensity - 0.3)
	# Frequency: the stock slew is 10% per 512 samples; stepped pitch wants jumps.
	var rate := 0.1 * delta * (1.0 + 19.0 * _v.flat_pitch)
	if _g_intensity == 0.0:
		_g_smooth_freq = _g_target_freq
	elif _g_target_freq > _g_smooth_freq:
		_g_smooth_freq = minf(_g_smooth_freq * (1.0 + rate), _g_target_freq)
	elif _g_target_freq < _g_smooth_freq:
		_g_smooth_freq = maxf(_g_smooth_freq / (1.0 + rate), _g_target_freq)
	_g_old_freq = _g_new_freq
	_g_new_freq = maxf(10.0, _g_smooth_freq * (1.0 + _vibrato(new_time)))
	# Tenseness, with Pink Trombone's slow drift when natural wobble is on.
	_g_old_tense = _g_new_tense
	if _v.natural_wobble:
		_g_new_tense = maxf(0.0, _g_target_tense + 0.1 * _simplex(new_time * 0.46) + 0.05 * _simplex(new_time * 0.36))
	else:
		_g_new_tense = _g_target_tense


func _vibrato(time: float) -> float:
	var vib := (_v.vib_depth / 100.0) * sin(TAU * time * _v.vib_rate)
	if _v.natural_wobble:
		vib += 0.02 * _simplex(time * 4.07) + 0.04 * _simplex(time * 2.15)
	return vib


func _simplex(x: float) -> float:
	return _noise.get_noise_1d(x)


func _glottis_step(lambda: float) -> float:
	if _g_time_in_wave > _g_wave_len:
		_g_time_in_wave -= _g_wave_len
		_setup_waveform(lambda)
	var t := _g_time_in_wave / _g_wave_len
	var out: float
	if _v.glottal_source == VoiceProfile.GlottalSource.NATURAL:
		# The LF pulse inline: it is the shipped source and this runs every sample.
		if t > _g_te:
			out = (-exp(-_g_epsilon * (t - _g_te)) + _g_shift) / _g_delta
		else:
			out = _g_e0 * exp(_g_alpha * t) * sin(_g_omega * t)
		out *= _g_intensity * _g_loudness
	else:
		out = _waveform(t)
	var tt := _g_target_tense
	# Pure voice keeps breath noise only where the glottis is meant to be open.
	if not _v.pure_voice or tt < 0.2:
		var aspiration := _g_intensity * (1.0 - sqrt(tt)) * _noise_modulator() * _run_bpf(_asp_bpf, randf() * 2.0 - 1.0)
		out += aspiration * (0.2 if _v.pure_voice else 0.2 + 0.02 * _simplex(_g_sample_count / _rate * 1.99))
	_g_sample_count += 1
	_g_time_in_wave += _inv_rate
	return out


func _noise_modulator() -> float:
	var voiced := 0.1 + 0.2 * maxf(0.0, sin(TAU * _g_time_in_wave / _g_wave_len))
	return _g_target_tense * _g_intensity * voiced + (1.0 - _g_target_tense * _g_intensity) * 0.3


func _setup_waveform(lambda: float) -> void:
	var frequency := _g_old_freq * (1.0 - lambda) + _g_new_freq * lambda
	var tenseness := _g_old_tense * (1.0 - lambda) + _g_new_tense * lambda
	_g_wave_len = 1.0 / frequency
	_g_loudness = pow(maxf(0.0, tenseness), 0.25)
	if _v.glottal_source != VoiceProfile.GlottalSource.NATURAL:
		return
	# Liljencrants-Fant parameters from Rd, as Glottis.setupWaveform.
	var rd := clampf(3.0 * (1.0 - tenseness), 0.5, 2.7)
	var ra := -0.01 + 0.048 * rd
	var rk := 0.224 + 0.118 * rd
	var rg := (rk / 4.0) * (0.5 + 1.2 * rk) / (0.11 * rd - ra * (0.5 + 1.2 * rk))
	var ta := ra
	var tp := 1.0 / (2.0 * rg)
	var te := tp + tp * rk
	var epsilon := 1.0 / ta
	var shift := exp(-epsilon * (1.0 - te))
	var delta := 1.0 - shift
	var rhs_integral := ((1.0 / epsilon) * (shift - 1.0) + (1.0 - te) * shift) / delta
	var total_lower := rhs_integral - (te - tp) / 2.0
	var total_upper := -total_lower
	var omega := PI / tp
	var s := sin(omega * te)
	var y := -PI * s * total_upper / (tp * 2.0)
	var z := log(y)
	var alpha := z / (tp / 2.0 - te)
	var e0 := -1.0 / (s * exp(alpha * te))
	_g_alpha = alpha
	_g_e0 = e0
	_g_epsilon = epsilon
	_g_shift = shift
	_g_delta = delta
	_g_te = te
	_g_omega = omega


func _waveform(t: float) -> float:
	var y: float
	match _v.glottal_source:
		VoiceProfile.GlottalSource.NATURAL:
			if t > _g_te:
				y = (-exp(-_g_epsilon * (t - _g_te)) + _g_shift) / _g_delta
			else:
				y = _g_e0 * exp(_g_alpha * t) * sin(_g_omega * t)
			return y * _g_intensity * _g_loudness
		VoiceProfile.GlottalSource.PULSE:
			var w := 0.18
			y = ((0.5 - 0.5 * cos(TAU * t / w) if t < w else 0.0) - w / 2.0) * 2.0
		VoiceProfile.GlottalSource.SAW:
			y = 2.0 * t - 1.0 - _blep(t, 1.0 / (_g_wave_len * _rate))
		_:
			var dt := 1.0 / (_g_wave_len * _rate)
			y = (1.0 if t < 0.5 else -1.0) + _blep(t, dt) - _blep(fmod(t + 0.5, 1.0), dt)
	return y * 0.6 * _g_intensity * _g_loudness


static func _blep(t: float, dt: float) -> float:
	if t < dt:
		t /= dt
		return t + t - t * t - 1.0
	if t > 1.0 - dt:
		t = (t - 1.0) / dt
		return t * t + t + t + 1.0
	return 0.0


# ---------------------------------------------------------------- tract shaper
func _reset_tract() -> void:
	_diameter.resize(N)
	_target.resize(N)
	_tongue_index = 12.9
	_tongue_diameter = 2.43
	for i in N:
		_diameter[i] = _rest_diameter(i)
		_target[i] = _diameter[i]
	_nose0 = VELUM_CLOSED
	_velum_target = VELUM_CLOSED
	_last_obstruction = -1
	_R.resize(_m); _R.fill(0.0)
	_L.resize(_m); _L.fill(0.0)
	_jR.resize(_m); _jR.fill(0.0)
	_jL.resize(_m + 1); _jL.fill(0.0)
	_refl.resize(_m); _refl.fill(0.0)
	_new_refl.resize(_m); _new_refl.fill(0.0)
	_area.resize(_m)
	_t_count = 0
	_t_time = 0.0
	_murmur = 0.0
	_murmur_a = 1.0 - exp(-TAU * 250.0 / _rate)
	_set_bpf(_fric_bpf, 1000.0, 0.5)
	_transients.clear()
	_turbulence.clear()
	_block_parameters()


func _rest_diameter(i: int) -> float:
	if i < 7:
		return 0.6
	if i < BLADE_START:
		return 1.1
	if i >= LIP_START:
		return 1.5
	var t := 1.1 * PI * (_tongue_index - i) / (TIP_START - BLADE_START)
	var fixed_tongue := 2.0 + (_tongue_diameter - 2.0) / 1.5
	var curve := (1.5 - fixed_tongue + 1.7) * cos(t)
	if i == BLADE_START - 2 or i == LIP_START - 1:
		curve *= 0.8
	if i == BLADE_START or i == LIP_START - 2:
		curve *= 0.94
	return 1.5 - curve


## TractUi.reduceTargetDiametersByTouch: pull targets down to `diameter` around `index`.
func _reduce_target(index: float, diameter: float) -> void:
	if index < 2.0 or index >= N or diameter >= 3.0:
		return
	var width: float
	if index < 25.0:
		width = 10.0
	elif index >= TIP_START:
		width = 5.0
	else:
		width = 10.0 - 5.0 * (index - 25.0) / (TIP_START - 25.0)
	for i in range(-ceili(width) - 1, ceili(width + 1.0)):
		if i >= width + 1.0:
			break
		var p := roundi(index) + i
		if p < 0 or p >= N:
			continue
		var relpos := absf(p - index) - 0.5
		var shrink: float
		if relpos <= 0.0:
			shrink = 0.0
		elif relpos > width:
			shrink = 1.0
		else:
			shrink = 0.5 * (1.0 - cos(PI * relpos / width))
		if diameter < _target[p]:
			_target[p] = diameter + (_target[p] - diameter) * shrink


func _shape_tract(dt: float) -> void:
	var amount := dt * _v.tract_speed
	var new_last := -1
	for i in N:
		var d := _diameter[i]
		if d <= 0.0:
			new_last = i
		var slow_return: float
		if i < NOSE_START:
			slow_return = 0.6
		elif i >= TIP_START:
			slow_return = 1.0
		else:
			slow_return = 0.6 + 0.4 * (i - NOSE_START) / float(TIP_START - NOSE_START)
		_diameter[i] = _move_towards(d, _target[i], slow_return * amount, 2.0 * amount)
	# A closure opening with the nose shut fires Pink Trombone's release click.
	if _last_obstruction > -1 and new_last == -1 and _nose0 < 0.223 and _v.plosive_click > 0.0:
		_transients.append(Vector4(_last_obstruction, _t_time, 0.3 * _v.plosive_click, 200.0))
	_last_obstruction = new_last
	_nose0 = _move_towards(_nose0, _velum_target, amount * 0.25, amount * 0.1)


static func _move_towards(current: float, target: float, up: float, down: float) -> float:
	return minf(current + up, target) if current < target else maxf(current - down, target)


# ---------------------------------------------------------------- lite waveguide
func _block_parameters() -> void:
	var per := float(N) / _m
	for k in _m:
		var a := 0.0
		var c := 0
		var i := floori(k * per)
		while i < floori((k + 1) * per) and i < N:
			a += _diameter[i] * _diameter[i]
			c += 1
			i += 1
		_area[k] = a / c if c > 0 else 0.0
	for k in _m:
		_refl[k] = _new_refl[k]
	for k in range(1, _m):
		_new_refl[k] = 0.999 if _area[k] == 0.0 else (_area[k - 1] - _area[k]) / (_area[k - 1] + _area[k])
	_nasal = clampf((_nose0 - 0.01) / 0.39, 0.0, 1.0)


func _synth_block() -> void:
	var n := _buf.size()
	var dt := n / _rate
	_glottis_adjust(dt)
	_shape_tract(dt)
	_block_parameters()
	# Hot loop: members copied to locals (packed arrays are references, so writes
	# land), and the click / frication calls skipped when nothing is pending, which
	# is most samples. Both lists only grow at block start (_drive, _shape_tract).
	var m := _m
	var damping := _v.tract_damping
	var R := _R
	var L := _L
	var jR := _jR
	var jL := _jL
	var refl := _refl
	var new_refl := _new_refl
	var buf := _buf
	var oral := (1.0 - 0.6 * _nasal) * 0.25
	var nose := _nasal * 0.8 * 0.25
	var murmur_a := _murmur_a
	var inv_rate := 1.0 / _rate
	var has_clicks := not _transients.is_empty()
	var has_noise := not _turbulence.is_empty()
	var inv_n := 1.0 / n
	for i in n:
		var lambda := i * inv_n
		var g := _glottis_step(lambda)
		if has_clicks:
			_process_transients()
		if has_noise:
			_add_turbulence()
		jR[0] = L[0] * 0.75 + g
		jL[m] = R[m - 1] * -0.85
		for k in range(1, m):
			var w := (refl[k] + (new_refl[k] - refl[k]) * lambda) * (R[k - 1] + L[k])
			jR[k] = R[k - 1] - w
			jL[k] = L[k] + w
		for k in m:
			R[k] = jR[k] * damping
			L[k] = jL[k + 1] * damping
		_murmur += murmur_a * (g - _murmur)
		_t_count += 1
		_t_time = _t_count * inv_rate
		buf[i] = R[m - 1] * oral + _murmur * nose


func _section(pos44: float) -> int:
	return clampi(roundi(pos44 * _m / N), 1, _m - 1)


func _process_transients() -> void:
	for i in range(_transients.size() - 1, -1, -1):
		var tr := _transients[i]
		var age := _t_time - tr.y
		if age > 0.2:
			_transients.remove_at(i)
			continue
		var amp := tr.z * pow(2.0, -tr.w * age)
		var k := _section(tr.x)
		_R[k] += amp / 2.0
		_L[k] += amp / 2.0


func _add_turbulence() -> void:
	for p: Vector4 in _turbulence:
		if p.y <= 0.0:
			continue
		var inten: float
		if is_nan(p.w):
			inten = clampf((_t_time - p.z) / 0.1, 0.0, 1.0)
		else:
			inten = clampf(1.0 - (_t_time - p.w) / 0.1, 0.0, 1.0)
		if inten <= 0.0:
			continue
		var thin := clampf(8.0 * (0.7 - p.y), 0.0, 1.0)
		var open := clampf(30.0 * (p.y - 0.3), 0.0, 1.0)
		var nz := 0.66 * _run_bpf(_fric_bpf, randf() * 2.0 - 1.0) * inten * _noise_modulator() * thin * open
		var k := _section(p.x)
		_R[k] += nz / 2.0
		_L[k] += nz / 2.0


# ---------------------------------------------------------------- post
# Freeverb-style room (4 damped combs into 2 all-passes), delays scaled from the
# lab's 44.1 kHz tunings to this rate.
func _reset_post() -> void:
	_combs.clear()
	_allpass.clear()
	_comb_pos = PackedInt32Array([0, 0, 0, 0])
	_comb_store = PackedFloat32Array([0, 0, 0, 0])
	_allpass_pos = PackedInt32Array([0, 0])
	# Warmth: the lab's 12 dB/oct low-pass, 12 kHz at 0 down to 2.5 kHz at 1. Skipped
	# when the cutoff is above what this rate can carry (warmth 0.1 at 17.6 kHz is).
	_warm.clear()
	var cutoff := 12000.0 * pow(2500.0 / 12000.0, _v.warmth)
	if _v.warmth > 0.0 and cutoff < 0.45 * _rate:
		var w0 := TAU * cutoff / _rate
		var alpha := sin(w0) / (2.0 * 0.6)
		var a0 := 1.0 + alpha
		var cw := cos(w0)
		_warm = PackedFloat64Array([(1.0 - cw) / 2.0 / a0, (1.0 - cw) / a0, (1.0 - cw) / 2.0 / a0,
				-2.0 * cw / a0, (1.0 - alpha) / a0, 0, 0, 0, 0])
	if _v.reverb_mix <= 0.0:
		return
	for len44: int in [1116, 1188, 1277, 1356]:
		var line := PackedFloat32Array()
		line.resize(maxi(1, roundi(len44 * _rate / 44100.0)))
		_combs.append(line)
	for len44: int in [556, 441]:
		var line := PackedFloat32Array()
		line.resize(maxi(1, roundi(len44 * _rate / 44100.0)))
		_allpass.append(line)


func _post_block() -> void:
	var mix := _v.reverb_mix
	var gain := _v.output_gain
	var warm := not _warm.is_empty()
	for i in _buf.size():
		var x := _buf[i]
		if warm:
			var w := _warm
			var y0 := w[0] * x + w[1] * w[5] + w[2] * w[6] - w[3] * w[7] - w[4] * w[8]
			w[6] = w[5]; w[5] = x; w[8] = w[7]; w[7] = y0
			x = y0
		if mix > 0.0:
			x = _reverb_sample(x, mix)
		x *= gain
		# Soft ceiling: transparent below 0.8, never past 1.
		var ax := absf(x)
		if ax > 0.8:
			x = signf(x) * (0.8 + 0.2 * tanh((ax - 0.8) / 0.2))
		_buf[i] = x


func _reverb_sample(x: float, mix: float) -> float:
	var wet := 0.0
	for c in 4:
		var line := _combs[c]          # a reference: writes land in _combs[c]
		var p := _comb_pos[c]
		var y := line[p]
		var store := y * 0.6 + _comb_store[c] * 0.4
		_comb_store[c] = store
		line[p] = x + store * 0.72
		p += 1
		_comb_pos[c] = 0 if p == line.size() else p
		wet += y * 0.25
	for a in 2:
		var line := _allpass[a]
		var p := _allpass_pos[a]
		var b := line[p]
		line[p] = wet + b * 0.5
		wet = b - wet
		p += 1
		_allpass_pos[a] = 0 if p == line.size() else p
	return x * (1.0 - 0.5 * mix) + wet * mix


# ---------------------------------------------------------------- biquad
# RBJ band-pass, constant 0 dB peak; state packed as [b0, b2, a1, a2, x1, x2, y1, y2].
func _set_bpf(f: PackedFloat64Array, freq: float, q: float) -> void:
	var w0 := TAU * freq / _rate
	var alpha := sin(w0) / (2.0 * q)
	var a0 := 1.0 + alpha
	f[0] = alpha / a0
	f[1] = -alpha / a0
	f[2] = -2.0 * cos(w0) / a0
	f[3] = (1.0 - alpha) / a0


static func _run_bpf(f: PackedFloat64Array, x: float) -> float:
	var y := f[0] * x + f[1] * f[5] - f[2] * f[6] - f[3] * f[7]
	f[5] = f[4]; f[4] = x; f[7] = f[6]; f[6] = y
	return y
