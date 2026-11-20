@tool
class_name ImpactBeat
extends BeatNode
## Fires one ContactEvent through the stage's impact dispatcher
## (CinematicStage.impact) for a contact no paired clip owns: a body landing
## from a jump (Kind.LAND), a door slammed into someone. The hit-stop, the
## shake, the kit's VFX and SFX all come from the event, as for a blow.
##
## The point is under the role's hips, on its floor: a clip that carries
## the body (a leap landing short of its mark) lands it where it shows, not
## at the unit's origin. Skipped, nothing: an impact is not state.

@export var role: StringName = &"":
	set(value):
		role = value
		_changed()
@export var event: ContactEvent = null:
	set(value):
		event = value
		_changed()
@export var kit: ImpactKit = null:
	set(value):
		kit = value
		_changed()


func _validate_property(property: Dictionary) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage and property.name == "role":
		_suggest_names(property, owner_stage.role_names())


func _fire(owner_stage: CinematicStage) -> void:
	var body: Node3D = owner_stage.body(role)
	if body == null or event == null:
		push_warning("ImpactBeat '%s': nobody is playing '%s', or no event." % [name, role])
		return
	owner_stage.impact(event, role, role, _under_hips(body, StandIn.body_of(owner_stage.actor(role))), kit)


func _under_hips(body: Node3D, model: CharacterModel) -> Vector3:
	var at: Vector3 = body.global_position
	var skeleton: Skeleton3D = model.find_child("GeneralSkeleton", true, false) as Skeleton3D if model else null
	var hips: int = skeleton.find_bone("Hips") if skeleton else -1
	if hips < 0:
		return at
	var shown: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(hips).origin
	return Vector3(shown.x, at.y, shown.z)


func _beat_warnings(owner_stage: CinematicStage) -> PackedStringArray:
	var warnings := PackedStringArray()
	_check_role(warnings, owner_stage, "role", role)
	if event == null:
		warnings.append("'event' is empty.")
	return warnings
