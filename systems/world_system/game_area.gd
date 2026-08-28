class_name GameArea
extends Node3D
## Base class for an ordinary loadable area (test_arena, test_area_2,
## cathedral_of_shadows, and any future one) — names the duck-typed
## contract WorldManager already documents (get_base_mode()/
## spawns_party()/get_spawn_point()/get_tactical_camera(), see
## world_manager.gd's own header) as real defaults instead of something
## every new area's script has to reimplement or copy from an existing
## one. A scene with no unique behavior at all needs THIS SCRIPT directly
## attached and nothing else — no per-area .gd file required.
##
## The overworld extends this too (see overworld.gd), overriding only
## get_base_mode()/spawns_party() — same "one shared contract" reasoning
## AreaDefinition itself already applies to the DATA side of an area; this
## is the BEHAVIOR side of the same decision.
##
## Deliberately defines NO _ready() — a base _ready() would silently do
## nothing whenever a subclass override forgot to call super(), a trap
## every future area script would have to remember to avoid. Every method
## here is instead resolved lazily, on call, so there's nothing a
## subclass can fail to invoke.
##
## Exports are real node references (editor-pickable, rename-safe — same
## reasoning AreaDefinition.world_scene's own doc comment gives for using
## a PackedScene reference over a path string), not node NAMES the way a
## data file would have to use. The name-based fallbacks below exist so
## every scene authored before this class existed keeps working with zero
## edits: "PartySpawnPoint" and "Start" are exactly the two names
## test_arena.tscn/overworld.tscn already use.

## Optional override — set this in the Inspector when a scene's Camera3D
## isn't reliably the only/first one, or needs picking explicitly.
## Falls back to the first Camera3D found anywhere under this node.
@export var tactical_camera: Camera3D
## Optional override for the fallback spawn point (see get_spawn_point()
## below) — falls back to a node literally named "PartySpawnPoint" or
## "Start" when unset, so this only needs setting if a scene uses neither
## name.
@export var party_spawn_point: Node3D


func get_base_mode() -> GameMode.Mode:
	return GameMode.Mode.EXPLORATION


func spawns_party() -> bool:
	return true


func get_tactical_camera() -> Camera3D:
	if tactical_camera:
		return tactical_camera
	return _find_first_camera(self)


## Resolves by name against this scene's own children first (recursive —
## an exit's own ArrivalPoint/a door's own name can sit at any depth), so
## every authored spawn/arrival point Just Works by name with no other
## wiring. Falls back to party_spawn_point, then to a node named
## "PartySpawnPoint" or "Start" (whichever this scene actually has), then
## null — see WorldManager._resolve_spawn_point()'s own comment for why a
## null here degrades to "spawn at world origin" instead of a hard error.
func get_spawn_point(spawn_point_name: StringName) -> Node3D:
	if spawn_point_name != &"":
		var found := find_child(String(spawn_point_name), true, false) as Node3D
		if found:
			return found

	if party_spawn_point:
		return party_spawn_point

	var named := find_child("PartySpawnPoint", true, false) as Node3D
	if named:
		return named
	return find_child("Start", true, false) as Node3D


func _find_first_camera(node: Node) -> Camera3D:
	for child in node.get_children():
		if child is Camera3D:
			return child
		var found: Camera3D = _find_first_camera(child)
		if found:
			return found
	return null
