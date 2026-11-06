extends SceneTree
# Temporary probe (score-data sizing, 2026-10-08): what a compiled plan holds.

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var music := root.get_node_or_null("Music")
	if music != null:
		music.table = null
	var director := SfzMusicDirector.new()
	root.add_child(director)
	await create_timer(1.0).timeout
	for area: String in ["overworld.exploration", "overworld.combat", "main_menu"]:
		var table := director.table
		var ensemble := SfzEnsemble.load_from(table.ensemble_path(area))
		var score: SfzScore = SfzScoreParser.parse_file(table.score_path(area))
		var s0 := int(Performance.get_monitor(Performance.MEMORY_STATIC))
		var player := director._player(0)
		await player.prepare(score, ensemble)
		var mem := int(Performance.get_monitor(Performance.MEMORY_STATIC)) - s0
		var plan: Dictionary = player._plan
		var head: Array = plan["head"]
		var tail: Array = plan["tail"]
		var bodies: Array = plan["bodies"]
		var n := head.size() + tail.size()
		for b: Array in bodies:
			n += b.size()
		var keys := {}
		for e: Dictionary in head:
			keys[e.size()] = keys.get(e.size(), 0) + 1
		var kinds := {}
		for e: Dictionary in head:
			kinds[e["kind"]] = kinds.get(e["kind"], 0) + 1
		var sample: Dictionary = head[head.size() / 2] if head.size() > 0 else {}
		print("EVENTS %s: %.2f MB, events %d (head %d, tail %d, bodies %d x ~%d), %.0f B/event" % [
			area, mem / 1048576.0, n, head.size(), tail.size(), bodies.size(),
			(bodies[0] as Array).size() if bodies.size() > 0 else 0, float(mem) / max(n, 1)])
		print("EVENTS   plan keys %s; dict sizes in head %s; kinds %s" % [plan.keys(), keys, kinds])
		print("EVENTS   sample %s" % sample)
		var bytes := var_to_bytes(plan).size()
		print("EVENTS   serialized plan %.2f MB" % (bytes / 1048576.0))
		player.queue_free()
		await process_frame
	quit(0)
