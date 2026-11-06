@tool
class_name FaceBeat
extends BeatNode
## Turns an actor to face someone or something, instantly. Through the
## Unit's own facing (snap_face_point), which knows the model's facing
## offset — a raw look_at would turn the real rig's back to the target.
##
## Skipped, it does exactly the same: which way someone faces is state.

@export var role: StringName = &"":
	set(value):
		role = value
		_changed()
## A role (face the person) or a mark.
@export var target: StringName = &"":
	set(value):
		target = value
		_changed()


func _validate_property(property: Dictionary) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage == null:
		return
	match property.name:
		"role":
			_suggest_names(property, owner_stage.role_names())
		"target":
			_suggest_names(property, _role_and_spot_names(owner_stage))


func _fire(owner_stage: CinematicStage) -> void:
	_face(owner_stage)


func _skip(owner_stage: CinematicStage) -> void:
	_face(owner_stage)


func _face(owner_stage: CinematicStage) -> void:
	var turning: Unit = owner_stage.actor(role)
	var looked_at: Node3D = owner_stage.locate(target)
	if turning == null or looked_at == null:
		push_warning("FaceBeat '%s': '%s' or '%s' does not resolve." % [name, role, target])
		return
	turning.snap_face_point(looked_at.global_position)
	owner_stage.sync_marker(role)


func preview(seconds_since_fire: float) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage == null or seconds_since_fire < 0.0:
		return
	var body: Node3D = _stand_in(owner_stage, role)
	var looked_at: Node3D = _preview_spot(owner_stage, target)
	if body and looked_at:
		_preview_face(body, looked_at.global_position)


func _beat_warnings(owner_stage: CinematicStage) -> PackedStringArray:
	var warnings := PackedStringArray()
	_check_role(warnings, owner_stage, "role", role)
	_check_spot(warnings, owner_stage, "target", target)
	if target == role and role != &"":
		warnings.append("'%s' is told to face itself." % role)
	return warnings
