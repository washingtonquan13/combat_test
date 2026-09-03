extends AiTestCase
## A scene can be an authored .tscn with a scrubbable timeline, and the
## director's contract is exactly the same as it was.
##
## WHAT IS ACTUALLY NEW HERE is the authoring surface, not the capability.
## The step model could already do everything the arrival scene does; what
## it could not do is let anyone SEE the shot while making it. So the
## checks below are deliberately about the seam rather than about the
## front end: the mode still says CUTSCENE, play() still returns true, an
## abort still returns false and leaves nothing behind. If a second way of
## authoring a scene needed a second set of guarantees, the front end would
## have grown into a second machine.
##
## THE HANG THIS EXISTS TO CATCH. The obvious way to wait for an
## AnimationPlayer is `await player.animation_finished`, and it does not
## fire when a player is STOPPED — so an aborted scene would leave play()
## suspended on a signal nothing will ever emit, forever, on the one path
## the whole always-returns contract was built to make impossible. Every
## wait below is capped in FRAMES so that hang shows up as a red check
## rather than as a suite that never ends.
##
## THE MOVE IS ASSERTED AS A CHANGE OVER TIME, in the right direction,
## rather than against a golden number. A push-in is a distance that
## shrinks; pinning it to 9.00 and 4.00 would fail every time anyone
## re-times the scene in the editor, which is the thing the timeline exists
## to make easy.

const SCENE_PATH := "res://data/cinematics/test_arena_arrival.tres"
## A definition path that LOADS and is not a UnitDefinition, so the
## unresolved-argument check exercises the stage's own guard instead of
## filling the log with a missing-file error.
const NOT_A_DEFINITION := "res://data/cinematics/test_arena_arrival.tres"

## Whichever comes first — the scene is 2.2 s and headless frames are
## short, but "short" is not a guarantee, so nothing here is measured in
## seconds.
const FRAME_CAP := 6000

## Where the leader stands. See run() for why it is nowhere near (0, 0, 0).
const LEADER_AT := Vector3(6.0, 0.0, -3.0)

var _saved_camera: CinematicCamera = null
var _camera: CinematicCamera = null
var _returned: bool = false
var _result: bool = false

var _early_distance: float = -1.0
var _early_keyed: float = -1.0
var _late_distance: float = -1.0
var _late_keyed: float = -1.0
## Set from the timeline's own signal — see the abort check for why this
## is the one thing that tells a cut-short scene from a waited-out one.
var _animation_finished: bool = false


func wants_world() -> bool:
	return true


func run() -> void:
	_saved_camera = CinematicDirector.camera()
	_camera = CinematicCamera.new()
	_root.add_child(_camera)

	# OFF THE ORIGIN, and this is not decoration. The stage is anchored at
	# the world origin (the arrival scene names no anchor mark), so a leader
	# standing at (0, 0, 0) makes "the marker was snapped onto the actor"
	# and "the marker was never touched" the same coordinates — which is
	# exactly the false green that let a sabotage of bind() run green the
	# first time this suite was written. The same trap tests/world's own
	# harness suite documents, in the same words.
	var leader: Unit = spawn_brute(LEADER_AT.x, LEADER_AT.z)
	await get_tree().process_frame

	var scene: CinematicScene = load(SCENE_PATH) as CinematicScene
	check("the authored arrival scene loads and is a TIMED scene",
		scene != null and scene.is_timed(),
		"loaded %s — a scene with no stage is still driven by phases, so " % str(scene) +
		"nothing below is testing the timeline path")
	if scene == null or not scene.is_timed():
		_cleanup()
		return

	check("and it says so when asked to describe itself",
		scene.describe().contains("timed"),
		"describe() says '%s'" % scene.describe())

	await _it_plays_through_to_the_end(scene, leader)
	await _an_abort_leaves_nothing_behind(scene, leader)
	_a_method_track_survives_an_unresolved_role(leader)
	_cleanup()


