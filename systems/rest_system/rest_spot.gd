class_name RestSpot
extends Area3D
## An inn: stand in it on the overworld, press interact, and the party
## rests there, free and whole (Rest.inn_rest). Marked by a corona in the
## doors' shader, blue rather than amber (world/inn_rest_spot.tscn), which
## brightens while the avatar stands in it. Offers itself to the interact
## prompt the way an OverworldDoor does. Part of the rest system; see
## docs/systems/rest.md.

const PROMPT_GROUP: StringName = &"interact_prompt"
## Seconds the corona takes to brighten or dim, as a door's does.
const HOT_TIME := 0.25

var _prompt: Node
var _hot_tween: Tween


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
	_set_hot(true)
	_offer()


func _on_body_exited(body: Node3D) -> void:
	if not body is OverworldAvatar:
		return
	_set_hot(false)
	if not _prompt:
		return
	_prompt.unregister(self)
	_prompt = null


func _offer() -> void:
	if _prompt:
		_prompt.unregister(self)
	_prompt = get_tree().get_first_node_in_group(PROMPT_GROUP)
	if _prompt:
		_prompt.register(self, _prompt_text())


## The same tween as overworld_door.gd's _set_hot.
func _set_hot(on: bool) -> void:
	if _hot_tween:
		_hot_tween.kill()
	_hot_tween = create_tween().set_parallel()
	for part: Node in [get_node_or_null(^"Ring"), get_node_or_null(^"Column")]:
		var mesh := part as GeometryInstance3D
		if mesh == null:
			continue
		var now: Variant = mesh.get_instance_shader_parameter(&"hot")
		_hot_tween.tween_method(func(v: float) -> void: mesh.set_instance_shader_parameter(&"hot", v),
			float(now) if now != null else 0.0, 1.0 if on else 0.0, HOT_TIME)


func _prompt_text() -> String:
	return "Rest at the inn"


## Called by interact_prompt.gd.
func activate() -> void:
	Rest.inn_rest()
