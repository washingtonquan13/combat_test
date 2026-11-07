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
##   - an aside (an alignment message, an echoed response, a skill-check
##     result) has no speaker and never re-cuts.
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
## The conversation being staged, or null. Only one presented as dialogue
## is followed; a negotiation is a menu panel with no speaker to frame.
var _conversation: Conversation = null
## How many of its transcript entries have already been staged.
var _seen: int = 0


const BINDINGS_PATH: String = "res://cinematics/dialogue_bindings.tres"


func _ready() -> void:
	_framing = CameraFraming.new()
	_framing.subject_role = &"speaker"
	_cast = SceneCast.new().track(&"speaker", _current_speaker)
	if ResourceLoader.exists(BINDINGS_PATH):
		_bindings = load(BINDINGS_PATH) as SceneBinding
	Conversations.follow(self, _on_conversation_began)


func _exit_tree() -> void:
	_forget()


func _on_conversation_began(c: Conversation) -> void:
	if c.presentation != &"dialogue":
		return
	_forget()
	_conversation = c
	_seen = 0
	c.changed.connect(_on_changed)
	_on_changed()


func _on_changed() -> void:
	var c: Conversation = _conversation
	if c == null:
		return
	if c.ended:
		_forget()
		_on_conversation_ended()
		return
	while _seen < c.transcript.size():
		var entry: Dictionary = c.transcript[_seen]
		_seen += 1
		if entry.get("kind") == &"line":
			_on_line(entry, c.cast)


func _forget() -> void:
	if _conversation and _conversation.changed.is_connected(_on_changed):
		_conversation.changed.disconnect(_on_changed)
	_conversation = null


func _current_speaker() -> Unit:
	return _speaker


func _on_line(entry: Dictionary, cast: Dictionary) -> void:
	var speaking: Unit = cast.get(entry.speaker) as Unit
	if not is_instance_valid(speaking) or speaking == _speaker:
		return
	_speaker = speaking

	# A node with a scene bound to it plays that scene instead of the
	# default shot — once, on the first line of the node. Not awaited: the
	# conversation carries on underneath, and the scene holds the screen
	# until it ends.
	var staged: PackedScene = _staged_scene(entry.get("node", ""))
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
## every line after the first, so a staged moment plays once. node_id is
## the node the transcript entry was recorded under.
func _staged_scene(node_id: String) -> PackedScene:
	if _bindings == null or node_id == "":
		return null
	if node_id == _staged_node:
		return null
	var scene: PackedScene = _bindings.scene_for(node_id)
	if scene == null:
		return null
	_staged_node = node_id
	return scene


func _on_conversation_ended() -> void:
	_staged_node = ""
	_speaker = null
	var camera: CinematicCamera = CinematicDirector.camera()
	if camera:
		camera.release()
