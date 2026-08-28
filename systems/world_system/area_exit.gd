class_name AreaExit
extends Node
## Shared "where does this trigger lead" data component — dropped onto
## anything that can send the player to another area, an overworld door's
## walk-in Area3D and an arena's context-menu Travel prop alike (see
## overworld_door.gd, travel_interaction.gd). Same find_on()-by-child-
## presence convention as StashComponent, for the same reason: a door and
## an InteractableProp share no common base below Node, so this can't
## live as a shared method on either.
##
## Empty target_area means "return to wherever the player came from" —
## resolved through WorldManager.return_area_id/return_spawn_point at
## the moment of travel rather than a fixed destination. That's what lets
## ONE arena exit serve any number of overworld doors leading into it:
## whichever door you walked in through is where you walk back out.

@export var target_area: StringName = &""
@export var target_spawn_point: StringName = &"default"


## Direct children only, deliberately not recursive — same reasoning as
## StashComponent.find_on(): this component is always meant to be a
## direct child of whatever it makes travelable, never nested deeper.
static func find_on(node: Node) -> AreaExit:
	for child in node.get_children():
		if child is AreaExit:
			return child
	return null


## Resolves the destination (falling back to the return pair when
## target_area is empty), records this exit's own PARENT's name as the
## spawn point the area being left should return to next time, then
## defers the actual load. Callers are always reacting from inside a
## physics callback (body_entered) or a menu action that must close
## first — deferring is owned here once rather than duplicated at both
## call sites. See WorldManager.load_area()'s own note on why the defer
## is required at all (the world being freed owns whatever node this
## call started from).
func travel() -> void:
	var area_id: StringName = target_area
	var spawn_point: StringName = target_spawn_point
	if area_id == &"":
		area_id = WorldManager.return_area_id
		spawn_point = WorldManager.return_spawn_point

	WorldManager.return_spawn_point = get_parent().name
	call_deferred("_load", area_id, spawn_point)


func _load(area_id: StringName, spawn_point: StringName) -> void:
	WorldManager.load_area(area_id, spawn_point)
