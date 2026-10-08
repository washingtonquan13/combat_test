extends SceneTree
# Temporary probe: which keys the title piece sends each part.


func _initialize() -> void:
	var table := SfzTransitions.load_from(SfzSettings.transitions_path())
	var score := SfzScoreParser.parse_file(table.score_path("main_menu"))
	var ensemble := SfzEnsemble.load_from(table.ensemble_path("main_menu"))
	var player := SfzScorePlayer.new(null)
	player.compiler = SfzPerformanceCompiler.new()
	var plan: Dictionary = player._build(score, ensemble)
	var cast: Dictionary = plan["cast"]
	var events: Array = plan["head"] + plan["tail"]
	for body: Array in plan["bodies"]:
		events.append_array(body)
	var keys := {}
	var kinds := {}
	for ev: Dictionary in events:
		var part_name: String = cast[ev["part"]]["part"] if cast.has(ev["part"]) else ev["part"]
		kinds[ev["kind"]] = kinds.get(ev["kind"], 0) + 1
		var part := ensemble.part(part_name)
		var k := -1
		if ev["kind"] == "note":
			k = part.fit(ev["key"])
		elif ev["kind"] == "hit":
			k = part.key_for(ev["drum"])
		else:
			continue
		var d: Dictionary = keys.get_or_add(part_name, {})
		d[k] = d.get(k, 0) + 1
	print(kinds)
	for p in keys:
		var ks: Array = keys[p].keys()
		ks.sort()
		print("%s: %d keys %s" % [p, ks.size(), ks])
		for layer in ensemble.part(p).layers:
			print("    layer %s transpose %d" % [layer.instrument, layer.transpose])
	player.free()
	quit(0)
