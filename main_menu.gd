extends Control
## main_menu.tscn's root script — the actual run/main_scene now.
## MainRoot.tscn (the persistent game shell) only loads once Start is
## pressed, via a real change_scene_to_file, not a SceneManager push —
## there's no game state yet at this point for SceneManager's suspend/
## resume model to preserve, and this transition only ever goes one way.

func _ready() -> void:
	var track: MusicTrack = MusicTrackDatabase.find("level_up_groovy")
	if track:
		MusicManager.play_track(track)


func _on_start_pressed() -> void:
	get_tree().change_scene_to_file("res://MainRoot.tscn")


func _on_quit_pressed() -> void:
	get_tree().quit()
