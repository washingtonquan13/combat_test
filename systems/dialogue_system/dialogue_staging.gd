class_name DialogueStaging
extends Node
## Frames the speaker during a conversation — by asking the cinematic
## director for a scene, exactly like anything else that wants the camera.
##
## THIS IS NOT A BYPASS, and the distinction is the whole point of phase 1.
## The replaced DialogueCameraRig owned a Camera3D of its own and drove it
## from dialogue signals, which made dialogue the one system with a private
## camera. Here dialogue is an ordinary caller: it builds a scene and plays
## it through CinematicDirector like a fusion or an area entrance would.
##
## The scene is the degenerate one — a single phase of zero duration
## carrying a single camera step at offset zero. A zero-duration phase
## never awaits, so play() completes inside this call, the mode never
## reports CUTSCENE for a line of dialogue, and conversations cost exactly
## what they used to.
##
## It also gets the precedence right for free: play() refuses while a real
## cutscene is running, so a staged moment triggered from a conversation
## keeps the screen and the next line cannot yank the camera back to a
## talking head.
##
## SHORT-LIVED, like dialogue_gaze.gd. When scenes are authored per
## conversation rather than defaulted, this is what gets replaced by a
## binding — see phase 4.

## The two rules inherited verbatim from DialogueCameraRig, because they
## are what makes coverage read as coverage:
##
##   - consecutive lines from one speaker HOLD the shot; only a change of
##     speaker re-frames.
##   - an empty speaker token is one of the small echo lines
##     DialogueChoice produces (an alignment message, an echoed response, a
##     skill-check result) and never re-cuts.
var _speaker: Unit = null
var _scene: CinematicScene = null
var _cast: SceneCast = null
## Bindings are optional. No file, or no entry for a node, means the
## default shot — which is how the long tail of conversations ships with no
## authoring at all.
var _bindings: SceneBinding = null
## Which node's staged scene has already been played, so a bound scene
## fires once per node rather than once per line.
var _staged_node: String = ""


const BINDINGS_PATH: String = "res://data/cinematics/dialogue_bindings.tres"


func _ready() -> void:
	_build_default_conversation()
	if ResourceLoader.exists(BINDINGS_PATH):
		_bindings = load(BINDINGS_PATH) as SceneBinding
	DialogueManager.line_shown.connect(_on_line_shown)
	DialogueManager.dialogue_ended.connect(_on_dialogue_ended)


## Built once and replayed, not rebuilt per line — a scene is data, and the
## only thing that varies between lines is who is cast in the speaker role,
## which the cast resolves live.
func _build_default_conversation() -> void:
	var framing := CameraFraming.new()
	framing.subject_role = &"speaker"

	var shot := CameraShotStep.new()
	shot.framing = framing
	# A CUT. Never a transit: sweeping from one face to another is the
	# swoop shot-and-reverse exists to avoid.
	shot.transit_seconds = 0.0

	var beat := ScenePhase.new()
	beat.duration_seconds = 0.0
	beat.steps = [shot]

	_scene = CinematicScene.new()
	_scene.id = &"default_conversation"
	_scene.phases = [beat]

	_cast = SceneCast.new().track(&"speaker", _current_speaker)


func _current_speaker() -> Unit:
	return _speaker


func _on_line_shown(_text: String, speaker_token: String) -> void:
	if speaker_token == "":
		return
	var speaking: Unit = DialogueManager.participants.get(speaker_token) as Unit
	if not is_instance_valid(speaking) or speaking == _speaker:
		return
	_speaker = speaking

	# A node with a scene bound to it gets that scene instead of the
	# default shot — once, on the first line of the node, not on every
	# line. The binding lives in its own file; nothing here reads a
	# cinematic field off the dialogue, because there is not one.
	var staged: CinematicScene = _staged_scene()
	if staged != null:
		CinematicDirector.play(staged, _cast)
		return

	# Not awaited: a zero-duration scene finishes inside this call. The
	# result is deliberately ignored — a refusal means a cutscene owns the
	# screen, which is the correct outcome, not an error.
	CinematicDirector.play(_scene, _cast)


## The bound scene for the node being spoken, or null — including null on
## every line after the first, so a staged moment plays once.
func _staged_scene() -> CinematicScene:
	if _bindings == null or DialogueManager.current_node == null:
		return null
	var node_id: String = DialogueManager.current_node.id
	if node_id == _staged_node:
		return null
	var scene: CinematicScene = _bindings.scene_for(node_id)
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
