extends AiTestCase
## Phase 2, and the acceptance test for the whole inversion.
##
## THE CRITERION IS THE TITLE. If the fusion cutscene can play end to end
## without a conversation being involved, cinematics are the spine and
## dialogue is one caller. If it cannot, the spine is still dialogue and
## every later phase inherits that. Drafts 1 and 2 of the plan would have
## failed this — not on dependencies, which were already fine, but because
## their vocabulary had no way to create an actor, destroy one, or hold one
## whose owner had let go.
##
## What it exercises that no conversation ever will: actors CONSUMED
## partway through, an actor that does not exist when the scene starts, and
## staging measured from a thing rather than a face.
##
## NOW PLAYED FROM THE AUTHORED FILE. The scene used to be assembled by a
## FusionCinematic builder, and this suite used to assert that it was —
## that its five beats were there and that every step it contained could
## fire. Those checks went with the builder. The scene is
## cinematics/fusion.tscn, driven by a timeline anyone can scrub, and what
## replaces them is the same claim one layer down: the file loads, its root
## is a stage, and the performance is on its Timeline.
##
## THE ONE THING THE TIMELINE COULD NOT SWALLOW is the result demon. It is
## computed from the two going in, and a method track key cannot carry a
## Resource — so the caller hands the DEFINITION to the director as props
## and the spawn key names the slot. The "result appears" check below is
## the only thing that proves that route works end to end.

const DEMON_A := "res://data/units/demons/test_pixie.tres"
const DEMON_B := "res://data/units/demons/test_wolf.tres"

## Capped in FRAMES, never in accumulated delta. A headless frame is
## however long the machine managed, so a seconds budget is not a bound —
## and the animation is advancing on the same clock the budget would be
## spending, which makes the two indistinguishable when something stalls.
const FRAME_CAP := 12000

var _saved_root: Node = null
var _saved_camera: CinematicCamera = null
var _saved_dialogue: Conversation = null
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

	var scene: PackedScene = load(FusionRitual.CUTSCENE_PATH) as PackedScene
	check("the fusion cutscene is an authored stage with a performance on its Timeline",
		_has_performance(scene),
		"loaded %s — its root is not a CinematicStage with a '%s' " % [
			str(scene), CinematicStage.DEFAULT_ANIMATION] +
		"animation on a 'Timeline' player, so the reveal can never happen")
	if not _has_performance(scene):
		_cleanup()
		return

	# The cast the ritual builds: both parents HELD, the result absent
	# because it does not exist yet. Built here rather than through
	# FusionRitual.perform() so the roster release below can be driven at
	# the exact moment a confirmation would drive it.
	var cast := SceneCast.new()
	cast.hold(FusionRitual.PARENT_A, parent_a)
	cast.hold(FusionRitual.PARENT_B, parent_b)

	# --- play it --------------------------------------------------------
	# The third argument is the whole point of props: species_a stands in
	# for a computed fusion result, which is a Resource, which is the one
	# thing a method track key cannot carry.
	_drive(scene, cast, {FusionRitual.RESULT: species_a})
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
		cast.unit(FusionRitual.PARENT_A) == parent_a
			and cast.unit(FusionRitual.PARENT_B) == parent_b,
		"the cast lost one of them the moment the roster released it — a " +
		"held role is owned by the SCENE until it says otherwise")
	check("and they are still on screen",
		is_instance_valid(parent_a) and parent_a.is_inside_tree()
			and is_instance_valid(parent_b) and parent_b.is_inside_tree(),
		"a parent left the world before its dissolve beat")

	# --- and no conversation is ever involved ---------------------------
	check("no conversation is running at any point",
		Conversations.current == null,
		"Conversations.current is %s — the cutscene reached for " % str(Conversations.current) +
		"dialogue, which means the spine is still dialogue")

	await _until_returned()
	check("the sequence runs to the end",
		_returned and _result,
		"returned=%s completed=%s" % [str(_returned), str(_result)])

	# --- what it left behind ---------------------------------------------
	check("the parents are gone once their dissolve beat has passed",
		not is_instance_valid(parent_a) and not is_instance_valid(parent_b),
		"a parent is still in the world after the whole sequence — the " +
		"despawn keys at 3.2 either did not fire or are not on the track")

	var born: Unit = cast.unit(FusionRitual.RESULT)
	check("the result was created mid-scene and is in the world",
		born != null and born.is_inside_tree(),
		"nothing is cast as the result. The scene cannot ask an authority " +
		"for a thing that did not exist when it started, so the key that " +
		"makes it must also hold it — and the DEFINITION only reaches that " +
		"key through the props the caller handed the director")

	if born:
		# ON THE GROUND PLAN, not in three dimensions. The result is a
		# CharacterBody3D and the mark is 1 m up, so by the time the scene
		# ends it has fallen most of that metre under its own gravity —
		# which is the body behaving correctly, not the key placing it
		# wrongly. Where it was PUT is the horizontal answer.
		var spot: Node3D = cast.mark(FusionRitual.RESULT_MARK)
		var drift: float = -1.0
		if spot:
			var here := Vector2(born.global_position.x, born.global_position.z)
			var there := Vector2(spot.global_position.x, spot.global_position.z)
			drift = here.distance_to(there)
		check("and it appears on the result mark",
			spot != null and drift < 0.05,
			"the result stands %.2fm from FusionResult on the ground plan" % drift)

		var reveal := CameraFraming.new()
		reveal.subject_role = FusionRitual.RESULT
		reveal.distance = 2.2
		reveal.elevation_degrees = 6.0
		check("and the camera ends on it",
			_camera.camera().global_position.distance_to(reveal.resolve_position(cast)) < 0.3,
			"camera is %.2fm from the reveal framing" %
				_camera.camera().global_position.distance_to(reveal.resolve_position(cast)))

	check("and the mode is handed back",
		GameMode.current_mode() != GameMode.Mode.CUTSCENE,
		"the director still holds the screen after the scene ended")
	if born:
		born.queue_free()

	await _a_skip_lands_on_the_end_state(scene, species_a, species_b)
	_cleanup()


