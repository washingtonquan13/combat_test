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
##   - a change of speaker cuts to them over the listener's shoulder. If
##     they keep talking, their second line cuts in to a close shot, and
##     further lines hold it.
##   - an aside (an alignment message, a skill-check result) has no
##     speaker and never re-cuts. A response the player's character says
##     aloud is a line, not an aside: it cuts to them, and is held as a
##     turn while they say it (see _hold_spoken).
var _speaker: Unit = null
## Who the speaker is talking to, or null when nobody else is in the
## conversation. The shots below need two people; one alone gets the plain
## shot.
var _listener: Unit = null
## How many lines in a row the speaker has had, which picks the shot.
var _run: int = 0
## Which side of the line between the two the camera works from, +1 or -1,
## or 0 before the first shot. Chosen once per conversation and kept:
## crossing that line flips who is on the left, which reads as the two
## having swapped places.
var _side: float = 0.0
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
## Whose face is mouthing the latest line, so the next speaker shuts it.
var _talking: Unit = null
## The spoken-line wait being held (its serial), or -1. A response the
## player's character says aloud is a turn: the conversation waits on it
## (see DialogueChoice.resolve) while it is said, and this ends the wait.
var _spoken_serial: int = -1
var _spoken_elapsed: float = 0.0
var _spoken_quiet: float = 0.0
var _spoken_min: float = 0.0


const BINDINGS_PATH: String = "res://cinematics/dialogue_bindings.tres"
## A spoken turn holds at least this long per letter of the line, read or
## mouthed, between these bounds; then a short beat after the mouth closes.
const SPOKEN_SECONDS_PER_LETTER: float = 0.04
const SPOKEN_MIN_SECONDS: float = 1.0
const SPOKEN_MAX_SECONDS: float = 5.0
const SPOKEN_TAIL_SECONDS: float = 0.3

## OVER THE SHOULDER: the camera stands behind the listener, off to one
## side, and looks at the speaker — who sits on the far third of the frame
## with the listener's shoulder in the near corner.
const SHOULDER_DISTANCE: float = 1.2
const SHOULDER_AZIMUTH: float = 28.0
const SHOULDER_ELEVATION: float = 6.0
const SHOULDER_FOV: float = 15.0
const SHOULDER_PAN: float = -3.0
## CLOSE: the speaker alone, from the same side, off-centre with the empty
## part of the frame in front of their face.
const CLOSE_DISTANCE: float = 1.15
const CLOSE_AZIMUTH: float = 28.0
const CLOSE_ELEVATION: float = 1.0
const CLOSE_FOV: float = 30.0
const CLOSE_PAN: float = -4.5
## Aims below the head so the face sits in the upper half of the frame,
## clear of the line and the choices under it.
const AIM_DROP: float = 0.04
## How far out of focus the listener's shoulder and the scenery go.
const FOCUS_BLUR: float = 0.09


func _ready() -> void:
	_framing = CameraFraming.new()
	_framing.subject_role = &"speaker"
	_cast = SceneCast.new().track(&"speaker", _current_speaker).track(&"listener", _current_listener)
	if ResourceLoader.exists(BINDINGS_PATH):
		_bindings = load(BINDINGS_PATH) as SceneBinding
	set_process(false)
	Conversations.follow(self, _on_conversation_began)


func _exit_tree() -> void:
	_forget()


func _on_conversation_began(c: Conversation) -> void:
	if c.presentation != &"dialogue":
		return
	_forget()
	_conversation = c
	_seen = 0
	_spoken_serial = -1
	c.attach(&"spoken", self)
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
	var wait: Dictionary = c.waiting
	if wait.get("kind") == &"spoken" and wait.serial != _spoken_serial:
		_hold_spoken(wait.serial, c)


func _forget() -> void:
	if _conversation:
		_conversation.detach(&"spoken", self)
		if _conversation.changed.is_connected(_on_changed):
			_conversation.changed.disconnect(_on_changed)
	_conversation = null
	_spoken_serial = -1
	set_process(false)
	_hush()


## Holds the spoken turn just recorded for as long as it takes to say:
## the reading time of the line, and until the speaker's mouth closes.
func _hold_spoken(serial: int, c: Conversation) -> void:
	_spoken_serial = serial
	_spoken_elapsed = 0.0
	_spoken_quiet = 0.0
	var said: String = c.transcript[-1].text if not c.transcript.is_empty() else ""
	_spoken_min = clampf(said.length() * SPOKEN_SECONDS_PER_LETTER, SPOKEN_MIN_SECONDS, SPOKEN_MAX_SECONDS)
	set_process(true)


func _process(delta: float) -> void:
	if not _holding_spoken():
		set_process(false)
		return
	_spoken_elapsed += delta
	var face: FaceDriver = FaceDriver.of(_talking) if is_instance_valid(_talking) else null
	if face and face.is_talking():
		_spoken_quiet = 0.0
		return
	_spoken_quiet += delta
	if _spoken_elapsed >= _spoken_min and _spoken_quiet >= SPOKEN_TAIL_SECONDS:
		_end_spoken()


