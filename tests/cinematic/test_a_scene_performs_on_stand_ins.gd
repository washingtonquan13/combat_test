extends AiTestCase
## A cutscene that performs on stand-ins moves nobody until it is over.
##
## While it plays the unit is exactly where the game left it and a copy
## does the walking; when it ends the unit is where the copy ended. A scene
## cut off with nothing to settle leaves the unit where it always was.

const StageFixture := preload("res://tests/fixtures/stage_fixture.gd")
const WALK_SECONDS := 0.4
const PATH_END := Vector3(3.0, 0.0, 0.0)


func wants_world() -> bool:
	return true


func run() -> void:
	var scene: PackedScene = _scene()

	# --- played through ---------------------------------------------------
	var walker: Unit = spawn_brute(0.0, 0.0)
	await get_tree().process_frame
	var began: Vector3 = walker.global_position
	var cast := SceneCast.new().track_unit(&"walker", walker)
	var result: Array = []
	_play(scene, cast, result)
	await get_tree().create_timer(WALK_SECONDS * 0.5).timeout
	var copy: StandIn = StandIn.of(walker)
	check("a copy does the walking",
		copy != null and copy.global_position.distance_to(began) > 0.3,
		"stand-in %s" % [copy.global_position if copy else "missing"])
	check("the unit has not moved while the scene plays",
		walker.global_position.distance_to(began) < 0.1,
		"moved %.3f m" % walker.global_position.distance_to(began))
	while result.is_empty():
		await get_tree().process_frame
	check("the unit is where its copy ended when the scene finishes",
		_flat(walker.global_position).distance_to(_flat(PATH_END)) < 0.6,
		"at %s" % walker.global_position)
	check("the copy is gone and the body is back",
		StandIn.of(walker) == null and StandIn.body_of(walker).visible,
		"stand-in still up")

	# --- cut off with nothing to settle (the world is going) --------------
	var kept: Unit = spawn_brute(0.0, 6.0)
	await get_tree().process_frame
	var kept_at: Vector3 = kept.global_position
	result = []
	_play(scene, SceneCast.new().track_unit(&"walker", kept), result)
	await get_tree().create_timer(WALK_SECONDS * 0.5).timeout
	CinematicDirector._cancel(false)
	while result.is_empty():
		await get_tree().process_frame
	check("a scene cut off unsettled leaves the unit where it was",
		kept.global_position.distance_to(kept_at) < 0.1 and StandIn.of(kept) == null,
		"moved %.3f m" % kept.global_position.distance_to(kept_at))


func _play(scene: PackedScene, cast: SceneCast, result: Array) -> void:
	result.append(await CinematicDirector.play(scene, cast))


func _flat(point: Vector3) -> Vector2:
	return Vector2(point.x, point.z)


func _scene() -> PackedScene:
	var beat := WalkPathBeat.new()
	beat.name = &"Walk"
	beat.role = &"walker"
	beat.duration = WALK_SECONDS
	beat.follows_ground = false
	var route := Path3D.new()
	route.name = &"Route"
	route.curve = Curve3D.new()
	route.curve.add_point(Vector3.ZERO)
	route.curve.add_point(PATH_END)
	beat.add_child(route)
	beat.path = NodePath("Route")
	var stage: CinematicStage = StageFixture.make(WALK_SECONDS + 0.3, [[beat, 0.0]]).instantiate()
	stage.performs_on_stand_ins = true
	var packed := PackedScene.new()
	packed.pack(stage)
	stage.free()
	return packed