## Skipped before anything has happened, the fusion must still END as it
## ends: parents gone, result standing on its mark. A skip that only
## jumped the playhead would leave both parents in the world with nobody
## holding them and no demon to show for it — the despawn and spawn keys
## never fire on a seek, so settling them is skip_to_end()'s job alone.
##
## THE SKIP IS A REAL INPUT EVENT, so this also covers the director reading
## cinematic_skip in the first place.
func _a_skip_lands_on_the_end_state(scene: PackedScene, species_a: UnitDefinition,
		species_b: UnitDefinition) -> void:
	var parent_a: Unit = _body(species_a)
	var parent_b: Unit = _body(species_b)
	await get_tree().process_frame
	var cast := SceneCast.new()
	cast.hold(FusionRitual.PARENT_A, parent_a)
	cast.hold(FusionRitual.PARENT_B, parent_b)

	_drive(scene, cast, {FusionRitual.RESULT: species_b})
	var spent: int = 0
	var at: float = -1.0
	while not _returned and spent < FRAME_CAP:
		var stage: CinematicStage = CinematicDirector.current_stage()
		var timeline: AnimationPlayer = stage.timeline() if stage else null
		if timeline and timeline.is_playing():
			at = timeline.current_animation_position
			if at >= 0.5:
				break
		await get_tree().process_frame
		spent += 1
	check("SETUP: the skip lands before the first beat has fired",
		not _returned and at >= 0.0 and at < 1.2,
		"playhead at %.2fs when the skip was sent — the parents are " % at +
		"placed at 1.2s, so a later skip is testing a half-played scene")

	var press := InputEventAction.new()
	press.action = &"cinematic_skip"
	press.pressed = true
	Input.parse_input_event(press)
	await _until_returned()
	await get_tree().process_frame

	check("a skipped fusion still counts as finished",
		_returned and _result,
		"returned=%s completed=%s" % [str(_returned), str(_result)])
	check("and the parents are gone, though their despawn keys never played",
		not is_instance_valid(parent_a) and not is_instance_valid(parent_b),
		"a parent is still in the world after skipping — skip_to_end() " +
		"jumped the playhead without settling the despawn beats")

	var born: Unit = cast.unit(FusionRitual.RESULT)
	var spot: Node3D = cast.mark(FusionRitual.RESULT_MARK)
	var drift: float = -1.0
	if born and spot:
		drift = Vector2(born.global_position.x, born.global_position.z).distance_to(
			Vector2(spot.global_position.x, spot.global_position.z))
	check("and the result stands on its mark",
		born != null and born.is_inside_tree() and drift >= 0.0 and drift < 0.05,
		"result=%s, %.2fm from FusionResult on the ground plan" % [str(born), drift])
	if born:
		born.queue_free()


## Marks, a camera, and somewhere for a spawned actor to go. The AI harness
## has no world, and WorldManager.spawn_parent() falls back to the scene
## root — so without registering one, the stage's spawn key has nowhere to
## put the demon it makes and the reveal would silently never happen.
func _stand_up_a_stage() -> bool:
	_saved_root = WorldManager._scene_root
	_saved_camera = CinematicDirector.camera()
	_saved_dialogue = Conversations.current
	Conversations.current = null

	WorldManager.register_scene_root(_root)

	_marks = Node3D.new()
	_root.add_child(_marks)
	var placements: Dictionary = {
		FusionRitual.DEVICE_MARK: Vector3(0.0, 0.0, 0.0),
		FusionRitual.LEFT_MARK: Vector3(-1.2, 1.0, 0.0),
		FusionRitual.RIGHT_MARK: Vector3(1.2, 1.0, 0.0),
		FusionRitual.RESULT_MARK: Vector3(0.0, 1.0, 0.0),
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


## Whether the stage really carries the animation the scene names. Cheap,
## and it turns "the reveal never happened" into a setup failure that says
## why rather than a mysterious missing demon.
func _has_performance(scene: PackedScene) -> bool:
	if scene == null:
		return false
	var built: Node = scene.instantiate()
	var stage := built as CinematicStage
	var found: bool = stage != null and stage.timeline() != null 		and stage.timeline().has_animation(CinematicStage.DEFAULT_ANIMATION)
	built.free()
	return found


func _body(species: UnitDefinition) -> Unit:
	var unit: Unit = species.unit_scene.instantiate()
	unit.definition = species
	_root.add_child(unit)
	return unit


func _drive(scene: PackedScene, cast: SceneCast, props: Dictionary) -> void:
	_returned = false
	_result = await CinematicDirector.play(scene, cast, props)
	_returned = true


func _until_returned() -> void:
	var spent: int = 0
	while not _returned and spent < FRAME_CAP:
		await get_tree().process_frame
		spent += 1


func _cleanup() -> void:
	CinematicDirector.abort()
	if is_instance_valid(_camera):
		_camera.release()
		_camera.queue_free()
	if is_instance_valid(_marks):
		_marks.queue_free()
	CinematicDirector.register_camera(_saved_camera)
	WorldManager.register_scene_root(_saved_root)
	Conversations.current = _saved_dialogue
