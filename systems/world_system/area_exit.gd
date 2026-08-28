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
## Purely DATA — travel() only forwards to WorldManager.load_area(),
## which does the real work, including WHICH spawn point to land on in
## the destination (see WorldManager._resolve_entry_spawn_point() and its
## back-link derivation). This component doesn't remember anything about
## past trips and never writes to WorldManager at all — an earlier
## version of this file did (a "return_area_id"/"return_spawn_point"
## pair, mutated by whichever exit fired most recently), and that mutable
## shared state was the actual source of two real, separate bugs: an
## avatar landing wrong because one exit's bookkeeping write raced ahead
## of another's read, and every FIRST-EVER trip into an area landing at
## its bare fallback marker because there was nothing to remember yet.
## Deriving the landing spot from the destination's own authored content
## instead of a runtime breadcrumb closes both — see WorldManager's own
## header for the full reasoning, and the architectural fix-pass writeup
## in project memory for the incident this replaced.
##
## target_area is required — an exit with an empty target_area is a
## configuration mistake, not a "figure it out" signal, and travel()
## warns rather than silently misrouting.

@export var target_area: StringName = &""
## Optional — which named spawn point in target_area this exit's own
## travel() should request. Leave empty to let the DESTINATION derive it:
## WorldManager searches target_area's own world for whichever of ITS
## OWN exits leads back to the area being left, and that exit's
## arrival_point becomes the landing spot — correct by construction,
## since that's definitionally the way back. Only needs setting for a
## genuinely asymmetric link (the destination has no exit pointing back
## this way at all) or to force one specific choice among several valid
## ones.
@export var target_spawn_point: StringName = &""
## Where THIS exit should be treated as leading TO within its OWN scene
## when something else resolves a back-link against target_area (see
## WorldManager._find_back_link()) — defaults to this exit's own parent
## (the door/prop itself) when unset. Only needs overriding when that
## parent isn't a safe place to physically stand: the arena's exit prop
## is a solid StaticBody3D, so its own AreaExit points this at a separate
## walkable Marker3D instead (see test_arena.tscn's own
## OverworldExit/ArrivalPoint). An overworld door is an Area3D with no
## solid collision, so its AreaExit leaves this unset — arriving directly
## ON the door is correct there.
@export var arrival_point: Node3D


## Direct children only, deliberately not recursive — same reasoning as
## StashComponent.find_on(): this component is always meant to be a
## direct child of whatever it makes travelable, never nested deeper.
static func find_on(node: Node) -> AreaExit:
	for child in node.get_children():
		if child is AreaExit:
			return child
	return null


## Starts the trip. Deferred: callers are always reacting from inside a
## physics callback (body_entered) or an input/menu action, and the load
## this triggers can synchronously free the very node this call started
## from — see WorldManager.load_world()'s own note on why.
func travel() -> void:
	if target_area == &"":
		push_warning("AreaExit.travel() on %s has no target_area set." % get_parent().name)
		return
	call_deferred("_load", target_area, target_spawn_point)


func _load(area_id: StringName, spawn_point: StringName) -> void:
	WorldManager.load_area(area_id, spawn_point)