## The whole path, once: mount, bind, run the timeline, return true.
func _it_plays_through_to_the_end(scene: CinematicScene, leader: Unit) -> void:
	var cast := SceneCast.new().track_unit(&"leader", leader)
	_drive(scene, cast)
	await get_tree().process_frame

	check("a timed scene claims the screen like any other",
		CinematicDirector.is_active()
			and GameMode.current_mode() == GameMode.Mode.CUTSCENE,
		"active=%s, mode=%s — the stage path does not reach the same " % [
			CinematicDirector.is_active(),
			GameMode.Mode.keys()[GameMode.current_mode()]] +
		"claim the phase path does, so nothing yields to it")

	var stage: CinematicStage = _mounted_stage()
	check("and the authored stage is standing in the world",
		stage != null,
		"no CinematicStage under the world — the scene named one and " +
		"nothing was instantiated")
	if stage == null:
		await _until_returned()
		return

	# The snap: this role is NOT driven by its marker (the player's leader
	# arrived under their own power), so bind() puts the MARKER on the
	# ACTOR instead — which is what gives a rig aiming at "leader"
	# something to point at in the editor, and what keeps the authored
	# layout and the played one the same shape.
	var marker: StageRole = _role_marker(stage, &"leader")
	check("SETUP: the actor is nowhere near the stage's own origin",
		marker != null and stage.global_position.distance_to(leader.global_position) > 3.0,
		"the leader is %.2fm from the stage — if it were on top of it, " % (
			stage.global_position.distance_to(leader.global_position)) +
		"a bind() that snapped nothing would be indistinguishable from " +
		"one that snapped correctly")
	check("bind() snapped the undriven role's marker onto its actor",
		marker != null
			and marker.global_position.distance_to(leader.global_position) < 0.05,
		"marker is at %s, the actor at %s" % [
			str(marker.global_position) if marker else "nowhere",
			str(leader.global_position)])

	var timeline: AnimationPlayer = stage.timeline()
	check("SETUP: the stage's Timeline holds the named animation",
		timeline != null and timeline.has_animation(scene.animation),
		"no '%s' on a player named 'Timeline'" % scene.animation)
	if timeline == null:
		await _until_returned()
		return

	# Time is driven by frames and READ off the animation, never assumed
	# from a wall clock: a headless frame is however long the machine
	# managed, so "0.1 seconds have passed" is not something a test here
	# can know except by asking the thing that is counting.
	await _sample_at(timeline, stage, leader, 0.1, true)
	await _sample_at(timeline, stage, leader, 1.9, false)

	check("SETUP: both samples were taken",
		_early_distance > 0.0 and _late_distance > 0.0,
		"early=%.2f late=%.2f — the timeline never reached one of the " % [
			_early_distance, _late_distance] +
		"sample points, so the move below is untested")

	check("the timeline keys the rig's framing, not a camera transform",
		_early_keyed > 7.0 and _late_keyed < 5.5,
		"FramingRig.distance went %.2f -> %.2f; the authored track says " % [
			_early_keyed, _late_keyed] + "9 -> 4")

	check("and the camera genuinely pushes in on the subject over the shot",
		_early_distance > 7.0 and _late_distance < 5.5
			and _early_distance - _late_distance > 3.0,
		"camera was %.2fm from the leader early and %.2fm late — a " % [
			_early_distance, _late_distance] +
		"push-in is a distance that shrinks, and this one moved %.2fm" % (
			_early_distance - _late_distance))

	await _until_returned()
	check("play() returns on its own when the timeline ends",
		_returned,
		"still suspended after %d frames on a 2.2 second scene — this is " % FRAME_CAP +
		"what awaiting animation_finished instead of polling looks like")
	check("and reports that it completed",
		_result,
		"returned false for a scene nothing interrupted")
	# One frame, because queue_free is deferred — the director asks for the
	# teardown before it returns, and the tree performs it at the end of
	# the frame.
	await get_tree().process_frame
	check("and the stage is taken down with it",
		_mounted_stage() == null,
		"a CinematicStage is still in the world after its scene ended")


