extends Control
## main_menu.tscn's root script — the actual run/main_scene now. Start
## leads to character_creation.tscn, then MainRoot.tscn (the persistent
## game shell) once a character's actually been created — both hops are
## real change_scene_to_file calls, never a SceneManager push. There's no
## game state yet at these points for SceneManager's suspend/resume model
## to preserve, and neither transition ever goes backward in normal play.

func _ready() -> void:
	var track: MusicTrack = MusicTrackDatabase.find("level_up_groovy")
	if track:
		MusicManager.play_track(track)


func _on_start_pressed() -> void:
	get_tree().change_scene_to_file("res://character_creation.tscn")


func _on_quit_pressed() -> void:
	get_tree().quit()
