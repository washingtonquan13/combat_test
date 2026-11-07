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
## The performance is over thirty seconds of real time (it follows the
## Nocturne footage beat for beat), so the full play-through runs the
## engine fast. Every check below is about WHAT happened, never when, so
## the speed changes nothing they assert. Restored before the skip half,
## which needs the playhead early, and in _cleanup.
const PLAY_SPEED := 12.0
## The Minister's role on the stage. He belongs to the room, which is
## why the harness stands one in it and the scene must leave him there.
const MINISTER := FusionRitual.MINISTER
## Where the Cathedral's Minister stands relative to its device: on the
## ground floor ten metres down, in front of the platforms, facing out.
const MINISTER_SPOT := Vector3(0.0, -10.0, -6.5)
## How far from its mark a standing body may be. The placeholder settles a
## little above the floor; a body knocked off its mark is metres away.
const STAND_TOLERANCE := 0.5

var _saved_root: Node = null
var _saved_camera: CinematicCamera = null
var _saved_dialogue: Conversation = null
var _camera: CinematicCamera = null
var _marks: Node3D = null
var _minister: Unit = null
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

	var scene: PackedScene = load(FusionRitual.CUTSCENE_PATH) as PackedScene
	check("the fusion cutscene is an authored stage with a performance on its Timeline",
		_has_performance(scene),
		"loaded %s — its root is not a CinematicStage with a '%s' " % [
			str(scene), CinematicStage.DEFAULT_ANIMATION] +
		"animation on a 'Timeline' player, so the reveal can never happen")
	if not _has_performance(scene):
		_cleanup()
		return

	# The cast the ritual builds: the room's Minister and nobody else. The
	# parents and the result are all made by the timeline's spawn keys,
	# from the species handed in as props.
	var cast := FusionRitual.cast_for(_root)

	# --- play it --------------------------------------------------------
	# The third argument is the whole point of props: species_a stands in
	# for a computed fusion result, which is a Resource, which is the one
	# thing a method track key cannot carry.
	Engine.time_scale = PLAY_SPEED
	_drive(scene, cast, FusionRitual.props_for(species_a, species_a, species_b))
	await get_tree().process_frame

	check("it holds the screen",
		GameMode.current_mode() == GameMode.Mode.CUTSCENE,
		"mode is %s" % GameMode.Mode.keys()[GameMode.current_mode()])

	# --- the opening: the Minister, and no parents yet -------------------
	await _until_playhead(1.0)
	var minister: Unit = cast.unit(MINISTER)
	check("the opening shot starts on the Minister",
		minister != null and minister.is_inside_tree()
			and _in_frame(minister.anchor(CharacterModel.Anchor.CHEST)),
		"minister=%s — the tilt up to the device has nobody at its foot" % str(minister))
	check("from in front of him, not from behind the platforms",
		minister != null and _camera.camera() != null
			and (_camera.camera().global_position - minister.global_position)
				.dot(minister.visual_forward()) > 0.0,
		"the camera is behind the Minister. In the Cathedral that is inside " +
		"the platforms he stands in front of; being in frustum does not " +
		"mean being seen")
	check("and the parents do not exist before the scene places them",
		cast.unit(FusionRitual.PARENT_A) == null and cast.unit(FusionRitual.PARENT_B) == null,
		"a parent is already cast in the opening. A body that exists " +
		"before its spawn key is somewhere the scene did not put it")

	# --- the fusion is confirmed: the roster lets the parents go ---------
	# What a real confirmation does, before the parents reach the screen.
	# The scene must not care: it never asked the roster for them.
	var owned_a: OwnedDemon = DemonRoster.recruit(species_a)
	var owned_b: OwnedDemon = DemonRoster.recruit(species_b)
	DemonRoster.release(owned_a)
	DemonRoster.release(owned_b)

	# --- the cut to the pads: both parents standing there, in frame ------
	await _until_playhead(9.0)
	var parent_a: Unit = cast.unit(FusionRitual.PARENT_A)
	var parent_b: Unit = cast.unit(FusionRitual.PARENT_B)
	var saw_parents: bool = parent_a != null and parent_b != null
	check("the parents are on their pads when the camera cuts to them",
		_stands_on(parent_a, FusionRitual.LEFT_MARK) and _stands_on(parent_b, FusionRitual.RIGHT_MARK),
		"%s / %s. A parent that is not on its mark has been pushed off it " % [
			_where(parent_a, FusionRitual.LEFT_MARK), _where(parent_b, FusionRitual.RIGHT_MARK)] +
		"(a body spawned overlapping something keeps the speed it was " +
		"shoved out with) or was never put there")
	check("and the pads shot has them both in frame",
		parent_a != null and parent_b != null
			and _in_frame(parent_a.anchor(CharacterModel.Anchor.CHEST))
			and _in_frame(parent_b.anchor(CharacterModel.Anchor.CHEST)),
		"the shot at 9s does not frame both parents")
	check("and the Minister is still standing in the room after the cut",
		is_instance_valid(minister) and minister.is_inside_tree()
			and minister.global_position.distance_to(MINISTER_SPOT) < STAND_TOLERANCE,
		"the scene removed or moved the Minister. He is the room's: the " +
		"menu shows him before the fusion and after it")

	# --- the dissolve: they stay on screen, unveiled, until the cut ------
	# The reference holds on the two of them going black and shedding
	# blobs. A body removed when the blobs start is a demon that blinks
	# out, and a light column left standing hides the whole dissolve.
	await _until_playhead(10.5)
	var columns: Node3D = CinematicDirector.current_stage().get_node_or_null(^"Effects/Columns")
	check("the light columns are gone once the burst is over",
		columns != null and not columns.is_visible_in_tree(),
		"the columns are still up at 10.5s and veil the parents for the dissolve")
	await _until_playhead(15.0)
	check("and the parents are still standing while the blobs leave them",
		is_instance_valid(parent_a) and parent_a.is_inside_tree()
			and is_instance_valid(parent_b) and parent_b.is_inside_tree(),
		"a parent left the world before the cut away from the dissolve")

	# The white silhouette after the strike is shown head-on, as in the
	# reference, on the same axis the reveal then pushes in along.
	await _until_playhead(26.5)
	var newborn: Unit = cast.unit(FusionRitual.RESULT)
	var strike_lens: Camera3D = _camera.camera()
	var toward_camera := Vector3.ZERO
	if newborn != null and strike_lens != null:
		toward_camera = (strike_lens.global_position - newborn.global_position) * Vector3(1, 0, 1)
	check("the white silhouette is framed from in front, not side-on",
		newborn != null and strike_lens != null
			and _in_frame(newborn.anchor(CharacterModel.Anchor.CHEST))
			and toward_camera.normalized().dot(newborn.visual_forward() * Vector3(1, 0, 1)) > 0.85,
		"the strike shot sees the result at %.0f degrees off its facing" %
			(rad_to_deg(toward_camera.angle_to(newborn.visual_forward())) if newborn else NAN))

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
		saw_parents
			and not is_instance_valid(parent_a) and not is_instance_valid(parent_b),
		"a parent is still in the world after the whole sequence — the " +
		"despawn keys either did not fire or are not on the track")

	var born: Unit = cast.unit(FusionRitual.RESULT)
	check("the result was created mid-scene and is in the world",
		born != null and born.is_inside_tree(),
		"nothing is cast as the result. The scene cannot ask an authority " +
		"for a thing that did not exist when it started, so the key that " +
		"makes it must also hold it — and the DEFINITION only reaches that " +
		"key through the props the caller handed the director")

	if born:
		# ON THE GROUND PLAN: where it was PUT is the horizontal answer.
		# Whether it stays standing there is the parents' check above.
		var spot: Node3D = cast.mark(FusionRitual.RESULT_MARK)
		var drift: float = -1.0
		if spot:
			var here := Vector2(born.global_position.x, born.global_position.z)
			var there := Vector2(spot.global_position.x, spot.global_position.z)
			drift = here.distance_to(there)
		check("and it appears on the result mark",
			spot != null and drift < 0.05,
			"the result stands %.2fm from FusionResult on the ground plan" % drift)

		# Whatever the last shot is tuned to, it must be LOOKING AT the
		# result and close enough to read it: the head inside the view cone
		# and within a few metres. Deliberately not a copy of the authored
		# framing, so retuning the reveal in the editor does not break this.
		var lens: Camera3D = _camera.camera()
		var head: Vector3 = born.anchor(CharacterModel.Anchor.HEAD)
		var to_head: Vector3 = head - lens.global_position
		var off_axis: float = rad_to_deg((-lens.global_transform.basis.z).angle_to(to_head))
		check("and the camera ends on it",
			off_axis < lens.fov * 0.5 and to_head.length() < 6.0,
			"the result's head is %.1f deg off the lens axis (half fov %.1f) at %.2fm" % [
				off_axis, lens.fov * 0.5, to_head.length()])

		check("and it is not left painted",
			_unpainted(born),
			"a mesh on the result still has a material_overlay — the white " +
			"silhouette was put on and never cleared")

	var greeting: String = str(FusionRitual.props_for(species_a)[FusionRitual.GREETING])
	check("the greeting names the demon and its race",
		greeting.begins_with("I am %s of the %s clan." % [species_a.display_name, species_a.order]),
		"greeting was '%s'" % greeting)

	check("and the mode is handed back",
		GameMode.current_mode() != GameMode.Mode.CUTSCENE,
		"the director still holds the screen after the scene ended")
	if born:
		born.queue_free()

	Engine.time_scale = 1.0
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
	var cast := FusionRitual.cast_for(_root)

	_drive(scene, cast, FusionRitual.props_for(species_b, species_a, species_b))
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
		"playhead at %.2fs when the skip was sent — the first beat is " % at +
		"keyed later than 1.2s, so a later skip is testing a half-played scene")

	var press := InputEventAction.new()
	press.action = &"cinematic_skip"
	press.pressed = true
	Input.parse_input_event(press)
	await _until_returned()
	await get_tree().process_frame

	check("a skipped fusion still counts as finished",
		_returned and _result,
		"returned=%s completed=%s" % [str(_returned), str(_result)])
	var standing: Array[Unit] = _units_in_world()
	standing.erase(_minister)
	check("and only the result is left standing beside the Minister, though no despawn key played",
		standing.size() == 1 and standing[0] == cast.unit(FusionRitual.RESULT)
			and is_instance_valid(_minister),
		"%d units in the world after skipping: %s. skip_to_end() " % [standing.size(), str(standing)] +
		"jumped the playhead without settling the spawn and despawn beats")

	var born: Unit = cast.unit(FusionRitual.RESULT)
	var spot: Node3D = cast.mark(FusionRitual.RESULT_MARK)
	var drift: float = -1.0
	if born and spot:
		drift = Vector2(born.global_position.x, born.global_position.z).distance_to(
			Vector2(spot.global_position.x, spot.global_position.z))
	check("and the result stands on its mark",
		born != null and born.is_inside_tree() and drift >= 0.0 and drift < 0.05,
		"result=%s, %.2fm from FusionResult on the ground plan" % [str(born), drift])
	check("and a skipped result is not left painted either",
		born != null and _unpainted(born),
		"a mesh on the skipped result still has a material_overlay")
	if born:
		born.queue_free()


