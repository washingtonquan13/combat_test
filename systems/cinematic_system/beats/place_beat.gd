@tool
class_name PlaceBeat
extends BeatNode
## Puts an actor on a mark, instantly — position AND rotation, so a mark's
## facing is part of what it says. For a move the audience should see, use
## a WalkBeat.
##
## Skipped, it does exactly the same: where someone stands is state.

@export var role: StringName = &"":
	set(value):
		role = value
		_changed()
## A stage mark, a declared world mark, or another role (stand where they
## are standing).
@export var mark: StringName = &"":
	set(value):
		mark = value
		_changed()


func _validate_property(property: Dictionary) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage == null:
		return
	match property.name:
		"role":
			_suggest_names(property, owner_stage.role_names())
		"mark":
			_suggest_names(property, _role_and_spot_names(owner_stage))


func _fire(owner_stage: CinematicStage) -> void:
	_place(owner_stage)


func _skip(owner_stage: CinematicStage) -> void:
	_place(owner_stage)


func _place(owner_stage: CinematicStage) -> void:
	if owner_stage.actor(role) == null:
		push_warning("PlaceBeat '%s': nobody is playing '%s'." % [name, role])
		return
	var target: Node3D = owner_stage.locate(mark)
	if target == null:
		push_warning("PlaceBeat '%s': no mark or role named '%s'." % [name, mark])
		return
	owner_stage.put(role, target.global_transform)


func preview(seconds_since_fire: float) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage == null or seconds_since_fire < 0.0:
		return
	var body: Node3D = _stand_in(owner_stage, role)
	var target: Node3D = _preview_spot(owner_stage, mark)
	if body and target:
		body.global_transform = target.global_transform


func _beat_warnings(owner_stage: CinematicStage) -> PackedStringArray:
	var warnings := PackedStringArray()
	_check_role(warnings, owner_stage, "role", role)
	_check_spot(warnings, owner_stage, "mark", mark)
	return warnings
