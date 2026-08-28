extends UIScreen
## The title screen — a UIScreen living permanently under MainRoot's
## CanvasLayer, NOT a world. It has no 3D environment of its own; what
## makes it "the main menu" is a UI screen plus GameMode.Mode.MAIN_MENU,
## which is why nothing here touches WorldManager. If a 3D backdrop is
## ever wanted behind it (BG3's own animated camp vista, say), that's an
## ordinary world loaded independently underneath this screen — see
## main_root.gd's own note. There's no backdrop art today, so SceneRoot
## simply sits empty and this screen's own Background ColorRect is what
## fills the viewport.
##
## hides_hud=true/blocks_input_below=true/closes_on_cancel=false are
## authored on this scene's instance in MainRoot.tscn — the gameplay HUD
## has nothing to show before a party exists, nothing may open on top of
## the title screen, and Escape must not dismiss it (there'd be nothing
## underneath).

func _enter_tree() -> void:
	# Found by role rather than NodePath — see character_creation.gd's own
	# matching _enter_tree(), which its Back button resolves through here.
	add_to_group("main_menu")


func _ready() -> void:
	var track: MusicTrack = MusicTrackDatabase.find("level_up_groovy")
	if track:
		MusicManager.play_track(track)


## Straight screen-to-screen handoff within the front end: no world is
## loaded or unloaded, only the mode and which screen is up. Character
## creation is likewise a screen, not a world (see character_creation.gd).
func _on_start_pressed() -> void:
	GameMode.set_base_mode(GameMode.Mode.CHARACTER_CREATION)
	close()
	UIStack.push(get_tree().get_first_node_in_group("character_creation"))


func _on_quit_pressed() -> void:
	get_tree().quit()
