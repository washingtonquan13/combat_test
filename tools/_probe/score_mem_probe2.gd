extends SceneTree
# Temporary probe (2026-10-08): parsed score vs compiled plan, and event counts.

func _initialize() -> void:
	_run.call_deferred()


func _st() -> int:
	return int(Performance.get_monitor(Performance.MEMORY_STATIC))


func _run() -> void:
	var music := root.get_node_or_null("Music")
	var table = music.table
	music.table = null
	for area in ["overworld.combat", "overworld.exploration", "main_menu"]:
		var b0 := _st()
		var sc := SfzScoreParser.parse_file(table.score_path(area))
		var b1 := _st()
		var d := SfzMusicDirector.new()
		d.table = table
		root.add_child(d)
		await process_frame
		var b2 := _st()
		await d.preload_area(area, SfzMusicDirector.Hold.SCORES)
		await process_frame
		var b3 := _st()
		var n := 0
		var keys := 0
		for path in d._prepared:
			var plan: Dictionary = d._prepared[path]._plan
			var all: Array = plan["head"] + plan["tail"]
			for body in plan["bodies"]:
				all += body
			n += all.size()
			for e in all:
				keys += e.size()
			print("SCOREMEM   %s: head %d bodies %s tail %d" % [path.get_file(), plan["head"].size(),
				plan["bodies"].map(func(x): return x.size()), plan["tail"].size()])
		print("SCOREMEM %s parse alone %.2f MB, preload %.2f MB, %d events, %.1f keys/event, %.0f B/event (preload - parse)" % [
			area, (b1 - b0) / 1048576.0, (b3 - b2) / 1048576.0, n, float(keys) / maxi(n, 1),
			float(b3 - b2 - (b1 - b0)) / maxi(n, 1)])
		sc = null
		d.queue_free()
		await process_frame
		await process_frame
	quit(0)
