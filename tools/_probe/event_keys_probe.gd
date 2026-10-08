extends SceneTree
# Temporary probe (2026-10-08): every key compiled events carry, with types, per kind.

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var music := root.get_node_or_null("Music")
	var table = music.table
	music.table = null
	var seen := {}
	var done := {}
	for area in table.areas:
		var path: String = table.score_path(area)
		if done.has(path):
			continue
		done[path] = true
		var d := SfzMusicDirector.new()
		d.table = table
		root.add_child(d)
		await process_frame
		await d.preload_area(area, SfzMusicDirector.Hold.SCORES)
		for p in d._prepared:
			var plan: Dictionary = d._prepared[p]._plan
			var all: Array = plan["head"] + plan["tail"]
			for body in plan["bodies"]:
				all += body
			for e: Dictionary in all:
				for k in e:
					var sig := "%s.%s:%s" % [e["kind"], k, type_string(typeof(e[k]))]
					seen[sig] = seen.get(sig, 0) + 1
		d.queue_free()
		await process_frame
	var keys := seen.keys()
	keys.sort()
	for k in keys:
		print("EVKEY %s %d" % [k, seen[k]])
	quit(0)
