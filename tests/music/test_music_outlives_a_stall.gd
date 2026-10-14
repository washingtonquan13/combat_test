extends AiTestCase
## The music is played on the audio thread from a timeline the conductor
## uploaded ahead, so the game thread holding still for longer than the
## old 0.65 s send-ahead neither starves it nor stops it. A load that
## hitches for seconds is the case this stands for.

const AREA := "test_area_2.exploration"
const STALL_MSEC := 1500
## Peak on the master bus that counts as sounding.
const AUDIBLE_DB := -60.0


func run() -> void:
	var ok: bool = await Music.go_to(AREA)
	check("the music starts", ok and Music.is_playing())
	if not ok:
		return
	while Music.position() < 1.0:
		await get_tree().process_frame
	var conductor: SfzConductor = Music.conductor()
	for instrument in _instruments():
		instrument.get_max_timing_error()   # read-and-reset

	# The same stretch unstalled first: the clock is the mix's own, and a
	# headless run's dummy driver mixes slower than the wall clock, so the
	# stalled stretch is held to what an unstalled one manages.
	var free_from := Music.position()
	var free_until := Time.get_ticks_msec() + STALL_MSEC
	while Time.get_ticks_msec() < free_until:
		await get_tree().process_frame
	var unstalled := Music.position() - free_from

	var before := Music.position()
	OS.delay_msec(STALL_MSEC)
	await get_tree().process_frame
	var advanced := Music.position() - before

	var peak := -200.0
	var until := Time.get_ticks_msec() + 1500
	while Time.get_ticks_msec() < until:
		peak = maxf(peak, AudioServer.get_bus_peak_volume_left_db(0, 0))
		await get_tree().process_frame
	var late := 0
	for instrument in _instruments():
		late = maxi(late, instrument.get_max_timing_error())

	check("no timeline starved through the stall", not conductor._warned.has("!timeline_starved"))
	check("no note went out late", late == 0, "%d frames late" % late)
	check("the music kept time through the stall", advanced > unstalled * 0.9,
		"advanced %.3f s over a %d ms stall, %.3f s unstalled" % [advanced, STALL_MSEC, unstalled])
	check("and is still sounding afterwards", Music.is_playing() and peak > AUDIBLE_DB,
		"peak %.1f dB" % peak)
	await Music.silence(0.0)


func _instruments() -> Array[SfzInstrument]:
	var out: Array[SfzInstrument] = []
	for c: SfzConductor in Music.conductors():
		if not c.is_loaded():
			continue
		for part_name in c._stacks:
			for entry in c._stacks[part_name]:
				out.append(entry.instrument)
	return out
