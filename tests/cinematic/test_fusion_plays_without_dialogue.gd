extends AiTestCase
## Phase 2, and the acceptance test for the whole inversion.
##
## THE CRITERION IS THE TITLE. If the fusion cutscene can play end to end
## without DialogueManager being involved, cinematics are the spine and
## dialogue is one caller. If it cannot, the spine is still dialogue and
## every later phase inherits that. Drafts 1 and 2 of the plan would have
## failed this — not on dependencies, which were already fine, but because
## their step vocabulary had no way to create an actor, destroy one, or
## hold one whose owner had let go.
##
## What it exercises that no conversation ever will: actors CONSUMED
## partway through, an actor that does not exist when the scene starts, and
## staging measured from a thing rather than a face.

const DEMON_A := "res://data/units/demons/test_pixie.tres"
const DEMON_B := "res://data/units/demons/test_wolf.tres"

var _saved_root: Node = null
var _saved_camera: CinematicCamera = null
var _saved_dialogue: DialogueNode = null
var _camera: CinematicCamera = null
var _marks: Node3D = null
var _returned: bool = false
var _result: bool = false


func run() -> void:
	if not _stand_up_a_stage():
		_cleanup()
		return

	var species_a: UnitDefinition = load(DEMON_A)
	var species_b: UnitDefinition = load(DEMON_B)
	if species_a == null or species_b == null:
		check("SETUP: two demon definitions to fuse", false, "%s / %s" % [DEMON_A, DEMON_B])
		_cleanup()
		return

	var parent_a: Unit = _body(species_a)
	var parent_b: Unit = _body(species_b)
	await get_tree().process_frame

	var built: Dictionary = FusionCinematic.build(parent_a, parent_b, species_a)
	var scene: CinematicScene = built["scene"]
	var cast: SceneCast = built["cast"]

	check("the scene is assembled from its participants, not authored",
		scene.phases.size() >= 5,
		"%d phases — the beats are missing" % scene.phases.size())
	check("and every step it contains can actually fire",
		scene.unreachable_steps().is_empty(),
		"steps sit past the end of their phase: %s" % _names(scene.unreachable_steps()))

	# --- play it --------------------------------------------------------
	_drive(scene, cast)
	await get_tree().process_frame

	check("it holds the screen",
		GameMode.current_mode() == GameMode.Mode.CUTSCENE,
		"mode is %s" % GameMode.Mode.keys()[GameMode.current_mode()])

	# --- the fusion is confirmed: the roster lets the parents go ---------
	# This is what a real confirmation does, and it happens BEFORE the
	# parents leave the screen. A tracked role would start resolving to
	# nothing here, several beats early.
	var owned_a: OwnedDemon = DemonRoster.recruit(species_a)
	var owned_b: OwnedDemon = DemonRoster.recruit(species_b)
	DemonRoster.release(owned_a)
	DemonRoster.release(owned_b)

	check("the parents survive their owner letting go of them",
		cast.unit(FusionCinematic.PARENT_A) == parent_a
			and cast.unit(FusionCinematic.PARENT_B) == parent_b,
		"the cast lost one of them the moment the roster released it — a " +
		"held role is owned by the SCENE until it says otherwise")
	check("and they are still on screen",
		is_instance_valid(parent_a) and parent_a.is_inside_tree()
			and is_instance_valid(parent_b) and parent_b.is_inside_tree(),
		"a parent left the world before its dissolve beat")

	# --- and DialogueManager is never involved ---------------------------
	check("no conversation is running at any point",
		not DialogueManager.is_active() and DialogueManager.current_node == null,
		"DialogueManager.current_node is %s — the cutscene reached for " % str(DialogueManager.current_node) +
		"dialogue, which means the spine is still dialogue")

	await _until_returned(20.0)
	check("the sequence runs to the end",
		_returned and _result,
		"returned=%s completed=%s" % [str(_returned), str(_result)])

	# --- what it left behind ---------------------------------------------
	check("the parents are gone once their dissolve beat has passed",
		not is_instance_valid(parent_a) and not is_instance_valid(parent_b),
		"a parent is still in the world after the whole sequence")

	var born: Unit = cast.unit(FusionCinematic.RESULT)
	check("the result was created mid-scene and is in the world",
		born != null and born.is_inside_tree(),
		"nothing is cast as the result — a scene cannot ask an authority " +
		"for a thing that did not exist when it started, so the step that " +
		"makes it must also hold it")

	if born:
		var reveal := CameraFraming.new()
		reveal.subject_role = FusionCinematic.RESULT
		reveal.distance = 2.2
		reveal.elevation_degrees = 6.0
		check("and the camera ends on it",
			_camera.camera().global_position.distance_to(reveal.resolve_position(cast)) < 0.3,
			"camera is %.2fm from the reveal framing" %
				_camera.camera().global_position.distance_to(reveal.resolve_position(cast)))

	check("and the mode is handed back",
		GameMode.current_mode() != GameMode.Mode.CUTSCENE,
		"the director still holds the screen after the scene ended")

	_cleanup()


## Marks, a camera, and somewhere for a spawned actor to go. The AI harness
## has no world, and WorldManager.spawn_parent() falls back to the scene
## root — so without registering one, SpawnActorStep has nowhere to put the
## demon it makes and the reveal would silently never happen.
func _stand_up_a_stage() -> bool:
	_saved_root = WorldManager._scene_root
	_saved_camera = CinematicDirector.camera()
	_saved_dialogue = DialogueManager.current_node
	DialogueManager.current_node = null

	WorldManager.register_scene_root(_root)

	_marks = Node3D.new()
	_root.add_child(_marks)
	var placements: Dictionary = {
		FusionCinematic.DEVICE_MARK: Vector3(0.0, 0.0, 0.0),
		FusionCinematic.LEFT_MARK: Vector3(-1.2, 1.0, 0.0),
		FusionCinematic.RIGHT_MARK: Vector3(1.2, 1.0, 0.0),
		FusionCinematic.RESULT_MARK: Vector3(0.0, 1.0, 0.0),
	}
	for mark_name in placements:
		var mark := Marker3D.new()
		mark.name = mark_name
		_marks.add_child(mark)
		mark.global_position = placements[mark_name]
		mark.add_to_group(SceneCast.MARK_GROUP)

	_camera = CinematicCamera.new()
	_root.add_child(_camera)
	return true


func _body(species: UnitDefinition) -> Unit:
	var unit: Unit = species.unit_scene.instantiate()
	unit.definition = species
	_root.add_child(unit)
	return unit


func _drive(scene: CinematicScene, cast: SceneCast) -> void:
	_returned = false
	_result = await CinematicDirector.play(scene, cast)
	_returned = true


func _until_returned(timeout_seconds: float) -> void:
	var waited: float = 0.0
	while not _returned and waited < timeout_seconds:
		await get_tree().process_frame
		waited += get_process_delta_time()


func _names(steps: Array[SceneStep]) -> String:
	var out: PackedStringArray = []
	for step in steps:
		out.append(step.describe())
	return ", ".join(out)


func _cleanup() -> void:
	CinematicDirector.abort()
	if is_instance_valid(_camera):
		_camera.release()
		_camera.queue_free()
	if is_instance_valid(_marks):
		_marks.queue_free()
	CinematicDirector.register_camera(_saved_camera)
	WorldManager.register_scene_root(_saved_root)
	DialogueManager.current_node = _saved_dialogue
