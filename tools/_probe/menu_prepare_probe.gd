extends SceneTree
# Temporary probe: what reading and compiling the title piece costs, step by step.


func _initialize() -> void:
	var table := SfzTransitions.load_from(SfzSettings.transitions_path())
	for i in 3:
		var t := Time.get_ticks_usec()
		var score := SfzScoreParser.parse_file(table.score_path("main_menu"))
		var t1 := Time.get_ticks_usec()
		var ensemble := SfzEnsemble.load_from(table.ensemble_path("main_menu"))
		var t2 := Time.get_ticks_usec()
		var player := SfzScorePlayer.new(null)
		player.compiler = SfzPerformanceCompiler.new()
		var plan: Dictionary = player._build(score, ensemble)
		var t3 := Time.get_ticks_usec()
		print("parse %.1f  ensemble %.1f  build %.1f ms" % [(t1 - t) / 1e3, (t2 - t1) / 1e3, (t3 - t2) / 1e3])
		player.free()
		var c := SfzPerformanceCompiler.new()
		c.ensemble = ensemble
		var t4 := Time.get_ticks_usec()
		var ev := c.compile(score)
		var t5 := Time.get_ticks_usec()
		print("   one-pass compile %.1f ms, %d events" % [(t5 - t4) / 1e3, ev.size()])
	quit(0)
