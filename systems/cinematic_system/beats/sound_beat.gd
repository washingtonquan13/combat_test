@tool
class_name SoundBeat
extends BeatNode
## Plays an SfxCue at a role (the actor's chest) or a mark.
##
## For a sound that belongs to the stage itself, an audio track on an
## AudioStreamPlayer3D child is the native answer and scrubs in the
## editor; this beat is for a cue that should sound where a unit or an
## area mark is.
##
## Skipped, nothing: a sound is not state.

@export var cue: SfxCue = null:
	set(value):
		cue = value
		_changed()
@export var at: StringName = &"":
	set(value):
		at = value
		_changed()


func _validate_property(property: Dictionary) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage and property.name == "at":
		_suggest_names(property, _role_and_spot_names(owner_stage))


func _fire(owner_stage: CinematicStage) -> void:
	owner_stage.sound(cue, at)


func _beat_warnings(owner_stage: CinematicStage) -> PackedStringArray:
	var warnings := PackedStringArray()
	if cue == null:
		warnings.append("'cue' is empty.")
	_check_spot(warnings, owner_stage, "at", at)
	return warnings
