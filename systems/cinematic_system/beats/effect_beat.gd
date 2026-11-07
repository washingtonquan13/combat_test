@tool
class_name EffectBeat
extends BeatNode
## Plays a VfxEffect — the same resource an ability uses — between two
## places, or at one. Each place is a role (the actor's chest) or a mark.
##
## Skipped, nothing: a flash is not state.

@export var vfx: VfxEffect = null:
	set(value):
		vfx = value
		_changed()
@export var from: StringName = &"":
	set(value):
		from = value
		_changed()
## Empty = at `from`, which is every burst that is not a projectile.
@export var to: StringName = &"":
	set(value):
		to = value
		_changed()


func _validate_property(property: Dictionary) -> void:
	var owner_stage: CinematicStage = stage()
	if owner_stage and (property.name == "from" or property.name == "to"):
		_suggest_names(property, _role_and_spot_names(owner_stage))


func _fire(owner_stage: CinematicStage) -> void:
	owner_stage.effect(vfx, from, to)


func _beat_warnings(owner_stage: CinematicStage) -> PackedStringArray:
	var warnings := PackedStringArray()
	if vfx == null:
		warnings.append("'vfx' is empty.")
	_check_spot(warnings, owner_stage, "from", from)
	_check_spot(warnings, owner_stage, "to", to, true)
	return warnings
