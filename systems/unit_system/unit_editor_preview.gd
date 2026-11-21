@tool
class_name UnitEditorPreview
extends Node3D
## Shows a placed unit's body in the editor.
##
## A unit builds its body when the game starts, so in the editor it would
## be an empty capsule. This node, a child of the unit in unit.tscn, shows
## the body the unit's definition names. Editor only: the body is never
## saved into a scene, and in game this node removes itself.
##
## It shows the body's shape, not its dressed look: skin, hair, clothes,
## weapons and size are applied by the unit when the game runs.

var _shown: String = ""
var _body: Node = null


func _ready() -> void:
	if not Engine.is_editor_hint():
		queue_free()


func _process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		return
	var wanted: String = _body_path()
	if wanted == _shown:
		return
	_shown = wanted
	if is_instance_valid(_body):
		_body.queue_free()
	_body = null
	if wanted == "":
		return
	var scene := load(wanted) as PackedScene
	if scene == null:
		return
	_body = scene.instantiate()
	# Internal and unowned: drawn, never listed in the tree or saved.
	add_child(_body, false, Node.INTERNAL_MODE_BACK)


## The body scene the unit above will wear: its look's, else its model.
## Read with get(): the unit and its resources are not tool scripts.
func _body_path() -> String:
	var unit: Node = get_parent()
	var definition: Resource = unit.get(&"definition") as Resource if unit else null
	if definition == null:
		return ""
	var look: Resource = definition.get(&"look") as Resource
	if look:
		var from_look: Variant = look.get(&"body_scene")
		if from_look is String and from_look != "" and ResourceLoader.exists(from_look):
			return from_look
	var model := definition.get(&"model_scene") as PackedScene
	return model.resource_path if model else ""
