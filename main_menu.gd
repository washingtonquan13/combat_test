extends Control
## main_menu.tscn's root script — WorldManager's very first loaded world,
## instantiated by MainRoot itself (see main_root.gd). Start hands off to
## character_creation.tscn via WorldManager.load_world(), same mechanism
## every other world transition in this project now uses.

const CHARACTER_CREATION_SCENE: PackedScene = preload("res://character_creation.tscn")


func _ready() -> void:
	var track: MusicTrack = MusicTrackDatabase.find("level_up_groovy")
	if track:
		MusicManager.play_track(track)


## Duck-typed — see WorldManager.load_world()/UIStack.set_world_hides_hud().
## MainRoot's gameplay HUD (hotbar, party panel, esc menu, ...) has
## nothing to show before a party/world exists.
func hides_hud() -> bool:
	return true


## Duck-typed — see WorldManager.load_world()/GameMode.set_base_mode().
func get_base_mode() -> GameMode.Mode:
	return GameMode.Mode.MAIN_MENU


func _on_start_pressed() -> void:
	WorldManager.load_world(CHARACTER_CREATION_SCENE)


func _on_quit_pressed() -> void:
	get_tree().quit()
