extends SceneTree
# Temporary probe (2026-10-08): private bytes in each state of the new preload policy.
# exploration playing + combat scores only / + combat ensemble held / combat playing.

var d: SfzMusicDirector

func _initialize() -> void:
	_run.call_deferred()


func _mb(b: int) -> String:
	return "%.1f" % (b / 1048576.0)


func _play_peak(sec: float) -> int:
	var peak := 0
	var t_end := Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < t_end:
		await process_frame
		peak = maxi(peak, SfzInstrument.get_process_private_bytes())
	return peak


func _settled() -> int:
	await create_timer(0.5).timeout
	SfzInstrument.trim_heap()
	await process_frame
	return SfzInstrument.get_process_private_bytes()


func _run() -> void:
	var music := root.get_node_or_null("Music")
	if music != null:
		music.table = null
	d = SfzMusicDirector.new()
	d.preload_hold = SfzMusicDirector.Hold.SCORES
	root.add_child(d)
	var base := await _settled()
	print("HOLD base %s MB" % _mb(base))
	await d.go_to("overworld.exploration")
	await d.preload_area("overworld.combat")
	var p := await _play_peak(20.0)
	print("HOLD exploring, combat scores only: settled %s MB, playing peak %s MB (preloaded '%s' prepared '%s')" % [
		_mb(await _settled() - base), _mb(p - base), d.preloaded(), d.prepared_area()])
	await d.preload_area("overworld.combat", SfzMusicDirector.Hold.ENSEMBLE)
	p = await _play_peak(20.0)
	print("HOLD exploring, combat ensemble held: settled %s MB, playing peak %s MB (preloaded '%s')" % [
		_mb(await _settled() - base), _mb(p - base), d.preloaded()])
	await d.go_to("overworld.combat", true)
	await d.preload_area("overworld.negotiation")
	p = await _play_peak(30.0)
	print("HOLD fighting, negotiation scores only: settled %s MB, playing peak %s MB (preloaded '%s' prepared '%s')" % [
		_mb(await _settled() - base), _mb(p - base), d.preloaded(), d.prepared_area()])
	await d.silence()
	print("HOLD after silence %s MB" % _mb(await _settled() - base))
	quit(0)
