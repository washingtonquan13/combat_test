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


func _ready() -> void:
	_build_default_conversation()
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
	# Not awaited: a zero-duration scene finishes inside this call. The
	# result is deliberately ignored — a refusal means a cutscene owns the
	# screen, which is the correct outcome, not an error.
	CinematicDirector.play(_scene, _cast)


func _on_dialogue_ended() -> void:
	_speaker = null
	var camera: CinematicCamera = CinematicDirector.camera()
	if camera:
		camera.release()
