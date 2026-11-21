class_name AreaDefinition
extends Resource
## The data record for one loadable world — "what test_arena IS," not any
## specific runtime state. Doors and exits (see AreaExit) reference an
## area by `id` only, NEVER by holding a direct AreaDefinition reference —
## see AreaDatabase for why that indirection matters. Consumed by
## WorldManager.load_area(), which resolves an id into one of these.
##
## Shared between the overworld and every ordinary area on purpose —
## both are walkable 3D worlds using the exact same avatar/camera/
## collision/load pipeline (WorldManager.load_world(), the duck-typed
## get_base_mode()/spawns_party()/get_spawn_point() contract). Splitting
## the type would only make sense if the overworld ran on genuinely
## different machinery, the way FF7's world-map module or Owlcat's
## click-a-point global map do.
##
## Deliberately has NO default_spawn_point field — a node name living in
## a separate data file goes stale silently on rename, and every world
## already resolves its own fallback correctly (see get_spawn_point() on
## overworld.gd/test_arena.gd).

@export var id: StringName = &""
@export var display_name: String = ""
## Item level of what its chests roll (StashComponent.loot_rolls); its
## monsters drop at their own level (UnitDefinition.level).
@export var level: int = 1
## The world's .tscn, as a path, not a PackedScene. A PackedScene field
## makes the scene an eager dependency of this .tres, and AreaDatabase
## loads every area's .tres to build its catalog: with a hard reference,
## the first find() loaded all eleven worlds (4.4 s measured 2026-11-21)
## to enter one. A path costs nothing until world_scene is read.
## A path is not rename-safe the way a reference is; area_validator.gd
## reports one that no longer resolves.
@export_file("*.tscn") var scene_path: String = ""
## The world, loaded on first read (ResourceLoader caches it after that).
## Null if scene_path is unset or names no scene.
var world_scene: PackedScene:
	get:
		if not has_world_scene():
			return null
		return load(scene_path) as PackedScene


## Whether scene_path names a scene, asked without loading it.
func has_world_scene() -> bool:
	return scene_path != "" and ResourceLoader.exists(scene_path)
