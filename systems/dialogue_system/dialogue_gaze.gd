class_name DialogueGaze
extends Node
## Everyone in a conversation looks at whoever is currently speaking.
##
## This is the cheapest thing in the project that makes dialogue feel
## staged rather than transcribed. BG3's conversations read as alive
## largely because heads track the speaker, and the machinery for it ships
## with Godot 4.4 as LookAtModifier3D — so the only new part is deciding
## who looks at whom, which is what this node does.
##
## A PRESENTATION LISTENER, in the same family as dialogue_overlay.gd,
## dialogue_camera_rig.gd and skill_check_dice_popup.gd: it follows a
## conversation's `changed` signal and reads its transcript and cast, and
## never calls back into it. Only a conversation presented as dialogue is
## followed; a negotiation is a menu panel with nobody staged to look.
##
## ONE node, not a component per unit. A Unit-owned listener connected to
## an autoload signal outlives its own freed owner — that exact leak has
## bitten this project before — whereas this lives on MainRoot for the
## life of the game and holds only weak intent.
##
## SHORT-LIVED BY DESIGN. When the cinematic director exists, aiming a
## gaze becomes an ordinary scene step and this node is absorbed along
## with dialogue_camera_rig.gd. It is written to be deleted.

## Who was aimed by the last line, so gazes can be released however the
## conversation ended.
var _aimed: Array[Unit] = []
## The conversation being followed, or null between conversations.
var _conversation: Conversation = null
## How many of its transcript entries have already been looked at.
var _seen: int = 0


func _ready() -> void:
	Conversations.follow(self, _on_conversation_began)


func _exit_tree() -> void:
	_forget()
	_release()


func _on_conversation_began(c: Conversation) -> void:
	if c.presentation != &"dialogue":
		return
	_forget()
	_conversation = c
	_seen = 0
	c.changed.connect(_on_changed)
	_on_changed()


## Mirrors dialogue_camera_rig.gd's rule exactly, and for the same reason:
## only a spoken line re-aims. An aside — an alignment note, an echoed
## response, a skill-check result — has no speaker, and re-aiming every
## head at those would make the whole cast twitch at moments nobody is
## talking.
func _on_changed() -> void:
	var c: Conversation = _conversation
	if c == null:
		return
	if c.ended:
		_forget()
		_release()
		return
	while _seen < c.transcript.size():
		var entry: Dictionary = c.transcript[_seen]
		_seen += 1
		if entry.get("kind") != &"line":
			continue
		var speaker: Unit = c.cast.get(entry.speaker) as Unit
		if is_instance_valid(speaker):
			aim_at(speaker, c.cast)


## Aims every live member of cast. The speaker is not excluded — they look
## at whoever they are addressing, which is what stops the person talking
## from being the only one in the scene staring into space.
##
## Public so a test can drive it without standing up a real conversation.
func aim_at(speaker: Unit, cast: Dictionary) -> void:
	_release()

	var addressee: Node3D = _someone_other_than(speaker, cast)
	var speaker_face: Node3D = speaker.gaze_point()

	for token in cast:
		var unit: Unit = cast[token] as Unit
		if not is_instance_valid(unit):
			continue
		var target: Node3D = addressee if unit == speaker else speaker_face
		if target and unit.gaze_at(target):
			_aimed.append(unit)


func _forget() -> void:
	if _conversation and _conversation.changed.is_connected(_on_changed):
		_conversation.changed.disconnect(_on_changed)
	_conversation = null


func _release() -> void:
	for unit in _aimed:
		if is_instance_valid(unit):
			unit.stop_gazing()
	_aimed.clear()


## The first live cast member who is not the speaker, as something to look
## at. Null in a monologue, which is why gaze_at's result is checked
## rather than assumed — a lone speaker simply keeps their animated pose.
func _someone_other_than(speaker: Unit, cast: Dictionary) -> Node3D:
	for token in cast:
		var unit: Unit = cast[token] as Unit
		if is_instance_valid(unit) and unit != speaker:
			return unit.gaze_point()
	return null
