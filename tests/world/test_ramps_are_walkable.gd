extends AiTestCase
## Grounded units walk up ramps the body can climb, and nowhere else.
##
## Each lane is a 2 m platform reached only by one tilted box. The units'
## CharacterBody3D slides up floors to 45 degrees and no further, and does
## not step up vertical faces, so the grid has to agree on both sides: the
## 15/30/40 degree ramps route, the 55 degree one and the bare 0.5 m step
## do not. One unit really walks the 30 degree ramp, so the route is one
## the body can follow, not only one the grid believes in.

const RISE: float = 2.0
const LANE_WIDTH: float = 3.0
const RAMP_FOOT_Z: float = 4.0
const PLATFORM_DEPTH: float = 4.0


func run() -> void:
	var walker: Unit = spawn_brute(0.0, 0.0)
	var lanes: Dictionary = {}
	var x: float = -12.0
	for degrees in [15.0, 30.0, 40.0, 55.0]:
		lanes[degrees] = _build_ramp_lane(x, degrees)
		x += 6.0
	var step_top: Vector3 = _build_step_lane(x, 0.5)

	for i in 20:
		await get_tree().physics_frame

	for degrees in [15.0, 30.0, 40.0]:
		var top: Vector3 = lanes[degrees]
		var path := _route(walker, top)
		check("a %d degree ramp routes up" % degrees, _arrives(path, top),
			"no route up to %s" % top)
	var steep: Vector3 = lanes[55.0]
	check("a 55 degree ramp does not route (steeper than the body climbs)",
		not _arrives(_route(walker, steep), steep))
	check("a bare 0.5 m step does not route (the body cannot step it)",
		not _arrives(_route(walker, step_top), step_top))

	await _walk_up(walker, lanes[30.0])


func _route(walker: Unit, top: Vector3) -> PackedVector3Array:
	var foot := Vector3(top.x, 0.05, RAMP_FOOT_Z - 3.0)
	return NavigationGrid.find_path(get_tree(), foot, top, walker, false)


func _arrives(path: PackedVector3Array, top: Vector3) -> bool:
	return path.size() >= 2 and path[path.size() - 1].distance_to(top) < 0.6


func _walk_up(walker: Unit, top: Vector3) -> void:
	walker.global_position = Vector3(top.x, 0.05, RAMP_FOOT_Z - 3.0)
	for i in 20:
		await get_tree().physics_frame
	check("SETUP: the walker accepts the order up the ramp", walker.move_to(top))
	for i in 600:
		await get_tree().physics_frame
		if not walker.is_moving():
			break
	check("the walker ends up on the platform",
		walker.global_position.y > RISE - 0.3 and Vector2(walker.global_position.x - top.x, walker.global_position.z - top.z).length() < 1.0,
		"ended at %s" % walker.global_position)


## A tilted box rising RISE over its run along +Z from RAMP_FOOT_Z, onto a
## platform. Returns a point on the platform.
func _build_ramp_lane(x: float, degrees: float) -> Vector3:
	var angle: float = deg_to_rad(degrees)
	var run_length: float = RISE / tan(angle)
	var thickness: float = 0.5
	var slope_length: float = RISE / sin(angle) + 1.0
	var up := Vector3(0.0, cos(angle), -sin(angle))
	var top_centre := Vector3(x, RISE * 0.5, RAMP_FOOT_Z + run_length * 0.5)
	var ramp := _add_box(top_centre - up * thickness * 0.5, Vector3(LANE_WIDTH, thickness, slope_length))
	ramp.rotation.x = -angle
	var platform_z: float = RAMP_FOOT_Z + run_length + PLATFORM_DEPTH * 0.5
	_add_box(Vector3(x, RISE * 0.5, platform_z), Vector3(LANE_WIDTH, RISE, PLATFORM_DEPTH))
	return Vector3(x, RISE + 0.05, platform_z + 0.5)


func _build_step_lane(x: float, height: float) -> Vector3:
	var z: float = RAMP_FOOT_Z + PLATFORM_DEPTH * 0.5
	_add_box(Vector3(x, height * 0.5, z), Vector3(LANE_WIDTH, height, PLATFORM_DEPTH))
	return Vector3(x, height + 0.05, z)


func _add_box(position: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	_root.add_child(body)
	body.global_position = position
	return body
