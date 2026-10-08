extends SceneTree
# Temporary probe: where SfzScorePlayer._build spends its time on the title piece.


func _initialize() -> void:
	var table := SfzTransitions.load_from(SfzSettings.transitions_path())
	var score := SfzScoreParser.parse_file(table.score_path("main_menu"))
	var ensemble := SfzEnsemble.load_from(table.ensemble_path("main_menu"))
	for i in 4:
		if i == 2:
			ensemble = SfzEnsemble.load_from(table.ensemble_path("main_menu"))
		if i == 3:
			score = SfzScoreParser.parse_file(table.score_path("main_menu"))
		var player := SfzScorePlayer.new(null)
		player.compiler = load("res://tools/_probe/timed_compiler.gd").new()
		var t := Time.get_ticks_usec()
		var plan: Dictionary = player._build(score, ensemble)
		var t1 := Time.get_ticks_usec()
		var events: Array = plan["head"] + plan["tail"]
		for b: Array in plan["bodies"]:
			events.append_array(b)
		var t2 := Time.get_ticks_usec()
		player._report(score, events, ensemble)
		var t3 := Time.get_ticks_usec()
		var s: Array = player.compiler.sorted(events)
		var t4 := Time.get_ticks_usec()
		player.compiler._switched(s)
		var t5 := Time.get_ticks_usec()
		var c := ensemble.cast(score.parts)
		var t6 := Time.get_ticks_usec()
		print("build %.1f | report %.1f  sorted %.1f  switched %.1f  cast %.1f  (%d events)" % [
			(t1 - t) / 1e3, (t3 - t2) / 1e3, (t4 - t3) / 1e3, (t5 - t4) / 1e3, (t6 - t5) / 1e3, events.size()])
		print("   ", player.compiler.spent)
		player.free()
	quit(0)
