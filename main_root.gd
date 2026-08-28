extends Node
## MainRoot.tscn's root script — the persistent shell that never unloads.
## SceneRoot boots EMPTY (see MainRoot.tscn's own header for why — worlds
## are replace-only now, loaded at runtime by WorldManager, never
## pre-instanced at edit time), so this is what actually kicks off the
## whole game: register the container, then load the very first world
## (the main menu).
##
## MusicManager.start_exploration_theme() no longer fires from here — the
## main menu isn't "entering the game world," it's the screen before it,
## and WorldManager now loads it as the very first world. That call moved
## to test_arena.gd's own _ready(), the actual moment a real gameplay
## world exists.

const MAIN_MENU_SCENE: PackedScene = preload("res://main_menu.tscn")


func _ready() -> void:
	WorldManager.register_scene_root($SceneRoot)
	UIStack.register_hud($CanvasLayer)
	WorldManager.load_world(MAIN_MENU_SCENE)
