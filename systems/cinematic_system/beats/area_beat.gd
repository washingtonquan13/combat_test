@tool
class_name AreaBeat
extends BeatNode
## Changes the area the scene plays in, by calling one of the area's own
## methods with no arguments: the goblin quarry's break_gate. The area owns what the
## change means (a flag, collision, the nav grid); the scene only says when.
##
## Skipped, the same call: a gate smashed in a skipped scene is smashed.

## A method on the GameArea the stage is in.
@export var method: StringName = &"":
	set(value):
		method = value
		_changed()


func _fire(owner_stage: CinematicStage) -> void:
	_apply(owner_stage)


func _skip(owner_stage: CinematicStage) -> void:
	_apply(owner_stage)


func _apply(owner_stage: CinematicStage) -> void:
	var area: GameArea = area_of(owner_stage)
	if area == null or not area.has_method(method):
		push_warning("AreaBeat '%s': no area with a '%s' method around the stage." % [name, method])
		return
	area.call(method)


## The GameArea `node` is inside, or null.
static func area_of(node: Node) -> GameArea:
	var at: Node = node
	while at:
		if at is GameArea:
			return at
		at = at.get_parent()
	return null


func _beat_warnings(_owner_stage: CinematicStage) -> PackedStringArray:
	var warnings := PackedStringArray()
	if method == &"":
		warnings.append("'method' is empty.")
	return warnings