## An abort has to unwind the same way, and this is the path that would
## hang: a stopped AnimationPlayer emits nothing.
func _an_abort_leaves_nothing_behind(scene: CinematicScene, leader: Unit) -> void:
	var cast := SceneCast.new().track_unit(&"leader", leader)
	_drive(scene, cast)
	await get_tree().process_frame

	var stage: CinematicStage = _mounted_stage()
	check("SETUP: the second play mounted a stage to abort",
		stage != null)
	if stage == null:
		return

	# THE DISCRIMINATOR, and it took a sabotage run to find it. A director
	# that awaited animation_finished still RETURNS false here — abort()
	# bumps the generation, the animation runs its remaining two seconds
	# out, the signal fires, and play() unwinds late but correctly. Every
	# other check below passes under that sabotage. What separates the two
	# is whether the timeline was STOPPED or merely waited out, and the
	# tell is that a stopped player emits nothing. (It is also why the real
	# hang exists: when the abort comes from a world teardown, that player
	# is freed rather than left running, and the signal never arrives at
	# all.)
	_animation_finished = false
	var timeline: AnimationPlayer = stage.timeline()
	if timeline:
		timeline.animation_finished.connect(_note_animation_finished)

	CinematicDirector.abort()
	await _until_returned()

	check("an aborted timeline releases the caller instead of stranding it",
		_returned,
		"play() is still suspended %d frames after abort() — a stopped " % FRAME_CAP +
		"AnimationPlayer never emits animation_finished, so an await on " +
		"it is a permanent hang")
	check("and it CUT the timeline short rather than waiting it out",
		not _animation_finished,
		"the animation ran to its natural end before play() returned — " +
		"the director is waiting on animation_finished instead of polling, " +
		"so an abort takes as long as the scene it aborted")
	check("and reports that it did NOT complete",
		not _result,
		"returned true for a scene that was cut short")

	await get_tree().process_frame
	check("and the stage is gone from the tree",
		not is_instance_valid(stage),
		"the aborted stage is still in the world, still driving whatever " +
		"it was driving")
	check("and the camera is handed back rather than frozen mid-move",
		not _camera.is_framing(),
		"the cinematic camera still holds a half-finished push-in on a " +
		"stage that no longer exists")
	check("and nothing is left claiming the mode",
		not CinematicDirector.is_active()
			and GameMode.current_mode() != GameMode.Mode.CUTSCENE,
		"the director still claims the screen after aborting")


## A method track fires from inside the AnimationPlayer's own process
## step. Throwing there abandons the rest of the track mid-shot and the
## scene FREEZES rather than looking wrong, so every one of these methods
## declines loudly and carries on.
func _a_method_track_survives_an_unresolved_role(leader: Unit) -> void:
	var stage := CinematicStage.new()
	_root.add_child(stage)
	var cast := SceneCast.new().track_unit(&"leader", leader)
	cast.tree = get_tree()
	stage.bind(cast)

	stage.spawn(&"nobody_at_all", NOT_A_DEFINITION, &"nowhere")
	stage.place(&"nobody_at_all", &"nowhere")
	stage.clip(&"nobody_at_all", "Idle")
	stage.despawn(&"nobody_at_all")
	stage.effect(&"no_such_prop", &"nobody_at_all")
	stage.sound(&"no_such_prop", &"nobody_at_all")

	check("every stage method declines an unresolved role instead of throwing",
		true,
		"reaching this line at all is the assertion")

	check("and a role that WAS bound still resolves on the same stage",
		stage._actor(&"leader") == leader,
		"the guards above swallowed the working case too")

	stage.unbind()
	stage.queue_free()


# --- driving -------------------------------------------------------


## Starts play() without awaiting it, so the suite can look at the game
## WHILE a scene runs rather than only after.
func _drive(scene: CinematicScene, cast: SceneCast) -> void:
	_returned = false
	_result = await CinematicDirector.play(scene, cast)
	_returned = true


func _until_returned() -> void:
	var spent: int = 0
	while not _returned and spent < FRAME_CAP:
		await get_tree().process_frame
		spent += 1


## Advances frames until the animation reaches `at` seconds, then records
## how far the camera is from the subject and what the rig's distance
## property has been keyed to.
func _sample_at(timeline: AnimationPlayer, stage: CinematicStage, leader: Unit,
		at: float, early: bool) -> void:
	var spent: int = 0
	while timeline.is_playing() and timeline.current_animation_position < at \
			and spent < FRAME_CAP:
		await get_tree().process_frame
		spent += 1
	var rig: FramingRig = stage.get_node_or_null(NodePath("FramingRig")) as FramingRig
	if rig == null:
		return
	var head: Vector3 = leader.anchor(CharacterModel.Anchor.HEAD)
	var where: float = _camera.camera().global_position.distance_to(head)
	if early:
		_early_distance = where
		_early_keyed = rig.distance
	else:
		_late_distance = where
		_late_keyed = rig.distance


func _note_animation_finished(_name: StringName) -> void:
	_animation_finished = true


func _mounted_stage() -> CinematicStage:
	var parent: Node = WorldManager.spawn_parent()
	if parent == null:
		return null
	for child in parent.get_children():
		if child is CinematicStage:
			return child
	return null


func _role_marker(stage: CinematicStage, role: StringName) -> StageRole:
	for node in stage.find_children("*", "", true, false):
		if node is StageRole and (node as StageRole).role_name() == role:
			return node
	return null


func _cleanup() -> void:
	CinematicDirector.abort()
	if is_instance_valid(_camera):
		_camera.release()
		_camera.queue_free()
	CinematicDirector.register_camera(_saved_camera)
