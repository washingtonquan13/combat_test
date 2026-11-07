extends SceneTree
# Temporary probe (2026-10-08): what a scores-only preload holds, per area.

func _initialize() -> void:
	_run.call_deferred()


func _st() -> int:
	return int(Performance.get_monitor(Performance.MEMORY_STATIC))


func _run() -> void:
	var music := root.get_node_or_null("Music")
	var table = music.table
	music.table = null
	for area in table.areas:
		var d := SfzMusicDirector.new()
		d.table = table
		root.add_child(d)
		await process_frame
		var before := _st()
		var ok := await d.preload_area(area, SfzMusicDirector.Hold.SCORES)
		await process_frame
		var after := _st()
		print("SCOREMEM %-28s ok=%s static delta %.2f MB" % [area, ok, (after - before) / 1048576.0])
		d.queue_free()
		await process_frame
		await process_frame
	quit(0)
