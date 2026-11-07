class_name DebugMusicPanel
extends Control
## The Music tab's content — debug-only "play any area of the transitions
## table and watch the director" tool. Root-level like
## DemonCompendiumPanel/DebugSpawnPanel, referenced via @onready from
## party_overview.gd the same way.
##
## The whole tab is debug-only: party_overview.gd hides %TabMusic itself,
## and this script's own _ready()/_process() additionally no-op outside a
## debug build as defense in depth — same reasoning DebugSpawnPanel uses.
##
## Play goes through Music.go_to(), so it exercises the table's real rule
## from whatever is playing now — the way to hear a transition without
## starting a fight. There is no scrubber: the music is generated as it
## plays, so there is no file position to seek to.

@onready var _area_list: ItemList = %MusicAreaList
@onready var _play_button: Button = %PlayMusicButton
@onready var _stop_button: Button = %StopMusicButton
@onready var _status_label: Label = %MusicStatusLabel
@onready var _stats_label: Label = %MusicStatsLabel

var _areas: Array[String] = []


func _ready() -> void:
	if not OS.is_debug_build():
		return
	_play_button.pressed.connect(_on_play_pressed)
	_stop_button.pressed.connect(Music.silence)
	_populate_list()
	_update_status()


func _process(_delta: float) -> void:
	if not OS.is_debug_build() or not is_visible_in_tree():
		return
	_update_status()


func refresh() -> void:
	if not OS.is_debug_build():
		return
	_populate_list()
	_update_status()


func _populate_list() -> void:
	_areas.clear()
	_area_list.clear()
	if Music.table == null:
		return
	for area in Music.table.areas:
		_areas.append(area)
	_areas.sort()
	for area in _areas:
		var entry: Dictionary = Music.table.areas[area]
		_area_list.add_item("%s  —  %s (%s)" % [area, entry["score"], entry["ensemble"]])


func _on_play_pressed() -> void:
	var selected: PackedInt32Array = _area_list.get_selected_items()
	if selected.is_empty():
		return
	Music.go_to(_areas[selected[0]])


func _update_status() -> void:
	var state: Dictionary = Music.state()
	var text: String
	if Music.is_playing():
		text = "%s — %.1fs, intensity %d" % [state["area"], Music.position(), state["intensity"]]
	else:
		text = "Stopped."
	if Music.is_busy():
		text += "  (transition under way)"
	if Music.preloaded() != "":
		text += "  [preloaded: %s]" % Music.preloaded()
	elif Music.prepared_area() != "":
		text += "  [scores ready: %s]" % Music.prepared_area()
	_status_label.text = text
	_stats_label.text = _format_stats(Music.stats()) if Music.is_playing() else ""


## One line per part. late_frames above zero means a note was dispatched
## after it should have sounded — the number that has to stay at 0.
func _format_stats(stats: Dictionary) -> String:
	var lines: PackedStringArray = []
	for part in stats:
		var row: Dictionary = stats[part]
		lines.append("%-10s voices %3d  late %d  dropped %d  starved %d  peak %.2f" % [
			part, row["voices"], row["late_frames"], row["dropped"], row["starved"], row["peak"]])
	return "\n".join(lines)
