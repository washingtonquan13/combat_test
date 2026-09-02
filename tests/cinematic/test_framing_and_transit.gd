extends AiTestCase
## Phase 1: one camera, one framing vocabulary, and the conversation rules
## that survived deleting DialogueCameraRig.
##
## The move vocabulary is asserted as what it is — ONE step type with
## different components interpolated, not one class per move. A push-in
## changes distance, an arc changes azimuth, a tilt holds position and
## moves the look target. If any of those needed its own step type, the
## polar framing would not be earning its place.
##
## WHY A GOLDEN VALUE FOR THE CONVERSATION SHOT. "Framing is unchanged from
## today" was the acceptance criterion for deleting the rig, and the rig is
## gone, so its formula is reproduced here as the reference: anchor at the
## head, rotate the subject's own forward by 20 degrees, out 1.4 metres,
## up 0.05. If CameraFraming's defaults ever drift from that, every
## conversation in the game silently reframes and nothing else would say so.

const OLD_DISTANCE := 1.4
const OLD_AZIMUTH := 20.0
const OLD_HEIGHT := 0.05

var _saved_camera: CinematicCamera = null
var _saved_participants: Dictionary = {}
var _camera: CinematicCamera = null
var _staging: DialogueStaging = null
var _scenes_played: int = 0


func run() -> void:
	_saved_camera = CinematicDirector.camera()
	_saved_participants = DialogueManager.participants.duplicate()

	_camera = CinematicCamera.new()
	_root.add_child(_camera)
	await get_tree().process_frame

	var subject: Unit = spawn_brute(0.0, 0.0)
	var other: Unit = spawn_brute(4.0, 0.0)
	var bystander: Unit = spawn_brute(0.0, 4.0)
	await get_tree().process_frame

	var cast := SceneCast.new().track_unit(&"speaker", subject).track_unit(&"listener", other)

	# --- the conversation shot is where it always was -------------------
	var default_shot := CameraFraming.new()
	var resolved: Vector3 = default_shot.resolve_position(cast)
	var expected: Vector3 = _the_old_rigs_formula(subject)
	check("the default framing puts the camera where the old rig did",
		resolved.distance_to(expected) < 0.02,
		"resolved %s, old formula gives %s — %.3fm apart. Every " % [
			str(resolved), str(expected), resolved.distance_to(expected)] +
		"conversation in the game reframes if this drifts")

	_camera.frame(default_shot, cast)
	await get_tree().process_frame
	check("and the camera actually goes there",
		_camera.camera().global_position.distance_to(expected) < 0.02,
		"camera is at %s" % str(_camera.camera().global_position))

	# --- one step type, three moves -------------------------------------
	var head: Vector3 = subject.anchor(CharacterModel.Anchor.HEAD)

	var push_in := CameraFraming.new()
	push_in.distance = OLD_DISTANCE * 0.5
	check("a push-in is the same framing with a smaller distance",
		absf(push_in.resolve_position(cast).distance_to(head) - OLD_DISTANCE * 0.5) < 0.02,
		"ended %.2fm from the head, expected %.2f" % [
			push_in.resolve_position(cast).distance_to(head), OLD_DISTANCE * 0.5])

	var arc := CameraFraming.new()
	arc.azimuth_degrees = OLD_AZIMUTH + 90.0
	var arced: Vector3 = arc.resolve_position(cast)
	check("an arc is the same framing with a different azimuth",
		absf(arced.distance_to(head) - OLD_DISTANCE) < 0.02
			and arced.distance_to(resolved) > 1.0,
		"radius went %.2f -> %.2f and it moved %.2fm; an arc keeps the " % [
			OLD_DISTANCE, arced.distance_to(head), arced.distance_to(resolved)] +
		"radius and changes where on the circle it sits")

	var tilt := CameraFraming.new()
	tilt.look_offset = Vector3(0.0, 3.0, 0.0)
	check("a tilt holds position and moves only the look target",
		tilt.resolve_position(cast).is_equal_approx(resolved)
			and not tilt.resolve_look(cast).is_equal_approx(default_shot.resolve_look(cast)),
		"position moved by %.3fm during what should be a pure tilt" %
			tilt.resolve_position(cast).distance_to(resolved))

	# --- transit ---------------------------------------------------------
	await _a_cut_is_instant_and_a_transit_is_not(cast, subject)
	await _crossing_to_another_subject_never_sweeps(cast)

	# --- the conversation rules ------------------------------------------
	await _the_rules_that_outlived_the_rig(subject, other, bystander)

	_cleanup()


