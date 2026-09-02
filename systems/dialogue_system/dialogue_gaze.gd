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
## dialogue_camera_rig.gd and skill_check_dice_popup.gd: it reads
## DialogueManager's signals and never calls back into it. DialogueManager
## stays "deliberately dumb about PRESENTATION" (see its own header).
##
## ONE node, not a component per unit. A Unit-owned listener connected to
## an autoload signal outlives its own freed owner — that exact leak has
## bitten this project before — whereas this lives on MainRoot for the
## life of the game and holds only weak intent.
##
## SHORT-LIVED BY DESIGN. When the cinematic director exists, aiming a
## gaze becomes an ordinary scene step and this node is absorbed along
## with dialogue_camera_rig.gd. It is written to be deleted.

## Who was aimed by the last line, so gazes can be released even if the
## participant table has already been cleared by the time dialogue ends.
var _aimed: Array[Unit] = []


func _ready() -> void:
	DialogueManager.line_shown.connect(_on_line_shown)
	DialogueManager.dialogue_ended.connect(_on_dialogue_ended)


## Mirrors dialogue_camera_rig.gd's rule exactly, and for the same reason:
## an empty speaker_token is one of the small echo lines DialogueChoice
## produces — an alignment message, an echoed response, a skill-check
## result — and re-aiming every head at those would make the whole cast
## twitch at moments nobody is talking.
func _on_line_shown(_text: String, speaker_token: String) -> void:
	if speaker_token == "":
		return
	var speaker: Unit = DialogueManager.participants.get(speaker_token) as Unit
	if not is_instance_valid(speaker):
		return
	aim_at(speaker)


## Aims every live participant. The speaker is not excluded — they look at
## whoever they are addressing, which is what stops the person talking
## from being the only one in the scene staring into space.
##
## Public so a test can drive it without standing up a real conversation.
func aim_at(speaker: Unit) -> void:
	_release()

	var addressee: Node3D = _someone_other_than(speaker)
	var speaker_face: Node3D = speaker.gaze_point()

	for token in DialogueManager.participants:
		var unit: Unit = DialogueManager.participants[token] as Unit
		if not is_instance_valid(unit):
			continue
		var target: Node3D = addressee if unit == speaker else speaker_face
		if target and unit.gaze_at(target):
			_aimed.append(unit)


func _on_dialogue_ended() -> void:
	_release()


func _release() -> void:
	for unit in _aimed:
		if is_instance_valid(unit):
			unit.stop_gazing()
	_aimed.clear()


## The first live participant who is not the speaker, as something to look
## at. Null in a monologue, which is why gaze_at's result is checked
## rather than assumed — a lone speaker simply keeps their animated pose.
func _someone_other_than(speaker: Unit) -> Node3D:
	for token in DialogueManager.participants:
		var unit: Unit = DialogueManager.participants[token] as Unit
		if is_instance_valid(unit) and unit != speaker:
			return unit.gaze_point()
	return null
