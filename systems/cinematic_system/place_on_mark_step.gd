class_name PlaceOnMarkStep
extends SceneStep
## Puts an actor exactly on a named mark.
##
## PLACED, NOT WALKED, and that is the guarantee both references pay for.
## BG3 states the teleport failsafe as doctrine; Mass Effect shipped the
## bug that comes from not having one, where a character arrives late and
## visibly slides into position mid-sentence. Staging that "asks nicely and
## hopes the navigation agrees" fails in front of the player, so a scene
## that says an actor is on a mark makes it true.
##
## A walking variant — go there over time, and be placed if the walk does
## not finish — is what an ENTRANCE needs. Nothing yet does: the fusion
## cutscene stands two demons on a device rather than walking them there,
## so building the timed version now would be guessing at its shape.

@export var role: StringName = &""
@export var mark: StringName = &""
## Whether the actor also takes the mark's facing. False leaves it facing
## however it already was, which is what a scene wants when it has posed an
## actor deliberately and only needs it moved.
@export var takes_facing: bool = true


func apply(cast: SceneCast) -> void:
	if role == &"" or mark == &"":
		return
	var actor: Unit = cast.unit(role)
	var spot: Node3D = cast.mark(mark)
	if actor == null or spot == null:
		return
	if takes_facing:
		actor.global_transform = spot.global_transform
	else:
		actor.global_position = spot.global_position


func describe() -> String:
	return "place '%s' on '%s' at %.2fs" % [role, mark, offset]
