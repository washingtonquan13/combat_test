extends SceneTree
# Temporary probe (RAM measurement, 2026-10-08). Headless, one configuration per process.
#   RAM_MODE=ensemble  RAM_AREA=<area> [RAM_SCALE=0.5] [RAM_PLAY=30]
#       preload_area() (the director's own filters, held), per-layer table, then
#       go_to() and play RAM_PLAY s tracking voices/streamed, then silence().
#   RAM_MODE=layers    RAM_AREA=<area>
#       captures the director's filters, unloads, then loads each layer alone
#       and reports its private-bytes delta beside its heads and region count.
#   RAM_MODE=synth     fixed cost of a synth: N one-region generator synths at V voices.

var director: SfzMusicDirector


func _initialize() -> void:
	_run.call_deferred()


func _mb(b: int) -> String:
	return "%.1f" % (b / 1048576.0)


func _priv() -> int:
	return SfzInstrument.get_process_private_bytes()


func _settle(sec: float = 0.5) -> int:
	await create_timer(sec).timeout
	SfzInstrument.trim_heap()
	await process_frame
	return _priv()


func _run() -> void:
	var music := root.get_node_or_null("Music")
	if music != null:
		music.table = null
	var mode := OS.get_environment("RAM_MODE")
	var scale := OS.get_environment("RAM_SCALE")
	if scale != "":
		ProjectSettings.set_setting(SfzSettings.PRELOAD_SCALE, float(scale))
	print("RAMISO mode=%s area=%s preload_scale=%s" % [mode, OS.get_environment("RAM_AREA"),
		SfzSettings.get_value(SfzSettings.PRELOAD_SCALE)])
	if mode == "synth":
		await _synth()
		quit(0)
		return
	director = SfzMusicDirector.new()
	root.add_child(director)
	var base := await _settle(2.0)
	var st0 := int(Performance.get_monitor(Performance.MEMORY_STATIC))
	print("RAMISO base private %s MB static %s MB" % [_mb(base), _mb(st0)])
	var area := OS.get_environment("RAM_AREA")
	var ok := await director.preload_area(area)
	var loaded := _priv()
	var loaded_trim := await _settle(1.0)
	print("RAMISO static after preload %s MB (delta %s MB) objects %d" % [
		_mb(int(Performance.get_monitor(Performance.MEMORY_STATIC))),
		_mb(int(Performance.get_monitor(Performance.MEMORY_STATIC)) - st0),
		int(Performance.get_monitor(Performance.OBJECT_COUNT))])
	var c: SfzConductor = director.conductors()[1]
	if not c.is_loaded():
		c = director.conductors()[0]
	print("RAMISO preload ok=%s private %s MB (trimmed %s) delta %s MB heads %s MB shared %s MB streamed %s MB" % [
		ok, _mb(loaded), _mb(loaded_trim), _mb(loaded_trim - base), _mb(director.heads_memory()),
		_mb(SfzInstrument.get_shared_sample_bytes()), _mb(SfzInstrument.get_streamed_bytes())])
	var layers: Array = []
	var tot_regions := 0
	print("RAMISO layer  part/layer | sfz | voices | preload_frames | regions | preloaded files | heads MB | ks | notes")
	for p in c._stacks:
		for e in c._stacks[p]:
			var inst: SfzInstrument = e.instrument
			tot_regions += inst.get_region_count()
			print("RAMISO layer  %s/%s | %s | %d | %d | %d | %d | %s | %d | %d" % [p, e.layer.name,
				e.layer.sfz_path.get_file(), inst.max_voices, inst.preload_frames, inst.get_region_count(),
				inst.get_preloaded_sample_count(), _mb(inst.get_sample_bytes()), e.keyswitches.size(), e.notes.size()])
			layers.append({"name": "%s/%s" % [p, e.layer.name], "path": e.layer.sfz_path,
				"keys": e.keyswitches, "notes": e.notes, "voices": inst.max_voices,
				"frames": inst.preload_frames, "cab": e.layer.cabinet_path})
	print("RAMISO total regions %d layers %d" % [tot_regions, layers.size()])
	if OS.get_environment("RAM_MODE") == "layers":
		await director.silence()
		await _layers(layers)
		quit(0)
		return
	var play := float(OS.get_environment("RAM_PLAY")) if OS.get_environment("RAM_PLAY") != "" else 30.0
	await director.go_to(area)
	var sc: SfzScore = director.foreground().score
	var score_len := sc.loop_end() if sc.has_loop() else sc.duration()
	if play < 0.0:
		play = score_len + 5.0
	print("RAMISO score duration %.1f s, loop end %.1f s, loop length %.1f s" % [sc.duration(),
		sc.loop_end() if sc.has_loop() else -1.0, sc.loop_length() if sc.has_loop() else -1.0])
	print("RAMISO score length %.1f s, playing %.1f s" % [score_len, play])
	var t_end := Time.get_ticks_msec() + int(play * 1000.0)
	var peaks := {}
	var sum_peak := 0
	var streamed_peak := 0
	var priv_peak := 0
	var next_print := 0
	c = director.conductor()
	while Time.get_ticks_msec() < t_end:
		await process_frame
		var total := 0
		for p in c._stacks:
			for e in c._stacks[p]:
				var v: int = e.instrument.get_active_voices()
				total += v
				var k := "%s/%s" % [p, e.layer.name]
				peaks[k] = maxi(peaks.get(k, 0), v)
		sum_peak = maxi(sum_peak, total)
		streamed_peak = maxi(streamed_peak, SfzInstrument.get_streamed_bytes())
		priv_peak = maxi(priv_peak, _priv())
		if Time.get_ticks_msec() >= next_print:
			next_print = Time.get_ticks_msec() + 5000
			print("RAMISO play t=%d private %s MB streamed %s MB" % [Time.get_ticks_msec(), _mb(_priv()), _mb(SfzInstrument.get_streamed_bytes())])
	print("RAMISO played %.0f s: private peak %s MB, streamed peak %s MB, summed active voice peak %d, starved %d" % [
		play, _mb(priv_peak), _mb(streamed_peak), sum_peak, SfzInstrument.get_starved_voices()])
	for p in c._stacks:
		for e in c._stacks[p]:
			var k := "%s/%s" % [p, e.layer.name]
			print("RAMISO voices %-22s cap %3d peak %3d" % [k, e.instrument.max_voices, peaks.get(k, 0)])
			print("RAMISO mix %-22s max_mix_frames %d" % [k, e.instrument.get_max_mix_frames()])
	print("RAMISO static after play %s MB (delta %s MB)" % [
		_mb(int(Performance.get_monitor(Performance.MEMORY_STATIC))),
		_mb(int(Performance.get_monitor(Performance.MEMORY_STATIC)) - st0)])
	await director.silence()
	var after := await _settle(2.0)
	print("RAMISO after silence private %s MB (base %s, residue %s MB) streamed %s MB shared %s MB" % [
		_mb(after), _mb(base), _mb(after - base), _mb(SfzInstrument.get_streamed_bytes()),
		_mb(SfzInstrument.get_shared_sample_bytes())])
	quit(0)


