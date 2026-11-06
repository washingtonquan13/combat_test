extends SceneTree
# Temporary probe: what the first compile in a process pays that later ones do not.


func _initialize() -> void:
	var table := SfzTransitions.load_from(SfzSettings.transitions_path())
	var score := SfzScoreParser.parse_file(table.score_path("main_menu"))
	var ensemble := SfzEnsemble.load_from(table.ensemble_path("main_menu"))
	for i in 3:
		var c := SfzPerformanceCompiler.new()
		c.ensemble = ensemble
		var t := Time.get_ticks_usec()
		c.cast_for(score)
		var t1 := Time.get_ticks_usec()
		var tl := score.timeline()
		var t2 := Time.get_ticks_usec()
		var ev := c.compile(score)
		var t3 := Time.get_ticks_usec()
		print("cast %.1f timeline %.1f compile %.1f" % [(t1 - t) / 1e3, (t2 - t1) / 1e3, (t3 - t2) / 1e3])
	quit(0)
