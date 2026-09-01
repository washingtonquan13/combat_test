extends UIScreen
## blocks_input_below=true is authored on this scene's instance in
## MainRoot.tscn — see UIScreen's own header. hides_hud/closes_on_cancel
## stay at their defaults (false, true): the pause menu doesn't hide the
## gameplay HUD today, and Escape closes it like any other screen.
##
## Built inline directly in MainRoot.tscn (CanvasLayer/EscMenu), not as
## its own reusable .tscn — the standalone res://esc_menu.tscn at the
## project root is orphaned, leftover content pointing at a script path
## (res://src/esc_menu.gd) that doesn't exist; nothing in the running
## game references it. Left alone as out of scope for whatever touched
## this file next — flagging here so it isn't mistaken for live content.

## The debug exit's own fixed destination — WorldManager no longer
## tracks "wherever you came from" at all (see the architectural
## fix-pass writeup in project memory for why remembering it was itself
## the bug), so this button just names the overworld directly. It still
## lands on the CORRECT door rather than the overworld's bare Start
## marker: WorldManager's own back-link derivation finds whichever
## overworld door leads back to the arena and lands there — this button
## doesn't need to know or care which one that is.
const HOME_AREA: StringName = &"overworld"

## Set via node_paths on this scene's own MainRoot.tscn instance — same
## borrow-a-sibling-screen pattern StashPanel's party_overview export
## already uses.
@export var save_load_panel: SaveLoadPanel

@onready var _debug_exit_button: Button = %DebugExitToOverworldButton
@onready var _save_button: Button = %SaveButton
@onready var _load_button: Button = %LoadButton
@onready var _main_menu_button: Button = %MainMenuButton


func _ready() -> void:
	visible = false
	add_to_group("esc_menu")
	_debug_exit_button.pressed.connect(_on_debug_exit_pressed)
	_save_button.pressed.connect(_on_save_pressed)
	_load_button.pressed.connect(_on_load_pressed)
	_main_menu_button.pressed.connect(_on_main_menu_pressed)
	# GameMode can change between one menu-open and the next (combat
	# starting/ending while a player alt-tabs, e.g.) — recompute every
	# time this becomes visible rather than once at _ready(), the same
	# idiom conversation_log.gd already uses for its own on-show refresh.
	visibility_changed.connect(_on_visibility_changed)
	# Closes itself if a load completes while it's open (Load below, or
	# a load initiated from save_load_panel while this sits open behind
	# it) — same reasoning main_menu.gd applies to its own CONTINUE/Load
	# path, so the pause menu doesn't linger on top of a freshly-loaded
	# world.
	SaveManager.load_completed.connect(_on_load_completed)


func _on_visibility_changed() -> void:
	if visible:
		_debug_exit_button.visible = OS.is_debug_build() and GameMode.current_mode() == GameMode.Mode.EXPLORATION
		_save_button.disabled = not SaveManager.can_save()


func _on_exit_to_desktop_pressed() -> void:
	get_tree().quit()


func _on_exit_button_pressed() -> void:
	close()


## Debug-only escape hatch, kept alongside the real one (see
## OverworldExit/travel_interaction.gd in test_arena.tscn).
func _on_debug_exit_pressed() -> void:
	close()
	WorldManager.load_area(HOME_AREA)


func _on_save_pressed() -> void:
	save_load_panel.open_for(SaveLoadPanel.Mode.SAVE)


func _on_load_pressed() -> void:
	save_load_panel.open_for(SaveLoadPanel.Mode.LOAD)


## Unlike the debug exit above, this genuinely unloads the world rather
## than swapping to another one — WorldManager.unload() (see that file's
## own header on why it exists as a separate entry point from
## load_world()), not load_area(), since there is no destination WORLD
## here, only a screen.
func _on_main_menu_pressed() -> void:
	if not WorldManager.unload():
		return
	close()
	# unload() above left no world focused, so GameMode is already back to
	# MAIN_MENU by the time this screen goes up.
	UIStack.push(get_tree().get_first_node_in_group("main_menu"))


func _on_load_completed(_path: String) -> void:
	if UIStack.is_open(self):
		close()
