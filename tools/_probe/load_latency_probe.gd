extends SceneTree
# Temporary probe (2026-10-08): how long does an area's ensemble take to load once
# its scores are already prepared? RAM_AREA=<area>. Times preload_area(SCORES), then
# ENSEMBLE three times (release between), then go_to() from a scores-only state.

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var music := root.get_node_or_null("Music")
	if music != null:
		music.table = null
	var area := OS.get_environment("RAM_AREA")
	var d := SfzMusicDirector.new()
	root.add_child(d)
	await create_timer(1.0).timeout
	var t := Time.get_ticks_usec()
	await d.preload_area(area, SfzMusicDirector.Hold.SCORES)
	print("LAT scores %.0f ms" % ((Time.get_ticks_usec() - t) / 1000.0))
	for i in 3:
		t = Time.get_ticks_usec()
		var worst := 0
		var last := Time.get_ticks_usec()
		d.preload_area(area, SfzMusicDirector.Hold.ENSEMBLE)
		while d.preloaded() != area or d.is_busy():
			await process_frame
			var now := Time.get_ticks_usec()
			worst = maxi(worst, now - last)
			last = now
		print("LAT ensemble #%d %.0f ms, worst frame %.1f ms" % [i, (Time.get_ticks_usec() - t) / 1000.0, worst / 1000.0])
		await create_timer(0.5).timeout
		await d.release_preload()
		await create_timer(0.5).timeout
	t = Time.get_ticks_usec()
	await d.go_to(area)
	print("LAT go_to from scores %.0f ms" % ((Time.get_ticks_usec() - t) / 1000.0))
	await d.silence()
	quit(0)