## WHY NOTHING HERE AWAITS A FRAME BEFORE ASSERTING.
##
## The first version of this did, and was flaky: two runs green, one red.
## frame() applies immediately, so the state right after the call is
## deterministic, whereas one awaited frame advances the transit by an
## unbounded delta — a slow frame in a headless suite can be long enough to
## finish a one-second move outright, and then a real transit looks exactly
## like a cut. A flaky test is worse than a missing one, so the assertions
## that can be made without a clock are made without one.
func _a_cut_is_instant_and_a_transit_is_not(cast: SceneCast, subject: Unit) -> void:
	var near := CameraFraming.new()
	near.distance = 0.6
	var far := CameraFraming.new()
	far.distance = 4.0

	_camera.frame(near, cast, 0.0)
	var head: Vector3 = subject.anchor(CharacterModel.Anchor.HEAD)
	check("a zero transit is a cut — it arrives before the next frame",
		absf(_camera.camera().global_position.distance_to(head) - 0.6) < 0.05
			and is_equal_approx(_camera.transit_progress(), 1.0),
		"%.2fm from the head at progress %.2f, expected 0.60 at 1.00" % [
			_camera.camera().global_position.distance_to(head), _camera.transit_progress()])

	_camera.frame(far, cast, 60.0)
	head = subject.anchor(CharacterModel.Anchor.HEAD)
	check("and a transit starts where the camera already was",
		absf(_camera.camera().global_position.distance_to(head) - 0.6) < 0.05
			and _camera.transit_progress() < 1.0,
		"%.2fm from the head at progress %.3f — a transit that begins at " % [
			_camera.camera().global_position.distance_to(head), _camera.transit_progress()] +
		"its destination is a cut wearing a duration")

	# Arrival, driven by frames rather than asserted at a moment: however
	# long a frame takes, enough of them finish the move.
	_camera.frame(far, cast, 0.0)
	head = subject.anchor(CharacterModel.Anchor.HEAD)
	check("and a transit that runs to the end does arrive",
		absf(_camera.camera().global_position.distance_to(head) - 4.0) < 0.05,
		"%.2fm from the head, expected 4.00" %
			_camera.camera().global_position.distance_to(head))


## Shot and reverse is an EDIT. A transit across it would sweep the camera
## through the space between two faces, which is the swoop coverage exists
## to prevent — so a framing that orbits a different person snaps whatever
## the caller asked for. Asserted without awaiting, for the reason above.
func _crossing_to_another_subject_never_sweeps(cast: SceneCast) -> void:
	var on_subject := CameraFraming.new()
	_camera.frame(on_subject, cast, 0.0)

	var on_other := CameraFraming.new()
	on_other.subject_role = &"listener"
	_camera.frame(on_other, cast, 60.0)

	var reached: Vector3 = on_other.resolve_position(cast)
	check("crossing to another subject cuts even when a transit is asked for",
		_camera.camera().global_position.distance_to(reached) < 0.05
			and is_equal_approx(_camera.transit_progress(), 1.0),
		"%.2fm short of the reverse shot at progress %.2f — it is sweeping " % [
			_camera.camera().global_position.distance_to(reached),
			_camera.transit_progress()] +
		"between two faces instead of cutting")


## The two rules DialogueCameraRig enforced, now enforced by DialogueStaging.
##
## Counted through scene_started rather than through camera position,
## because the camera re-resolves its framing every frame and therefore
## follows a moving subject — position alone cannot tell "it re-cut" from
## "it kept up".
##
## A BYSTANDER IS BOUND TO THE EMPTY TOKEN, exactly as in
## test_gaze_follows_the_speaker and for the same reason: with no
## participant under "", the echo-line rule is unfalsifiable, because the
## lookup returns null and a later guard catches it whether or not the rule
## exists. Sabotaging the rule left the first version of this green.
func _the_rules_that_outlived_the_rig(a: Unit, b: Unit, bystander: Unit) -> void:
	DialogueManager.participants = {&"npc": a, &"player": b, &"": bystander}
	_staging = DialogueStaging.new()
	_root.add_child(_staging)
	CinematicDirector.scene_started.connect(_count_scene)
	await get_tree().process_frame

	_scenes_played = 0
	DialogueManager.line_shown.emit("One.", "npc")
	check("a line frames its speaker",
		_scenes_played == 1,
		"%d scenes played for one line" % _scenes_played)

	DialogueManager.line_shown.emit("Two.", "npc")
	check("consecutive lines from the same speaker hold the shot",
		_scenes_played == 1,
		"%d scenes played — the camera re-cut on a line from the person " % _scenes_played +
		"it was already framing")

	DialogueManager.line_shown.emit("(you feel uneasy)", "")
	check("an echo line with no speaker never re-cuts",
		_scenes_played == 1,
		"%d scenes played — an alignment message or skill-check result " % _scenes_played +
		"moved the camera")

	DialogueManager.line_shown.emit("My turn.", "player")
	check("and a change of speaker does cut",
		_scenes_played == 2,
		"%d scenes played — the reverse shot never happened" % _scenes_played)


func _count_scene(_scene: CinematicScene) -> void:
	_scenes_played += 1


## DialogueCameraRig's formula, reproduced verbatim as the reference.
func _the_old_rigs_formula(subject: Unit) -> Vector3:
	var anchor: Vector3 = subject.anchor(CharacterModel.Anchor.HEAD)
	var shot_dir: Vector3 = subject.visual_forward().rotated(
		Vector3.UP, deg_to_rad(OLD_AZIMUTH))
	return anchor + shot_dir * OLD_DISTANCE + Vector3(0.0, OLD_HEIGHT, 0.0)


func _cleanup() -> void:
	if CinematicDirector.scene_started.is_connected(_count_scene):
		CinematicDirector.scene_started.disconnect(_count_scene)
	if is_instance_valid(_staging):
		_staging.queue_free()
	if is_instance_valid(_camera):
		_camera.release()
		_camera.queue_free()
	CinematicDirector.register_camera(_saved_camera)
	DialogueManager.participants = _saved_participants
