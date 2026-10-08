extends Node
# Temporary probe (RAM measurement, 2026-10-08): launches the real game like
# menu_capture.gd, but records nothing (AudioEffectRecord grows ~11 MB/min),
# and prints memory + director state once a second and a voice report at exit.
#   RAM_SECONDS      run length (default 60)
#   RAM_CONTINUE     press Continue (loads newest save) RAM_CONTINUE_DELAY ms after the menu shows
#   RAM_NOMUSIC=1    no music at all (Music.table = null for the whole run)
#   RAM_SKIP_TITLE=1 no title music; the table is restored just before Continue

var RUN_SECONDS := float(OS.get_environment("RAM_SECONDS")) if OS.get_environment("RAM_SECONDS") != "" else 60.0
var CONTINUE_DELAY := int(OS.get_environment("RAM_CONTINUE_DELAY")) if OS.get_environment("RAM_CONTINUE_DELAY") != "" else 6000
var _table: SfzTransitions
var _menu_at := -1
var _continued := false
var _last_print := 0
var _peaks := {}      # "ensemble/part/layer" -> [max_voices, peak active]
var _sum_peak := {}   # ensemble -> peak of summed active voices
var _streamed_peak := 0


func _ready() -> void:
	_table = Music.table
	if OS.get_environment("RAM_NOMUSIC") != "" or OS.get_environment("RAM_SKIP_TITLE") != "":
		Music.table = null
	Music.area_changed.connect(func(a: String) -> void: _mark("music lands: %s" % a))
	SaveManager.load_finished.connect(func(_p: String, ok: bool, _r: String) -> void: _mark("load finished ok=%s" % ok))
	_launch.call_deferred()


func _launch() -> void:
	get_tree().current_scene = null
	get_tree().change_scene_to_file("res://MainRoot.tscn")


func _ms() -> int:
	return Time.get_ticks_msec()


func _mark(what: String) -> void:
	print("RAMCAP %7d ms  %s" % [_ms(), what])


func _slots() -> String:
	var parts: Array[String] = []
	for c: SfzConductor in Music.conductors():
		var n := 0
		var regions := 0
		for p in c._stacks:
			for e in c._stacks[p]:
				n += 1
				regions += e.instrument.get_region_count()
		parts.append("%s(%s,%d inst,%d reg,held=%s)" % [
			c.ensemble.id if c.ensemble != null else "-", "loaded" if c.is_loaded() else "empty",
			n, regions, c.is_held()])
	return " ".join(parts)


func _process(_d: float) -> void:
	if _menu_at < 0:
		var menu := get_tree().get_first_node_in_group("main_menu")
		if menu is CanvasItem and menu.is_visible_in_tree():
			_menu_at = _ms()
			_mark("menu on screen")
	if OS.get_environment("RAM_CONTINUE") != "" and not _continued and _menu_at > 0 \
			and _ms() - _menu_at >= CONTINUE_DELAY:
		_continued = true
		if OS.get_environment("RAM_SKIP_TITLE") != "" and OS.get_environment("RAM_NOMUSIC") == "":
			Music.table = _table
		_mark("press Continue")
		get_tree().get_first_node_in_group("main_menu")._on_continue_pressed()
	# Voices, every frame.
	for c: SfzConductor in Music.conductors():
		if c.ensemble == null:
			continue
		var total := 0
		for p in c._stacks:
			for e in c._stacks[p]:
				var inst: SfzInstrument = e.instrument
				var v := inst.get_active_voices()
				total += v
				var k := "%s/%s/%s" % [c.ensemble.id, p, e.layer.name]
				var row: Array = _peaks.get(k, [inst.max_voices, 0])
				row[1] = maxi(row[1], v)
				_peaks[k] = row
		_sum_peak[c.ensemble.id] = maxi(_sum_peak.get(c.ensemble.id, 0), total)
	var streamed := SfzInstrument.get_streamed_bytes()
	_streamed_peak = maxi(_streamed_peak, streamed)
	if _ms() - _last_print >= 1000:
		_last_print = _ms()
		print("RAMCAP %7d ms  private %.1f MB  godot_static %.1f MB  heads %.1f MB  shared %.1f MB  streamed %.1f MB  objs %d  area=%s preloaded=%s  %s" % [
			_ms(), SfzInstrument.get_process_private_bytes() / 1048576.0,
			OS.get_static_memory_usage() / 1048576.0, Music.heads_memory() / 1048576.0,
			SfzInstrument.get_shared_sample_bytes() / 1048576.0, streamed / 1048576.0,
			Performance.get_monitor(Performance.OBJECT_COUNT), Music.area, Music.preloaded(), _slots()])
	if _ms() > RUN_SECONDS * 1000.0:
		set_process(false)
		print("RAMCAP voices (layer: cap / peak active)")
		var keys := _peaks.keys()
		keys.sort()
		for k in keys:
			print("RAMCAP   %-40s %3d / %3d" % [k, _peaks[k][0], _peaks[k][1]])
		for e in _sum_peak:
			print("RAMCAP   ensemble %s peak summed active %d" % [e, _sum_peak[e]])
		print("RAMCAP streamed peak %.1f MB" % (_streamed_peak / 1048576.0))
		get_tree().quit()
