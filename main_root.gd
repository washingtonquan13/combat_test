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
## screen plays its own track (see main_menu.gd). The exploration theme
## instead starts from MusicManager's own world_loaded handler, which fires
## for every real world load (see WorldManager.load_world()).

func _ready() -> void:
	WorldManager.register_scene_root($SceneRoot)
	# Where per-world viewports are instanced. A world needs its own
	# viewport because World3D is per-viewport — see MainRoot.tscn's own
	# WorldHost note, and WorldManager's.
	WorldManager.register_world_host($WorldHost)
	# The nodes that represent the player LOOKING at the world rather than
	# anything the world owns. A Node3D only renders in, and only raycasts
	# against, the World3D of the viewport above it, so these have to ride
	# along into whichever viewport is being looked at. Registered from
	# here because knowing MainRoot's own layout is MainRoot's job — the
	# same reason register_scene_root and register_hud live here.
	# DragSelectBox is in here despite being a Control on the HUD canvas,
	# and it is why register_attention_nodes remembers a home PER NODE.
	# It reads the mouse through _unhandled_input, which the world view
	# container consumes in the root viewport GUI pass — so a tool that
	# operates on the world has to sit inside the world view to see a
	# mouse event at all. It draws over the 3D and under the HUD there,
	# which is where a selection box belongs anyway.
	var attention: Array[Node] = [
		$Indicators, $GroundClickTarget, $DialogueCameraRig, $CanvasLayer/DragSelectBox,
	]
	WorldManager.register_attention_nodes(attention)
	# The TACTICAL HUD subtree, not the CanvasLayer — see
	# UIStack.register_hud()'s own header for why that distinction is
	# load-bearing rather than cosmetic.
	UIStack.register_hud($CanvasLayer/TacticalUI)

	# No mode to set. With no world loaded and character creation not open,
	# GameMode already answers MAIN_MENU — that is its floor, and booting
	# is exactly the state it describes.
	UIStack.push($CanvasLayer/MainMenu)
