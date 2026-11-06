extends SceneTree
# Temporary probe: a naive load, the whole groovy ensemble with no filters.

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var conductor := SfzConductor.new()
	root.add_child(conductor)
	await process_frame
	var ensemble := SfzEnsemble.load_from(SfzSettings.ensemble_path("groovy"))
	var t0 := Time.get_ticks_usec()
	var ok: bool = await conductor.load_ensemble(ensemble)
	print("NAIVE_LOAD ok=%s %.1f ms" % [ok, (Time.get_ticks_usec() - t0) / 1000.0])
	quit(0)
