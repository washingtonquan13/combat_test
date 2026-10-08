extends SceneTree
# Temporary probe (score-data sizing, 2026-10-08). Headless, one area per process.
#   RAM_AREA=<area>
# Godot static memory, step by step, for what preload_area() builds on the
# Godot side: the parsed score, the ensemble manifest, the compiled player;
# then the director's own Hold.SCORES and full preload as cross-checks.

var director: SfzMusicDirector


func _initialize() -> void:
	_run.call_deferred()


func _mb(b: int) -> String:
	return "%.2f" % (b / 1048576.0)


func _static() -> int:
	return int(Performance.get_monitor(Performance.MEMORY_STATIC))


func _objects() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_COUNT))


func _step(label: String, before: int, objects_before: int) -> void:
	print("SCOREDATA %-28s static +%s MB  objects +%d" % [label, _mb(_static() - before),
		_objects() - objects_before])


func _run() -> void:
	var music := root.get_node_or_null("Music")
	if music != null:
		music.table = null
	director = SfzMusicDirector.new()
	root.add_child(director)
	await create_timer(1.0).timeout
	var area := OS.get_environment("RAM_AREA")
	var table := director.table
	var paths := [table.score_path(area)]
	for urgent in [false, true]:
		var sting: String = table.rule("", area, urgent)["sting"]
		if sting != "":
			paths.append(SfzTransitions.sting_path(sting))
	print("SCOREDATA area=%s base static %s MB" % [area, _mb(_static())])

	var held := []
	var s0 := _static()
	var o0 := _objects()
	var ensemble := SfzEnsemble.load_from(table.ensemble_path(area))
	_step("ensemble manifest", s0, o0)
	for path: String in paths:
		var bytes := FileAccess.get_file_as_bytes(path).size()
		var s1 := _static()
		var o1 := _objects()
		var score: SfzScore = SfzScoreParser.parse_file(path)
		_step("parse %s (%d KB)" % [path.get_file(), bytes / 1024], s1, o1)
		held.append(score)
		var s2 := _static()
		var o2 := _objects()
		var player := director._player(0)
		await player.prepare(score, ensemble)
		await process_frame
		_step("compile %s" % path.get_file(), s2, o2)
		held.append(player)
	_step("TOTAL manual", s0, o0)

	for x: Variant in held:
		if x is Node:
			(x as Node).queue_free()
	held.clear()
	ensemble = null
	await process_frame
	await process_frame
	_step("after freeing manual", s0, o0)

	var s3 := _static()
	var o3 := _objects()
	await director.preload_area(area, SfzMusicDirector.Hold.SCORES)
	await process_frame
	_step("director Hold.SCORES", s3, o3)
	await director.preload_area(area)
	await process_frame
	_step("director full preload", s3, o3)
	quit(0)
