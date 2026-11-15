extends AiTestCase
## A CameraPathRig puts the one cinematic camera on its drawn line, as far
## along it as `progress` says, aimed at the role or mark it names or at a
## second line. With no line it gives no answer, so the camera holds.

const START := Vector3(0.0, 4.0, 10.0)
const END := Vector3(8.0, 2.0, 10.0)
const AIM_START := Vector3(0.0, 1.0, 0.0)
const AIM_END := Vector3(8.0, 1.0, 0.0)
const MARK := &"RideTestMark"
const MARK_AT := Vector3(3.0, 1.5, -2.0)

var _saved_camera: CinematicCamera = null
var _camera: CinematicCamera = null


func run() -> void:
	_saved_camera = CinematicDirector.camera()
	var spot := Node3D.new()
	spot.name = MARK
	spot.add_to_group(SceneCast.MARK_GROUP)
	_root.add_child(spot)
	spot.global_position = MARK_AT
	_camera = CinematicCamera.new()
	_root.add_child(_camera)

	var rig := CameraPathRig.new()
	rig.look_mark = MARK
	rig.add_child(_line(&"Line", START, END))
	rig.add_child(_line(&"Aim", AIM_START, AIM_END))
	rig.path = NodePath("Line")
	rig.progress = 0.25
	_root.add_child(rig)
	await get_tree().process_frame

	var cast := SceneCast.new()
	cast.tree = get_tree()
	rig.begin(cast)
	rig.tick()
	var lens: Camera3D = _camera.camera()
	var expected: Vector3 = START.lerp(END, 0.25)
	check("the camera is a quarter of the way along the line",
		lens.global_position.distance_to(expected) < 0.01,
		"at %s, expected %s" % [lens.global_position, expected])
	check("and looks at the mark the rig names",
		(-lens.global_basis.z).angle_to(MARK_AT - expected) < 0.01,
		"looking %s" % -lens.global_basis.z)

	rig.aim_path = NodePath("Aim")
	rig.progress = 1.0
	rig.tick()
	check("an aim line is ridden at the same progress",
		lens.global_position.distance_to(END) < 0.01 \
				and (-lens.global_basis.z).angle_to(AIM_END - END) < 0.01,
		"at %s looking %s" % [lens.global_position, -lens.global_basis.z])

	var held: Vector3 = lens.global_position
	rig.path = NodePath("Nowhere")
	rig.progress = 0.0
	rig.tick()
	check("with no line to ride the camera holds where it was",
		lens.global_position.distance_to(held) < 0.01,
		"moved to %s" % lens.global_position)

	rig.end()
	rig.queue_free()
	_camera.release()
	_camera.queue_free()
	CinematicDirector.register_camera(_saved_camera)


func _line(line_name: StringName, from: Vector3, to: Vector3) -> Path3D:
	var line := Path3D.new()
	line.name = line_name
	line.curve = Curve3D.new()
	line.curve.add_point(from)
	line.curve.add_point(to)
	return line
