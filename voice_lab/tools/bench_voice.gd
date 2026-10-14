extends SceneTree
# GDScript cost breakdown of the coordinator voice, per second of speech.
#   godot --path . --headless -s voice_lab/tools/bench_voice.gd
# (voice_lab/ is .gdignore'd, so this runs by path and never ships.)
func _initialize() -> void:
	var base: VoiceProfile = load("res://resources/voices/coordinator.tres")
	var text := "Te damos la bienvenida al páramo. Esta tierra y su agua son sagradas."
	var t0 := Time.get_ticks_usec()
	for i in 10:
		VoicePlan.build(text, &"es", base)
	var plan_ms := (Time.get_ticks_usec() - t0) / 10000.0
	var plan := VoicePlan.build(text, &"es", base)
	print("plan + frames: %.2f ms per line (%.1f s of speech)" % [plan_ms, plan.duration])
	for reverb: float in [base.reverb_mix, 0.0]:
		var v: VoiceProfile = base.duplicate()
		v.reverb_mix = reverb
		var best := INF
		for run in 3:
			var synth := VoiceSynth.new()
			var out := PackedFloat32Array()
			var s0 := Time.get_ticks_usec()
			synth.start(plan, v)
			while not synth.is_finished():
				synth.fill(out, 4096)
			best = minf(best, (Time.get_ticks_usec() - s0) / 1000.0 / (out.size() / v.tract_rate()))
		print("synth, reverb %.2f: %.1f ms per s of speech" % [reverb, best])
	quit()
