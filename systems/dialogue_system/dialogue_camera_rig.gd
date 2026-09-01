class_name DialogueCameraRig
extends Node3D
## Owns the dedicated cinematic Camera3D used for BG3/Mass-Effect-style
## conversation shots — completely separate from crpg_camera.gd (see
## camera_director.gd's own header for why: one script trying to own both
## "orbit the battlefield" and "frame a speaker's face" would fight its
## own state, the god-object crpg_camera.gd was deliberately kept out of
## becoming).
##
## Listens to DialogueManager's signals and reacts — never touches
## DialogueManager itself, never called directly by anything else.
##
## The Camera3D itself is created in code rather than a companion .tscn —
## one child node is all this needs, same "script-only, no wrapper scene
## for something this simple" precedent hotbar_divider.gd and
## interaction_menu.gd's PopupMenu.new() already use.
##
## Framing anchor: looks for a child node named "FaceAnchor" anywhere
## under the speaking Unit (meant to be a Marker3D under a
## BoneAttachment3D on unit.tscn's skeleton, hand-placed in the editor —
## same "give it a real 3D gizmo instead of a typed-in bone name guess"
## precedent ladder.gd already uses for its own base_marker/top_marker).
## Falls back to a height-based estimate (Unit.height) if that hasn't
## been set up yet, so the whole system works today and just gets more
## precise once the anchor exists — not blocked on it.
##
## Cuts are HARD, not panned — smoothly re-panning between two different
## people's faces reads as a disorienting swoop, not a clean shot/
## reverse-shot. Only repositions when the speaker actually changes;
## multiple lines in a row from the same person hold the same shot.

@export var shot_distance: float = 1.4
@export var shot_height_offset: float = 0.05
## Slight 3/4 angle rather than a dead-on mugshot — degrees, applied
## around the speaker's own forward direction.
@export var shot_horizontal_offset_degrees: float = 20.0
@export var fov_degrees: float = 40.0

var _camera: Camera3D
var _current_speaker: Unit = null


func _ready() -> void:
	_camera = Camera3D.new()
	_camera.fov = fov_degrees
	add_child(_camera)

	DialogueManager.dialogue_started.connect(_on_dialogue_started)
	DialogueManager.line_shown.connect(_on_line_shown)
	DialogueManager.dialogue_ended.connect(_on_dialogue_ended)


func _on_dialogue_started(_root: DialogueNode) -> void:
	_current_speaker = null
	CameraDirector.activate_cinematic_camera(_camera)


## speaker_token is "" for the small echo lines DialogueChoice.resolve
## produces (alignment message, echoed response, skill check result) —
## deliberately no re-cut for those, only a node's own text_block drives
## a shot change.
func _on_line_shown(_text: String, speaker_token: String) -> void:
	if speaker_token == "":
		return

	var unit: Unit = DialogueManager.participants.get(speaker_token)
	if not unit or unit == _current_speaker:
		return

	_current_speaker = unit
	_frame_speaker(unit)


func _on_dialogue_ended() -> void:
	_current_speaker = null
	CameraDirector.deactivate_cinematic_camera()


func _frame_speaker(unit: Unit) -> void:
	var anchor: Vector3 = _get_face_anchor(unit)
	var forward: Vector3 = unit.visual_forward()
	var shot_dir: Vector3 = forward.rotated(Vector3.UP, deg_to_rad(shot_horizontal_offset_degrees))

	_camera.global_position = anchor + shot_dir * shot_distance + Vector3(0, shot_height_offset, 0)
	_camera.look_at(anchor, Vector3.UP)


## Asked of the BODY rather than searched for by name. A dragon's face is
## not at 85% of its height, and this used to be the only caller that even
## tried — everything else aiming at part of a creature used a constant.
func _get_face_anchor(unit: Unit) -> Vector3:
	return unit.anchor(CharacterModel.Anchor.HEAD)