## Marks, a camera, and somewhere for a spawned actor to go. The marks
## are where the Cathedral's are, relative to its device, and on the
## harness's floor, so the stage's own shots frame them as they would
## there and a body standing on one stays on it. The AI harness
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
		FusionRitual.LEFT_MARK: Vector3(-2.0, 0.0, -2.0),
		FusionRitual.RIGHT_MARK: Vector3(2.0, 0.0, -2.0),
		FusionRitual.RESULT_MARK: Vector3(0.0, 0.0, 2.0),
	}
	for mark_name in placements:
		var mark := Marker3D.new()
		mark.name = mark_name
		_marks.add_child(mark)
		mark.global_position = placements[mark_name]
		mark.add_to_group(SceneCast.MARK_GROUP)

	# The Cathedral's ground floor, ten metres under the device, where the
	# Minister stands. The harness floor is the platform tops.
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(20.0, 1.0, 20.0)
	shape.shape = box
	ground.add_child(shape)
	_root.add_child(ground)
	ground.global_position = Vector3(0.0, -10.5, 0.0)

	# The room's Minister, as the Cathedral authors him: in the group the
	# ritual casts from, turned to face out (-z) past the unit's model offset.
	var definition: UnitDefinition = load("res://data/units/npcs/minister.tres")
	_minister = definition.unit_scene.instantiate()
	_minister.definition = definition
	_minister.add_to_group(FusionRitual.MINISTER_GROUP)
	_root.add_child(_minister)
	_minister.global_transform = Transform3D(Basis(Vector3.UP, PI), MINISTER_SPOT)

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


