class_name DialogueStaging
extends Node
## Frames the speaker during a conversation, on the one cinematic camera.
##
## NOT A SCENE PER LINE. A line of dialogue asks for one thing: a cut to
## whoever is speaking, now, with no time in it. That is a single call —
## CinematicCamera.frame() — and wrapping it in a cutscene would buy
## nothing but a mounted stage per line. So the default shot goes straight
## to the camera, and only a node that has an authored cutscene BOUND to it
## (see SceneBinding) goes through CinematicDirector.play().
##
## PRECEDENCE, kept by one check: while a cutscene is running it owns the
## screen, so a speaker change does not frame anybody. A staged moment
## triggered from a conversation therefore keeps its shot, and the next
## line cannot yank the camera back to a talking head. This is the job the
## director's refusal used to do when every line was a scene.
##
## The camera itself is not dialogue's: it belongs to the viewer (see
## cinematic_camera.gd), and this is one of several callers that frame it.

## The two rules inherited from DialogueCameraRig, because they are what
## makes coverage read as coverage:
##
##   - consecutive lines from one speaker HOLD the shot; only a change of
##     speaker re-frames.
##   - an empty speaker token is one of the small echo lines
##     DialogueChoice produces (an alignment message, an echoed response, a
##     skill-check result) and never re-cuts.
var _speaker: Unit = null
## Built once and reframed with, not rebuilt per line — the only thing
## that varies between lines is who is cast as the speaker, which the cast
## resolves live.
var _framing: CameraFraming = null
var _cast: SceneCast = null
## Bindings are optional. No file, or no entry for a node, means the
## default shot — which is how the long tail of conversations ships with no
## authoring at all.
var _bindings: SceneBinding = null
## Which node's bound scene has already been played, so a bound scene
## fires once per node rather than once per line.
var _staged_node: String = ""


const BINDINGS_PATH: String = "res://cinematics/dialogue_bindings.tres"


func _ready() -> void:
	_framing = CameraFraming.new()
	_framing.subject_role = &"speaker"
	_cast = SceneCast.new().track(&"speaker", _current_speaker)
	if ResourceLoader.exists(BINDINGS_PATH):
		_bindings = load(BINDINGS_PATH) as SceneBinding
	DialogueManager.line_shown.connect(_on_line_shown)
	DialogueManager.dialogue_ended.connect(_on_dialogue_ended)


func _current_speaker() -> Unit:
	return _speaker


func _on_line_shown(_text: String, speaker_token: String) -> void:
	if speaker_token == "":
		return
	var speaking: Unit = DialogueManager.participants.get(speaker_token) as Unit
	if not is_instance_valid(speaking) or speaking == _speaker:
		return
	_speaker = speaking

	# A node with a scene bound to it plays that scene instead of the
	# default shot — once, on the first line of the node. Not awaited: the
	# conversation carries on underneath, and the scene holds the screen
	# until it ends.
	var staged: PackedScene = _staged_scene()
	if staged != null:
		CinematicDirector.play(staged, _cast)
		return

	if CinematicDirector.is_active():
		return
	var camera: CinematicCamera = CinematicDirector.camera()
	if camera:
		# A CUT. Never a transit: sweeping from one face to another is the
		# swoop shot-and-reverse exists to avoid.
		camera.frame(_framing, _cast, 0.0)


## The bound scene for the node being spoken, or null — including null on
## every line after the first, so a staged moment plays once.
func _staged_scene() -> PackedScene:
	if _bindings == null or DialogueManager.current_node == null:
		return null
	var node_id: String = DialogueManager.current_node.id
	if node_id == _staged_node:
		return null
	var scene: PackedScene = _bindings.scene_for(node_id)
	if scene == null:
		return null
	_staged_node = node_id
	return scene


func _on_dialogue_ended() -> void:
	_staged_node = ""
	_speaker = null
	var camera: CinematicCamera = CinematicDirector.camera()
	if camera:
		camera.release()
