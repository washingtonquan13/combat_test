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

## Set via node_paths on this scene's own MainRoot.tscn instance —
## SaveLoadPanel is pushed ON TOP of this screen (not instead of it) for
## LOAD GAME, same as StashPanel opens over PartyOverview rather than
## replacing it (see stash_panel.gd's own header for that precedent).
@export var save_load_panel: SaveLoadPanel

@onready var _continue_button: Button = %ContinueButton


func _enter_tree() -> void:
	# Found by role rather than NodePath — see character_creation.gd's own
	# matching _enter_tree(), which its Back button resolves through here.
	add_to_group("main_menu")


func _ready() -> void:
	# Recomputed every time this becomes visible, not just once here — a
	# save made mid-session (Esc menu -> Save, then Esc menu -> Main Menu)
	# needs CONTINUE to pick it up without a restart. Same on-show refresh
	# idiom esc_menu.gd's own _on_visibility_changed already uses for its
	# debug exit button. The title track moved here too, for the same
	# reason: _ready() only ever fires once at boot, so returning to this
	# screen via Esc -> MAIN MENU never replayed it — the exploration
	# theme just kept playing underneath a silent title screen.
	visibility_changed.connect(_on_visibility_changed)
	_on_visibility_changed()

	# Closes itself if a load completes while it's the one open — reached
	# via CONTINUE below, but ALSO via a load initiated from
	# save_load_panel while this screen sits open underneath it. Without
	# this, a successful load would leave the title screen's own
	# Background ColorRect covering the freshly-loaded world.
	SaveManager.load_completed.connect(_on_load_completed)


func _on_visibility_changed() -> void:
	if visible:
		_continue_button.visible = SaveManager.most_recent() != ""
		# play_track() no-ops when this is already the playing track (see
		# music_manager.gd), so re-showing this screen without leaving it
		# (a stray visibility_changed toggle) doesn't restart the intro.
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


## _continue_button.visible already guards this from being reachable
## with no save on disk (see _on_visibility_changed) — most_recent()
## re-checked here regardless, same belt-and-suspenders reasoning
## save_load_panel.gd's own _on_save_pressed applies to an empty name.
func _on_continue_pressed() -> void:
	var path: String = SaveManager.most_recent()
	if path != "":
		SaveManager.load_file(path)


func _on_load_pressed() -> void:
	save_load_panel.open_for(SaveLoadPanel.Mode.LOAD)


## SaveManager.load_completed fires for EVERY successful load, including
## ones that have nothing to do with this screen (an Esc-menu load
## during ordinary play) — only close if THIS screen is actually the one
## currently open.
func _on_load_completed(_path: String) -> void:
	if UIStack.is_open(self):
		close()
