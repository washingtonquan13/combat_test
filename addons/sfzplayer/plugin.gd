@tool
extends EditorPlugin

# Enabling the plugin puts the music paths in Project Settings and adds the
# director as an autoload called Music, so a game can say
#
#   Music.go_to("battle", true)
#
# from anywhere. Nothing here is needed at runtime: the classes are global
# and the settings fall back to their defaults without it.

const AUTOLOAD := "Music"
const DIRECTOR := "res://addons/sfzplayer/runtime/music_director.gd"
const EXPORT_MIDI := "Export Score to MIDI..."

var _dialog: EditorFileDialog


func _enter_tree() -> void:
	for key: String in SfzSettings.DEFAULTS:
		if not ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, SfzSettings.DEFAULTS[key])
		ProjectSettings.set_initial_value(key, SfzSettings.DEFAULTS[key])
		ProjectSettings.set_as_basic(key, true)
		var info := {"name": key, "type": TYPE_STRING, "hint": PROPERTY_HINT_DIR}
		if key == SfzSettings.TRANSITIONS or key == SfzSettings.LOUDNESS:
			info.merge({"hint": PROPERTY_HINT_FILE, "hint_string": "*.json"}, true)
		elif key == SfzSettings.BUS:
			info["hint"] = PROPERTY_HINT_NONE
		elif key == SfzSettings.PRELOAD_SCALE:
			info.merge({"type": TYPE_FLOAT, "hint": PROPERTY_HINT_RANGE,
				"hint_string": "0.125,4,0.125"}, true)
		ProjectSettings.add_property_info(info)
	add_tool_menu_item(EXPORT_MIDI, _pick_score)


func _exit_tree() -> void:
	remove_tool_menu_item(EXPORT_MIDI)
	if _dialog != null:
		_dialog.queue_free()
		_dialog = null


# Project > Tools > Export Score to MIDI: pick a .score, get a .mid beside it.
# The same export as addons/sfzplayer/tools/export_midi.gd, performed.
func _pick_score() -> void:
	if _dialog == null:
		_dialog = EditorFileDialog.new()
		_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
		_dialog.access = EditorFileDialog.ACCESS_RESOURCES
		_dialog.add_filter("*.score", "Scores")
		_dialog.title = "Export a score to MIDI"
		_dialog.file_selected.connect(_export_score)
		EditorInterface.get_base_control().add_child(_dialog)
	_dialog.current_dir = SfzSettings.get_path(SfzSettings.SCORES)
	_dialog.popup_file_dialog()


func _export_score(path: String) -> void:
	var export := SfzMidiExport.new()
	var out := path.get_basename() + ".mid"
	var problem := export.write_file(path, out)
	if problem != "":
		push_error("MIDI export: " + problem)
		return
	print("MIDI export: %s -> %s
  %s" % [path, out, export.summary()])
	EditorInterface.get_resource_filesystem().scan()


func _enable_plugin() -> void:
	if not ProjectSettings.has_setting("autoload/" + AUTOLOAD):
		add_autoload_singleton(AUTOLOAD, DIRECTOR)


func _disable_plugin() -> void:
	if ProjectSettings.has_setting("autoload/" + AUTOLOAD):
		remove_autoload_singleton(AUTOLOAD)
