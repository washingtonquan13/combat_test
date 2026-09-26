@tool
class_name DespawnBeat
extends BeatNode
## Takes an actor out of the world and out of its role — fusion's parents,
## consumed. Frees the unit, so it is for actors the scene owns; for
## someone who should merely leave the shot, walk them out instead.
##
## Skipped, the actor is gone all the same: this is the beat that makes a
## skipped fusion leave no parent bodies standing in the world.

@export var role: StringName = &"":
	set(value):
		role = value
		_changed()


func _validate_property(property: Dictionary) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage and property.name == "role":
		_suggest_names(property, owner_stage.role_names())


func _fire(owner_stage: CinematicStage) -> void:
	owner_stage.despawn(role)


func _skip(owner_stage: CinematicStage) -> void:
	owner_stage.despawn(role)


func preview(seconds_since_fire: float) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage == null or seconds_since_fire < 0.0:
		return
	var body: Node3D = _stand_in(owner_stage, role)
	if body:
		body.visible = false


func _beat_warnings(owner_stage: CinematicStage) -> PackedStringArray:
	var warnings := PackedStringArray()
	_check_role(warnings, owner_stage, "role", role)
	return warnings
