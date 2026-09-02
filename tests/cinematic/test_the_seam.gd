extends AiTestCase
## Phase 0 of the cinematic director: something asks for a scene, the game
## yields to it, and it always hands control back.
##
## NO VISUALS ARE TESTED HERE, and none exist yet. The whole point of
## building the seam alone is that a wrong seam is invisible and expensive
## later — this project has been burned twice in exactly that place, once
## by a mode with three stored copies that deadlocked save loading, and
## once by a pause-for-presentation pattern that can hang.
##
## THE CALLER HAS NO DIALOGUE INVOLVEMENT ANYWHERE IN THIS SUITE. That is
## the acceptance criterion, not an incidental detail: drafts 1 and 2 of
## the plan had cinematics hanging off dialogue, and the tell that the
## spine was still wrong was that every example began with a dialogue node.
## If this suite ever needs DialogueManager to stage a scene, the
## inversion has quietly come undone. It appears once below, and only to
## prove that a cutscene OUTRANKS a conversation.

const HOLD := 0.25

var _returned: bool = false
var _result: bool = false
var _saved_node: DialogueNode = null


func run() -> void:
	_saved_node = DialogueManager.current_node

	check("SETUP: nothing is playing to begin with",
		not CinematicDirector.is_active())

	# --- refusals cost nothing -----------------------------------------
	check("a null scene is refused without claiming anything",
		not await CinematicDirector.play(null) and not CinematicDirector.is_active(),
		"play(null) either returned true or left the director active")

	# --- the mode claim ------------------------------------------------
	var scene := CinematicScene.new()
	scene.id = &"test_seam"
	scene.hold_seconds = HOLD

	var before: GameMode.Mode = GameMode.current_mode()
	_drive(scene)
	await get_tree().process_frame

	check("a caller with no dialogue involvement can stage a scene",
		CinematicDirector.is_active(),
		"the director never started")

	check("and the game reports CUTSCENE while it holds",
		GameMode.current_mode() == GameMode.Mode.CUTSCENE,
		"mode is %s" % GameMode.Mode.keys()[GameMode.current_mode()])

	# --- what yielding actually means ----------------------------------
	check("travel yields to it",
		not GameMode.can_transition(),
		"can_transition() is true during a cutscene, so a door could be " +
		"walked through mid-shot")

	check("and the tactical camera yields to it",
		not CameraDirector.has_control(),
		"the player can still orbit the battlefield during a cutscene")

	check("and saving is refused during one",
		not SaveManager.can_save(),
		"a save taken mid-cutscene would capture a state nothing restores")

	# --- precedence: the one place dialogue appears --------------------
	# A cutscene staged FROM a conversation leaves that conversation
	# running underneath, so DialogueManager.is_active() is still true. If
	# DIALOGUE were asked first, a locked cinematic would report DIALOGUE
	# and keep running dialogue's input rules.
	DialogueManager.current_node = DialogueNode.new()
	check("SETUP: a dialogue really is active underneath",
		DialogueManager.is_active())
	check("a cutscene outranks a conversation running underneath it",
		GameMode.current_mode() == GameMode.Mode.CUTSCENE,
		"mode is %s — CUTSCENE is not being asked first" % GameMode.Mode.keys()[GameMode.current_mode()])
	DialogueManager.current_node = _saved_node

	# --- one at a time --------------------------------------------------
	var second := CinematicScene.new()
	second.id = &"test_second"
	check("a second scene is refused while one is playing",
		not await CinematicDirector.play(second),
		"two scenes ran at once, so nothing owns the screen")

	# --- and it hands control back --------------------------------------
	await _until_returned(2.0)
	check("play() returns on its own",
		_returned,
		"still suspended %.2fs after a %.2fs scene" % [2.0, HOLD])
	check("and reports that it completed",
		_result,
		"returned false for a scene nothing interrupted")
	check("and the mode goes back to what was underneath",
		GameMode.current_mode() == before,
		"was %s before, %s after" % [
			GameMode.Mode.keys()[before], GameMode.Mode.keys()[GameMode.current_mode()]])

	await _a_world_teardown_releases_the_caller()
	_cleanup()


## The hazard this whole design exists to avoid: a caller suspended forever
## because the thing that was supposed to release it went away.
##
## Announces a world teardown rather than calling discard_worlds(), and
## that is not a shortcut. discard_worlds() gates on can_rebuild(), which
## needs a registered world host that this harness does not have, so the
## call refuses and emits nothing — a version of this test that called it
## passed its setup and then failed three checks for a reason that had
## nothing to do with the director. What a real teardown actually does to
## anyone listening is emit world_loading(null) on its first line, which is
## what is reproduced here.
func _a_world_teardown_releases_the_caller() -> void:
	var scene := CinematicScene.new()
	scene.id = &"test_interrupted"
	# Long enough that returning promptly can only mean it was cut short,
	# never that it simply finished.
	scene.hold_seconds = 5.0

	_returned = false
	_drive(scene)
	await get_tree().process_frame
	if not CinematicDirector.is_active():
		check("SETUP: the long scene started", false)
		return

	WorldManager.world_loading.emit(null)
	await _until_returned(1.0)

	check("a world teardown releases the caller instead of stranding it",
		_returned,
		"play() is still suspended a second after the world went away, on " +
		"a scene with 5 seconds left — this is the hang an awaited signal " +
		"would have produced")
	check("and it reports that it did NOT complete",
		not _result,
		"returned true for a scene that was cut short, so a caller cannot " +
		"tell an abort from a clean finish")
	check("and nothing is left holding the mode",
		not CinematicDirector.is_active() and GameMode.current_mode() != GameMode.Mode.CUTSCENE,
		"the director still claims the screen after aborting")


## Starts play() without awaiting it, so the test can look at the game
## WHILE a scene is running rather than only after.
func _drive(scene: CinematicScene) -> void:
	_returned = false
	_result = await CinematicDirector.play(scene)
	_returned = true


func _until_returned(timeout_seconds: float) -> void:
	var waited: float = 0.0
	while not _returned and waited < timeout_seconds:
		await get_tree().process_frame
		waited += get_process_delta_time()


func _cleanup() -> void:
	CinematicDirector.abort()
	DialogueManager.current_node = _saved_node