## The same key that moves a cutscene line on cuts a spoken turn short.
func _unhandled_input(event: InputEvent) -> void:
	if _holding_spoken() and event.is_action_pressed(&"cinematic_advance"):
		get_viewport().set_input_as_handled()
		_end_spoken()


func _holding_spoken() -> bool:
	return _conversation != null and _spoken_serial >= 0 			and _conversation.waiting.get("serial", -1) == _spoken_serial


func _end_spoken() -> void:
	set_process(false)
	if _holding_spoken():
		_conversation.complete()


func _hush() -> void:
	var face: FaceDriver = FaceDriver.of(_talking) if is_instance_valid(_talking) else null
	if face:
		face.hush()
	_talking = null


func _current_speaker() -> Unit:
	return _speaker


func _current_listener() -> Unit:
	return _listener if is_instance_valid(_listener) else null


func _someone_other_than(speaker: Unit, cast: Dictionary) -> Unit:
	for token in cast:
		var unit: Unit = cast[token] as Unit
		if is_instance_valid(unit) and unit != speaker:
			return unit
	return null


## The shot for the speaker's `run`-th line in a row. The plain shot when
## they have nobody to talk to.
func _shot(run: int) -> CameraFraming:
	if not is_instance_valid(_listener):
		return _framing
	var shot := CameraFraming.new()
	shot.look_offset = Vector3(0.0, -AIM_DROP, 0.0)
	shot.focus_blur = FOCUS_BLUR
	if run <= 1:
		shot.subject_role = &"listener"
		shot.look_role = &"speaker"
		shot.distance = SHOULDER_DISTANCE
		shot.elevation_degrees = SHOULDER_ELEVATION
		shot.fov_degrees = SHOULDER_FOV
		_keep_side(shot, 180.0, SHOULDER_AZIMUTH, SHOULDER_PAN)
	else:
		shot.subject_role = &"speaker"
		shot.distance = CLOSE_DISTANCE
		shot.elevation_degrees = CLOSE_ELEVATION
		shot.fov_degrees = CLOSE_FOV
		_keep_side(shot, 0.0, CLOSE_AZIMUTH, -CLOSE_PAN)
	return shot


## Swings `shot` off `centre` by `swing` degrees, to whichever hand keeps
## the camera on this conversation's side of the line between the two, and
## pans it by `pan` the same way round.
func _keep_side(shot: CameraFraming, centre: float, swing: float, pan: float) -> void:
	var from: Vector3 = _speaker.global_position
	var along: Vector3 = _listener.global_position - from
	if _side == 0.0:
		var view: Camera3D = _speaker.get_viewport().get_camera_3d()
		var seen_from: Vector3 = view.global_position if view else from + Vector3.RIGHT
		_side = 1.0 if along.cross(seen_from - from).y >= 0.0 else -1.0
	shot.azimuth_degrees = centre + swing
	shot.pan_degrees = pan
	var eye: Vector3 = shot.resolve_position(_cast)
	if along.cross(eye - from).y * _side < 0.0:
		shot.azimuth_degrees = centre - swing
		shot.pan_degrees = -pan


func _on_line(entry: Dictionary, cast: Dictionary) -> void:
	var speaking: Unit = cast.get(entry.speaker) as Unit
	if not is_instance_valid(speaking):
		return
	# Every line is mouthed, the held ones included; whoever was talking
	# stops when someone else starts.
	if speaking != _talking:
		_hush()
	var face: FaceDriver = FaceDriver.of(speaking)
	if face:
		face.talk(entry.text)
		_talking = speaking
	if speaking == _speaker:
		_run += 1
	else:
		_run = 1
		_speaker = speaking
		_listener = _someone_other_than(speaking, cast)
	if _run > 2:
		return
	var opening: bool = _run == 1

	# A node with a scene bound to it plays that scene instead of the
	# default shot — once, on the first line of the node. Not awaited: the
	# conversation carries on underneath, and the scene holds the screen
	# until it ends.
	var staged: PackedScene = _staged_scene(entry.get("node", "")) if opening else null
	if staged != null:
		CinematicDirector.play(staged, _cast)
		return

	if CinematicDirector.is_active():
		return
	var camera: CinematicCamera = CinematicDirector.camera()
	if camera:
		# A CUT. Never a transit: sweeping from one face to another is the
		# swoop shot-and-reverse exists to avoid.
		camera.frame(_shot(_run), _cast, 0.0, -2.0, true)


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
	_hush()
	_staged_node = ""
	_speaker = null
	_listener = null
	_run = 0
	_side = 0.0
	var camera: CinematicCamera = CinematicDirector.camera()
	if camera:
		camera.release()
