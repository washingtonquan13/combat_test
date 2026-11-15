extends AiTestCase
## A body runs while its arms shoot (BodyAnimationTree's UPPER layer): the
## legs move exactly as a body only running, the arms do not. A blow on the
## run recoils on top of it (FLINCH) and the run goes on. In a scene, a
## walk drawn with an upper clip does the same on the stand-in, and the bow
## comes down on arrival.

const StageFixture := preload("res://tests/fixtures/stage_fixture.gd")
const LEGS: Array[String] = ["Hips", "LeftUpperLeg", "RightUpperLeg", "LeftLowerLeg", "RightLowerLeg"]
const ARMS: Array[String] = ["LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm"]
const WALK_SECONDS := 0.8

var _poses: Dictionary = {}


func wants_world() -> bool:
	return true


func run() -> void:
	await _gameplay()
	free_spawned()
	await _scene()


func _gameplay() -> void:
	var runner: Unit = spawn_brute(0.0, 6.0)
	var shooter: Unit = spawn_brute(8.0, 0.0)
	await get_tree().process_frame
	await get_tree().process_frame
	var plain: BodyAnimationTree = runner.animator().playback
	var layered: BodyAnimationTree = shooter.animator().playback
	check("SETUP: a humanoid body has an upper body", layered.has_upper())
	plain.play(&"Jog_Fwd", 0.0)
	layered.play(&"Jog_Fwd", 0.0)
	check("the bow goes up over the run", layered.play_upper(&"Weapon/Bow_Shot", 0.0))
	var a: Skeleton3D = _watch(runner)
	var b: Skeleton3D = _watch(shooter)
	for i in 20:
		await get_tree().process_frame
	check("legs run as a body only running", _most_apart(a, b, LEGS) < 0.01,
		"%.3f rad" % _most_apart(a, b, LEGS))
	check("arms do not", _most_apart(a, b, ARMS) > 0.1, "%.3f rad" % _most_apart(a, b, ARMS))

	var ordered: bool = shooter.move_to(shooter.global_position + Vector3(4.0, 0.0, 0.0))
	for i in 3:
		await get_tree().physics_frame
	var walking: StringName = layered.current_animation
	check("SETUP: on the run", ordered and shooter.is_moving())
	shooter.take_damage(1)
	check("a blow on the run recoils on top of it", layered.is_flinching())
	check("and the run goes on",
		shooter.is_moving() and layered.current_animation == walking,
		"moving %s, showing %s" % [shooter.is_moving(), layered.current_animation])
	shooter.stop_moving()


func _scene() -> void:
	var walker: Unit = spawn_brute(0.0, 0.0)
	await get_tree().process_frame
	var result: Array = []
	_play(_walk_scene(), SceneCast.new().track_unit(&"walker", walker), result)
	await get_tree().create_timer(WALK_SECONDS * 0.4).timeout
	var copy: StandIn = StandIn.of(walker)
	var tree: BodyAnimationTree = BodyAnimationTree.of(copy.body()) if copy else null
	check("in a scene the stand-in walks with the bow up",
		tree != null and tree.current_animation == walker.animator().walk_animation
		and tree.upper_animation == &"Weapon/Bow_Shot",
		"%s / %s" % [tree.current_animation, tree.upper_animation] if tree else "no stand-in")
	var idle: StringName = StringName(walker.animator().idle_animation)
	var guard: int = 0
	while is_instance_valid(tree) and tree.current_animation != idle and guard < 600:
		await get_tree().process_frame
		guard += 1
	check("and lowers it on arrival", tree == null or not is_instance_valid(tree) or tree.upper_animation == &"",
		"%s" % tree.upper_animation if is_instance_valid(tree) else "")
	while result.is_empty():
		await get_tree().process_frame


func _watch(unit: Unit) -> Skeleton3D:
	var skeleton: Skeleton3D = unit.find_children("*", "Skeleton3D", true, false)[0]
	skeleton.skeleton_updated.connect(func() -> void:
		var pose := {}
		for bone in LEGS + ARMS:
			pose[bone] = skeleton.get_bone_pose_rotation(skeleton.find_bone(bone))
		_poses[skeleton] = pose)
	return skeleton


func _most_apart(a: Skeleton3D, b: Skeleton3D, bones: Array[String]) -> float:
	var most: float = 0.0
	for bone in bones:
		most = maxf(most, (_poses[a][bone] as Quaternion).angle_to(_poses[b][bone]))
	return most


func _play(scene: PackedScene, cast: SceneCast, result: Array) -> void:
	result.append(await CinematicDirector.play(scene, cast))


func _walk_scene() -> PackedScene:
	var beat := WalkPathBeat.new()
	beat.name = &"Walk"
	beat.role = &"walker"
	beat.duration = WALK_SECONDS
	beat.follows_ground = false
	beat.upper_animation_name = "Weapon/Bow_Shot"
	var route := Path3D.new()
	route.name = &"Route"
	route.curve = Curve3D.new()
	route.curve.add_point(Vector3.ZERO)
	route.curve.add_point(Vector3(3.0, 0.0, 0.0))
	beat.add_child(route)
	beat.path = NodePath("Route")
	var stage: CinematicStage = StageFixture.make(WALK_SECONDS + 0.5, [[beat, 0.0]]).instantiate()
	stage.performs_on_stand_ins = true
	var packed := PackedScene.new()
	packed.pack(stage)
	stage.free()
	return packed
