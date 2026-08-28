extends Node
## MainRoot.tscn's root script — the persistent shell that never unloads.
## Owns two registrations and the game's actual entry point.
##
## The entry point is deliberately NOT a world load. The title screen is a
## UIScreen plus a GameMode, not a 3D environment (see main_menu.gd), so
## booting means: set the base mode, push the menu screen, and leave
## SceneRoot empty. The first real world load happens on Confirm in
## character creation — the moment the game proper begins.
##
## If a 3D backdrop behind the title screen is ever wanted (BG3's animated
## camp vista), it's an ordinary WorldManager.load_world() call added right
## here alongside the push below — the menu screen renders on the
## CanvasLayer above whatever world happens to be loaded, and needs no
## changes to accommodate one. There's no backdrop art today.
##
## MusicManager.start_exploration_theme() is not called here — the title
## screen plays its own track (see main_menu.gd), and the exploration
## theme starts from test_arena.gd's own _ready(), the actual moment a
## gameplay world exists.

func _ready() -> void:
	WorldManager.register_scene_root($SceneRoot)
	# The TACTICAL HUD subtree, not the CanvasLayer — see
	# UIStack.register_hud()'s own header for why that distinction is
	# load-bearing rather than cosmetic.
	UIStack.register_hud($CanvasLayer/TacticalUI)

	GameMode.set_base_mode(GameMode.Mode.MAIN_MENU)
	UIStack.push($CanvasLayer/MainMenu)
