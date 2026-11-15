class_name DialogueStandIns
extends Node
## Puts the people in a conversation on a scene template's marks for as long
## as they talk, without moving them.
##
## A conversation starts wherever the walk up to somebody happened to stop:
## any distance inside talking reach, at any angle, neither one turned to
## the other. Shots composed against that are composed against chance. So
## when a dialogue begins the template is laid down on the person spoken to,
## turned toward the one who came up, and each gets a StandIn on their mark;
## the camera, heads and faces all work on those. When it ends they are
## struck in the same frame the camera cuts back, and the units are where
## they always were.
##
## A PRESENTATION LISTENER like DialogueGaze and DialogueStaging, and it
## must be added BEFORE them: it is then told of a conversation first, so
## the stand-ins exist by the time the first head turns and the first shot
## is cut, and told of its end first, so they are gone before the camera
## lets go. A cast or a patch of ground the template does not fit is left
## alone, and the conversation plays on the units as they stand.

const TEMPLATE: PackedScene = preload("res://cinematics/templates/dialogue_pair.tscn")

var _conversation: Conversation = null
var _raised: Array[StandIn] = []


func _ready() -> void:
	Conversations.follow(self, _on_conversation_began)


func _exit_tree() -> void:
	_forget()
	_strike()


func _on_conversation_began(c: Conversation) -> void:
	if c.presentation != &"dialogue":
		return
	_forget()
	_strike()
	_conversation = c
	c.changed.connect(_on_changed)
	_raise(c.cast)


func _on_changed() -> void:
	if _conversation and _conversation.ended:
		_forget()
		_strike()


func _raise(cast: Dictionary) -> void:
	var template := TEMPLATE.instantiate() as SceneTemplate
	var placed: Dictionary = template.fit(cast)
	template.free()
	for role in placed:
		var unit: Unit = cast.get(String(role)) as Unit
		var stand: StandIn = StandIn.raise(unit, placed[role].at, placed[role].facing)
		if stand:
			_raised.append(stand)


func _forget() -> void:
	if _conversation and _conversation.changed.is_connected(_on_changed):
		_conversation.changed.disconnect(_on_changed)
	_conversation = null


func _strike() -> void:
	for stand in _raised:
		if is_instance_valid(stand):
			stand.strike()
	_raised.clear()
