@tool
class_name ExpressionBeat
extends BeatNode
## An actor's face changes: a smile, a frown, a narrowing of the eyes.
##
## Only a body with a face (CharacterModel.face, a FaceDriver) can do this.
## On any other body the beat does nothing, quietly, so a scene written for
## a human still plays with a placeholder in the role.
##
## The expression is held until the next ExpressionBeat on the same actor;
## "neutral" puts the face back at rest. It mixes with whatever the face is
## already doing: the actor still blinks, and still mouths a line over a
## smile.
##
## Skipped, it sets the face straight to where it would have ended, so a
## scene skipped past a scowl does not leave the actor smiling.

## Whose face.
@export var role: StringName = &"":
	set(value):
		role = value
		_changed()
## One of FaceDriver.EXPRESSIONS.
@export var expression: StringName = &"smile"
## How much of it: 1 is the full expression, 0.5 a hint of it.
@export_range(0.0, 1.0, 0.05) var weight: float = 1.0
## How long the face takes to get there.
@export_range(0.0, 3.0, 0.05, "suffix:s") var fade_seconds: float = 0.3


func _validate_property(property: Dictionary) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage and property.name == "role":
		_suggest_names(property, owner_stage.role_names())
	elif property.name == "expression":
		property.hint = PROPERTY_HINT_ENUM_SUGGESTION
		property.hint_string = ",".join(PackedStringArray(FaceDriver.EXPRESSIONS.keys()))


func _fire(owner_stage: CinematicStage) -> void:
	_express(owner_stage, fade_seconds)


func _skip(owner_stage: CinematicStage) -> void:
	_express(owner_stage, 0.0)


func _express(owner_stage: CinematicStage, fade: float) -> void:
	var face: FaceDriver = FaceDriver.of(owner_stage.actor(role))
	if face:
		face.express(expression, weight, fade)


func _beat_warnings(owner_stage: CinematicStage) -> PackedStringArray:
	var warnings := PackedStringArray()
	_check_role(warnings, owner_stage, "role", role)
	if not FaceDriver.EXPRESSIONS.has(expression):
		warnings.append("No expression called '%s'." % expression)
	return warnings
