extends Node
## MainRoot.tscn's root script — the persistent shell that never unloads.
## Registers this scene's SceneRoot container with SceneManager so it can
## adopt whatever arena is already instanced there at edit time. See
## systems/scene_system/scene_manager.gd's register_scene_root() for why
## the autoload never reaches for this node itself.

func _ready() -> void:
	SceneManager.register_scene_root($SceneRoot)