## No SilhouetteBeat paint left on any mesh of the unit's model.
func _unpainted(unit: Unit) -> bool:
	var model: Node = unit.get_node_or_null("CharacterModel")
	if model == null:
		return false
	for mesh in model.find_children("*", "MeshInstance3D", true, false):
		if (mesh as MeshInstance3D).material_overlay != null:
			return false
	return true


## Whether `unit` is standing on `mark_name`, in three dimensions. A body
## pushed off a mark flies up, not sideways, so the height is the point.
func _stands_on(unit: Unit, mark_name: StringName) -> bool:
	var spot: Node3D = _marks.get_node_or_null(NodePath(String(mark_name)))
	return unit != null and spot != null \
		and unit.global_position.distance_to(spot.global_position) < STAND_TOLERANCE


func _where(unit: Unit, mark_name: StringName) -> String:
	var spot: Node3D = _marks.get_node_or_null(NodePath(String(mark_name)))
	if unit == null or spot == null:
		return "%s: nobody" % mark_name
	return "%s: %.2fm off, at y %.2f" % [
		mark_name, unit.global_position.distance_to(spot.global_position), unit.global_position.y]


func _in_frame(point: Vector3) -> bool:
	var lens: Camera3D = _camera.camera()
	return lens != null and lens.is_position_in_frustum(point)


## Every Unit under the harness root, freed ones excluded.
func _units_in_world() -> Array[Unit]:
	var found: Array[Unit] = []
	for node in _root.find_children("*", "", true, false):
		if node is Unit and not node.is_queued_for_deletion():
			found.append(node)
	return found


## Waits until the timeline has passed `seconds`, or the scene has ended.
func _until_playhead(seconds: float) -> void:
	var spent: int = 0
	while not _returned and spent < FRAME_CAP:
		var stage: CinematicStage = CinematicDirector.current_stage()
		var timeline: AnimationPlayer = stage.timeline() if stage else null
		if timeline and timeline.current_animation_position >= seconds:
			return
		await get_tree().process_frame
		spent += 1


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
	Engine.time_scale = 1.0
	CinematicDirector.abort()
	if is_instance_valid(_camera):
		_camera.release()
		_camera.queue_free()
	if is_instance_valid(_marks):
		_marks.queue_free()
	if is_instance_valid(_minister):
		_minister.queue_free()
	CinematicDirector.register_camera(_saved_camera)
	WorldManager.register_scene_root(_saved_root)
	Conversations.current = _saved_dialogue
