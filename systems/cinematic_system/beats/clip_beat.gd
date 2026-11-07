@tool
class_name ClipBeat
extends BeatNode
## Makes an actor play one of its own animation clips — a bow, a flinch, a
## pose. Claims the animator by default so gameplay does not animate over
## the shot; the director releases every claim when the scene ends.
##
## Skipped, nothing is played. A clip is performance, not state, and the
## claim it would have taken is released at the end regardless — gameplay
## picks the actor's animation back up either way.

@export var role: StringName = &"":
	set(value):
		role = value
		_changed()
## A clip name on the actor's model's AnimationPlayer. Free text: the stage
## has no model to list clips from.
@export var animation_name: String = "":
	set(value):
		animation_name = value
		_changed()
## Hold off gameplay's own animation until the scene ends.
@export var claims: bool = true


func _validate_property(property: Dictionary) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage and property.name == "role":
		_suggest_names(property, owner_stage.role_names())


func _fire(owner_stage: CinematicStage) -> void:
	owner_stage.clip(role, animation_name, claims)


func _beat_warnings(owner_stage: CinematicStage) -> PackedStringArray:
	var warnings := PackedStringArray()
	_check_role(warnings, owner_stage, "role", role)
	if animation_name == "":
		warnings.append("'animation_name' is empty.")
	return warnings
