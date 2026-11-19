class_name RestSpot
extends Area3D
## A safe spot: stand in it on the overworld, press interact, and the
## party takes a full rest (Rest.full_rest). Offers itself to the interact
## prompt the way an OverworldDoor does. Part of the rest system; see
## docs/systems/rest.md.

const PROMPT_GROUP: StringName = &"interact_prompt"

var _prompt: Node


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)
	WorldManager.world_focused.connect(_on_world_focused)


func _on_world_focused(_world: Node) -> void:
	for body in get_overlapping_bodies():
		if body is OverworldAvatar and (body as OverworldAvatar).active:
			_on_body_entered(body)
			return


func _on_body_entered(body: Node3D) -> void:
	if not body is OverworldAvatar or not (body as OverworldAvatar).active:
		return
	_offer()


func _on_body_exited(body: Node3D) -> void:
	if not body is OverworldAvatar or not _prompt:
		return
	_prompt.unregister(self)
	_prompt = null


func _offer() -> void:
	if _prompt:
		_prompt.unregister(self)
	_prompt = get_tree().get_first_node_in_group(PROMPT_GROUP)
	if _prompt:
		_prompt.register(self, _prompt_text())


func _prompt_text() -> String:
	var count := Rest.supplies_count()
	if count == 0:
		return "Rest (no %s)" % Rest.SUPPLIES.item_name
	return "Rest (%d %s)" % [count, Rest.SUPPLIES.item_name]


## Called by interact_prompt.gd.
func activate() -> void:
	Rest.full_rest()
	# The supplies count on the prompt has changed.
	_offer()
