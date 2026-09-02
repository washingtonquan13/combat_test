class_name OverworldDoor
extends Area3D
## Authored overworld exit — reads its own AreaExit child (see
## area_exit.gd) for where "in" leads. Walk into range, press Space (see
## interact_prompt.gd) — travel only fires from activate(), never from
## the trigger volume itself, which is what makes it safe to arrive
## standing directly ON a door: there's no bounce to guard against
## anymore, unlike the old procedurally-generated door this replaced
## (see git history for the "primed" latch it needed and this doesn't).
##
## overworld_door.tscn deliberately carries NO AreaExit child of its own
## — every placed door adds one as its OWN extra content (see
## overworld.tscn's own DoorA for the pattern), same as
## interactable_prop.tscn/AreaExit on the arena's exit prop. A shared
## AreaExit baked into this base scene was tried first and silently
## didn't work: overriding a property on a node NESTED inside an
## instanced sub-scene needs real editable-children plumbing Godot's
## serializer doesn't apply just because a script sets `owner` on it —
## the override showed up as an ignored orphan (or, worse, a same-named
## duplicate colliding with the real one) rather than actually taking
## effect. Overriding a property directly on the INSTANCED ROOT itself
## (ProtoBlock.size, this door's own position) has no such problem — only
## a nested child does.

const PROMPT_GROUP: StringName = &"interact_prompt"

var _prompt: Node


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	# Switching focus clears every prompt (see interact_prompt), and
	# body_entered will not fire again for an avatar that never left — so
	# a door the player was already standing in has to offer itself again
	# when they come back to this world.
	WorldManager.world_focused.connect(_on_world_focused)


func _on_world_focused(_world: Node) -> void:
	for body in get_overlapping_bodies():
		if body is OverworldAvatar and (body as OverworldAvatar).active:
			_on_body_entered(body)
			return


func _on_body_entered(body: Node3D) -> void:
	# The ACTIVE avatar only. With one avatar per group, a group left
	# standing on a doorstep would otherwise keep offering the prompt for
	# a door the player is nowhere near.
	if not body is OverworldAvatar or not (body as OverworldAvatar).active:
		return
	_prompt = get_tree().get_first_node_in_group(PROMPT_GROUP)
	if _prompt:
		_prompt.register(self, _prompt_text())


func _on_body_exited(body: Node3D) -> void:
	if not body is OverworldAvatar or not _prompt:
		return
	_prompt.unregister(self)
	_prompt = null


## Called by interact_prompt.gd when this door is the current candidate
## and the player presses interact — duck-typed the same way
## get_interactions()/get_spawn_point() are.
func activate() -> void:
	var exit: AreaExit = AreaExit.find_on(self)
	if exit:
		exit.travel()


## "Enter <area display_name>" when resolvable, bare "Enter" otherwise —
## gives AreaDefinition.display_name its first actual consumer.
func _prompt_text() -> String:
	var exit: AreaExit = AreaExit.find_on(self)
	if not exit:
		return "Enter"
	var area: AreaDefinition = AreaDatabase.find(exit.target_area)
	return "Enter %s" % area.display_name if area else "Enter"
