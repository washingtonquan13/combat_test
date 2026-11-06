extends Node
# Temporary probe: launch the real game with a live timer, event marks and a
# real-time recording of the master bus, for a screen-captured menu video.

var RUN_SECONDS := float(OS.get_environment("CAPTURE_SECONDS")) if OS.get_environment("CAPTURE_SECONDS") != "" else 14.0
const AUDIBLE_DB := -50.0

var _rec := AudioEffectRecord.new()
var _square := ColorRect.new()
var _clock := Label.new()
var _events := Label.new()
var _rec_tick := 0
var _marks: Array[String] = []
var _menu_seen := false
var _heard := false
var _continue_at := -1


func _ready() -> void:
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	var wp := DisplayServer.window_get_position()
	var ws := DisplayServer.window_get_size()
	print("CAPTURE client %d %d %d %d" % [wp.x, wp.y, ws.x, ws.y])
	AudioServer.add_bus_effect(0, _rec)
	_rec.set_recording_active(true)
	_rec_tick = Time.get_ticks_msec()
	var layer := CanvasLayer.new()
	layer.layer = 128
	_square.size = Vector2(36, 36)
	_square.color = Color.WHITE
	_clock.position = Vector2(48, 2)
	_events.position = Vector2(8, 44)
	for l: Label in [_clock, _events]:
		l.add_theme_font_size_override("font_size", 22)
		l.add_theme_color_override("font_color", Color.YELLOW)
		l.add_theme_color_override("font_outline_color", Color.BLACK)
		l.add_theme_constant_override("outline_size", 6)
	layer.add_child(_square)
	layer.add_child(_clock)
	layer.add_child(_events)
	add_child(layer)
	_mark("recording starts")
	Music.area_changed.connect(func(a: String) -> void: _mark("music lands: %s" % a))
	SaveManager.load_finished.connect(func(_p: String, ok: bool, _r: String) -> void: _mark("load finished ok=%s" % ok))
	WorldManager.world_loaded.connect(func(_w: Node, _r) -> void: _mark("world loaded: %s" % WorldManager.current_area().id))
	_launch.call_deferred()


func _launch() -> void:
	get_tree().current_scene = null
	get_tree().change_scene_to_file("res://MainRoot.tscn")


func _mark(what: String) -> void:
	var line := "%6d ms  %s" % [Time.get_ticks_msec(), what]
	_marks.append(line)
	_events.text = "\n".join(_marks)
	print("CAPTURE ", line)


func _process(_delta: float) -> void:
	_clock.text = "%d ms since launch" % Time.get_ticks_msec()
	if not _menu_seen:
		var menu := get_tree().get_first_node_in_group("main_menu")
		if menu is CanvasItem and menu.is_visible_in_tree():
			_menu_seen = true
			_mark("menu on screen")
	if not _heard and AudioServer.get_bus_peak_volume_left_db(0, 0) > AUDIBLE_DB:
		_heard = true
		_mark("first audible note")
		if OS.get_environment("CAPTURE_CONTINUE") != "":
			_continue_at = Time.get_ticks_msec() + 2000
	if _continue_at > 0 and Time.get_ticks_msec() >= _continue_at:
		_continue_at = -1
		_mark("press Continue")
		get_tree().get_first_node_in_group("main_menu")._on_continue_pressed()
	if Time.get_ticks_msec() - _rec_tick > RUN_SECONDS * 1000.0:
		set_process(false)
		_rec.set_recording_active(false)
		var out := OS.get_environment("CAPTURE_WAV")
		_rec.get_recording().save_to_wav(out)
		print("CAPTURE rec_start_ms=%d wav=%s" % [_rec_tick, out])
		get_tree().quit()
