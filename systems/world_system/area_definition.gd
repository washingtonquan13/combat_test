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
## A real PackedScene reference, not a path string — editor-pickable and
## rename-safe, matching UnitDefinition.unit_scene/Surface.ambient_scene.
## Known cost: any .tres holding a PackedScene makes that scene an EAGER
## dependency of whatever loads the .tres, so AreaDatabase's directory
## scan (see that file) loads every area's world_scene up front. That
## cost is exactly what id-indirection at every OTHER reference point
## (doors, exits) exists to contain — nothing but AreaDatabase itself
## ever touches this field directly.
@export var world_scene: PackedScene

@export_group("Music")
@export var exploration_track: MusicTrack
@export var combat_track: MusicTrack
@export var negotiation_track: MusicTrack
