@tool
class_name SpawnBeat
extends BeatNode
## Brings an actor into the world, holds it in a role, and stands it on a
## mark. The scene is the authority on anything it creates (SceneCast's
## HELD roles), so the director does not hand it back to anyone.
##
## TWO WAYS TO SAY WHO. `definition` is the author's pick, exported so it
## is a resource picker rather than a typed path. `prop_key` names a value
## the CALLER hands in through play() — fusion's result is only known once
## the fusion has been computed — and wins when set, because the runtime
## answer is the more specific one.
##
## Skipped, the actor is spawned all the same: someone existing is state.

@export var role: StringName = &"":
	set(value):
		role = value
		_changed()
@export var definition: UnitDefinition = null:
	set(value):
		definition = value
		_changed()
## A key into the stage's props, filled by the caller. Preferred over
## `definition` when set.
@export var prop_key: String = "":
	set(value):
		prop_key = value
		_changed()
## Where to stand them: a mark, a declared world mark, or a role.
@export var at: StringName = &"":
	set(value):
		at = value
		_changed()


func _validate_property(property: Dictionary) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage == null:
		return
	match property.name:
		"role":
			_suggest_names(property, owner_stage.role_names())
		"at":
			_suggest_names(property, _role_and_spot_names(owner_stage))


func _fire(owner_stage: CinematicStage) -> void:
	owner_stage.spawn(role, _definition(owner_stage), at)


func _skip(owner_stage: CinematicStage) -> void:
	owner_stage.spawn(role, _definition(owner_stage), at)


func _definition(owner_stage: CinematicStage) -> UnitDefinition:
	if prop_key != "":
		var supplied: UnitDefinition = owner_stage.prop(prop_key) as UnitDefinition
		if supplied == null:
			push_warning("SpawnBeat '%s': no UnitDefinition in props['%s']." % [name, prop_key])
		return supplied
	return definition


## Not there before the key; on its mark from the key on.
func preview(seconds_since_fire: float) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage == null:
		return
	var body: Node3D = _stand_in(owner_stage, role)
	if body == null:
		return
	if seconds_since_fire < 0.0:
		body.visible = false
		return
	var spot_node: Node3D = _preview_spot(owner_stage, at)
	if spot_node and spot_node != body:
		body.global_transform = spot_node.global_transform


func _beat_warnings(owner_stage: CinematicStage) -> PackedStringArray:
	var warnings := PackedStringArray()
	_check_role(warnings, owner_stage, "role", role)
	_check_spot(warnings, owner_stage, "at", at, true)
	if prop_key == "":
		if definition == null:
			warnings.append("Set 'definition', or 'prop_key' for a definition the caller supplies.")
		elif definition.unit_scene == null:
			warnings.append("'definition' has no unit_scene to spawn.")
	return warnings
