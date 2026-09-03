class_name SpawnActorStep
extends SceneStep
## Brings an actor into the world mid-scene and HOLDS it in a role.
##
## The fusion cutscene's seventh beat is why this exists: the fused demon
## does not exist when the scene starts, so no cast built up front can
## contain it and no tracked role can find it — there is no authority to
## ask, because the thing has not been made yet. The scene makes it and
## owns it.
##
## The definition is supplied by whoever built the scene rather than
## authored on the step, because a fusion result is computed from its
## parents and is different every time. `definition_role` names a slot in
## the cast's own data for that reason.

## Which role the new actor is held in.
@export var role: StringName = &""
## Where it appears. A named mark, resolved through the cast.
@export var mark: StringName = &""
## Set by the scene's builder, not authored — see the header.
var definition: UnitDefinition = null


func apply(cast: SceneCast) -> void:
	if role == &"" or definition == null:
		return
	var spawned: Unit = definition.unit_scene.instantiate()
	# BEFORE add_child, and this is not stylistic. Unit adopts its body in
	# _enter_tree, so a definition assigned afterwards produces a unit with
	# no model at all — silently, because a bodiless unit still walks,
	# fights and dies perfectly well. This project has shipped that bug
	# twice already.
	spawned.definition = definition

	var parent: Node = WorldManager.spawn_parent()
	if parent == null:
		spawned.free()
		return
	parent.add_child(spawned)

	if mark != &"":
		var spot: Node3D = cast.mark(mark)
		if spot:
			spawned.global_transform = spot.global_transform

	cast.hold(role, spawned)


func describe() -> String:
	return "spawn '%s' at '%s' at %.2fs" % [role, mark, offset]
