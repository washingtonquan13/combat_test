extends SceneTree
# Temporary probe: time from asking for the title music to its first note.

var t0 := 0
var _seen_ready := {}
var _seen_clock := {}
var _log: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _ms() -> float:
	return (Time.get_ticks_usec() - t0) / 1000.0


func _run() -> void:
	var director := SfzMusicDirector.new()
	root.add_child(director)
	await process_frame
	for c: SfzConductor in director.conductors():
		c.ensemble_ready.connect(func(_e): _log.append("  ensemble_ready  %7.1f ms" % _ms()))
	director.area_changed.connect(func(a): _log.append("  area_changed    %7.1f ms" % _ms()))
	t0 = Time.get_ticks_usec()
	_watch(director)
	var ok: bool = await director.go_to("main_menu")
	for l in _log: print(l)
	print("MENU_LOAD ok=%s total %.1f ms read=%s" % [ok, _ms(), director.last_handoff().get("read")])
	quit(0)


func _watch(director: SfzMusicDirector) -> void:
	var attached := false
	var stage := ""
	while true:
		await process_frame
		var now_stage := "read" if director._reading != null else ""
		for child in director.get_children():
			if child is SfzScorePlayer and child._compiling != null:
				now_stage = "compile"
		if now_stage != stage:
			_log.append("  stage %-8s %7.1f ms" % [now_stage if now_stage != "" else "-", _ms()])
			stage = now_stage
		for c: SfzConductor in director.conductors():
			if not attached and not c._stacks.is_empty():
				attached = true
				_log.append("  attach begun    %7.1f ms" % _ms())
			for part_name in c._stacks:
				for entry in c._stacks[part_name]:
					var inst = entry.instrument
					var key := "%s/%d" % [part_name, inst.get_instance_id()]
					if not _seen_ready.has(key) and inst.is_ready():
						_seen_ready[key] = true
						_log.append("    ready   %-10s %7.1f ms" % [part_name, _ms()])
					if not _seen_clock.has(key) and inst.get_playback_time() > 0.0:
						_seen_clock[key] = true
						_log.append("    clock   %-10s %7.1f ms" % [part_name, _ms()])
		if director.area != "":
			var p := director.foreground()
			var c := director.conductor()
			_log.append("  first downbeat in %.1f ms after area_changed (clock %.3f, downbeat %.3f)" % [
				(p.downbeat() - c.now()) * 1000.0 if true else -1.0,
				c.now() if true else -1.0, p.downbeat()])
			return