func _load_one(path: String, keys: PackedInt32Array, notes: PackedInt32Array, voices: int,
		frames: int, cab: String) -> Array:
	var inst := SfzInstrument.new()
	inst.sfz_path = path
	inst.keyswitches = keys
	inst.notes = notes
	inst.cabinet_path = cab
	inst.max_voices = voices
	inst.preload_frames = frames
	var p := AudioStreamPlayer.new()
	p.stream = inst
	root.add_child(p)
	p.play()
	while not inst.is_ready():
		await process_frame
	return [inst, p]


func _unload(pairs: Array) -> void:
	for pair in pairs:
		pair[1].stop()
		pair[1].queue_free()
	var deadline := Time.get_ticks_msec() + 20000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		var any := false
		for pair in pairs:
			if pair[0].is_ready():
				any = true
		if not any and SfzInstrument.get_pending_frees() == 0:
			break


func _layers(layers: Array) -> void:
	print("RAMISO iso  layer | regions | heads MB | private delta MB | non-head MB | non-head KB/region")
	var sum := 0
	for l in layers:
		var before := await _settle(0.5)
		var pair: Array = await _load_one(l.path, l.keys, l.notes, l.voices, l.frames, l.cab)
		var after := await _settle(0.5)
		var inst: SfzInstrument = pair[0]
		var heads := inst.get_sample_bytes()
		var regions := inst.get_region_count()
		var d := after - before
		sum += d
		print("RAMISO iso  %s | %d | %s | %s | %s | %s" % [l.name, regions, _mb(heads), _mb(d), _mb(d - heads),
			"%.1f" % ((d - heads) / 1024.0 / regions) if regions > 0 else "-"])
		await _unload([pair])
	print("RAMISO iso sum of deltas %s MB" % _mb(sum))


func _synth() -> void:
	var dir := OS.get_environment("RAM_SYNTH_DIR")
	var n := 10
	for sfz in ["one-sine.sfz", "fx-sine.sfz"]:
		for v in [8, 64, 256]:
			var before := await _settle(1.0)
			var pairs: Array = []
			for i in n:
				pairs.append(await _load_one(dir.path_join(sfz), PackedInt32Array(), PackedInt32Array(), v, 4096, ""))
			var after := await _settle(1.0)
			print("RAMISO synth %s voices %3d: %d synths, delta %s MB = %.0f KB per synth" % [
				sfz, v, n, _mb(after - before), (after - before) / 1024.0 / n])
			await _unload(pairs)
