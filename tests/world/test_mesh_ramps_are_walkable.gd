extends AiTestCase
## The grid reads mesh collision shapes by their real surface, not their AABB.
##
## Same lanes as test_ramps_are_walkable, but each ramp is a solid wedge
## built as a ConcavePolygonShape3D (one as a ConvexPolygonShape3D): the
## 15/30/40 degree wedges route, the 55 degree one does not. A concave
## "table" (slab on two side walls) must leave the floor under it open, and
## one unit really walks the concave 30 degree ramp.

const RISE: float = 2.0
const LANE_WIDTH: float = 3.0
const RAMP_FOOT_Z: float = 4.0
const PLATFORM_DEPTH: float = 4.0

## The table: open along Z, 3 m deep. The underside sits above the 2 m unit
## height (the grid checks every layer the body spans), so the gap is a
## real doorway for the body, not only for its feet.
const TABLE_X: float = 0.0
const TABLE_Z_MIN: float = -9.5
const TABLE_Z_MAX: float = -6.5
const TABLE_HALF_OPENING: float = 1.45
const TABLE_WALL: float = 0.2
const TABLE_UNDERSIDE: float = 2.5
const TABLE_SLAB: float = 0.3


const BRIDGE_X: float = -8.0


func run() -> void:
	var walker: Unit = spawn_brute(0.0, 0.0)
	var lanes: Dictionary = {}
	var x: float = -12.0
	for degrees: float in [15.0, 30.0, 40.0, 55.0]:
		lanes[degrees] = _build_ramp_lane(x, degrees, false)
		x += 6.0
	var convex_top: Vector3 = _build_ramp_lane(x, 30.0, true)
	_build_table()
	_build_bridge()

	for i in 20:
		await get_tree().physics_frame

	for degrees: float in [15.0, 30.0, 40.0]:
		var top: Vector3 = lanes[degrees]
		var path: PackedVector3Array = _route(walker, top)
		check("a %d degree concave wedge routes up" % degrees, _arrives(path, top),
			"no route up to %s" % top)
	var steep: Vector3 = lanes[55.0]
	check("a 55 degree concave wedge does not route (steeper than the body climbs)",
		not _arrives(_route(walker, steep), steep))
	check("a 30 degree convex wedge routes up", _arrives(_route(walker, convex_top), convex_top),
		"no route up to %s" % convex_top)

	var from := Vector3(TABLE_X, 0.05, TABLE_Z_MIN - 2.5)
	var to := Vector3(TABLE_X, 0.05, TABLE_Z_MAX + 2.5)
	var under: PackedVector3Array = NavigationGrid.find_path(get_tree(), from, to, walker, false)
	var straight: float = from.distance_to(to)
	var walked: float = _length(from, under)
	check("the floor under a concave table routes straight through (not AABB-filled)",
		_arrives(under, to) and walked < straight + 0.5,
		"path %s, length %.2f vs straight %.2f" % [under, walked, straight])

	var b_from := Vector3(BRIDGE_X, 0.05, -12.5)
	var b_to := Vector3(BRIDGE_X, 0.05, -3.5)
	var b_path: PackedVector3Array = NavigationGrid.find_path(get_tree(), b_from, b_to, walker, false)
	var b_walked: float = _length(b_from, b_path)
	check("under an open deck over open ground (one mesh) routes straight through",
		_arrives(b_path, b_to) and b_walked < b_from.distance_to(b_to) + 0.5,
		"path %s, length %.2f" % [b_path, b_walked])

	await _walk_up(walker, lanes[30.0])


func _route(walker: Unit, top: Vector3) -> PackedVector3Array:
	var foot := Vector3(top.x, 0.05, RAMP_FOOT_Z - 3.0)
	return NavigationGrid.find_path(get_tree(), foot, top, walker, false)


func _arrives(path: PackedVector3Array, top: Vector3) -> bool:
	return path.size() >= 2 and path[path.size() - 1].distance_to(top) < 0.6


func _length(from: Vector3, path: PackedVector3Array) -> float:
	var total: float = 0.0
	var last: Vector3 = from
	for point: Vector3 in path:
		total += last.distance_to(point)
		last = point
	return total


func _walk_up(walker: Unit, top: Vector3) -> void:
	walker.global_position = Vector3(top.x, 0.05, RAMP_FOOT_Z - 3.0)
	for i in 20:
		await get_tree().physics_frame
	check("SETUP: the walker accepts the order up the concave ramp", walker.move_to(top))
	for i in 600:
		await get_tree().physics_frame
		if not walker.is_moving():
			break
	check("the walker ends up on the platform past the concave ramp",
		walker.global_position.y > RISE - 0.3 and Vector2(walker.global_position.x - top.x, walker.global_position.z - top.z).length() < 1.0,
		"ended at %s" % walker.global_position)


## A solid wedge rising RISE along +Z from RAMP_FOOT_Z, onto a box platform.
## Concave (triangle soup) unless `convex`. Returns a point on the platform.
func _build_ramp_lane(x: float, degrees: float, convex: bool) -> Vector3:
	var run_length: float = RISE / tan(deg_to_rad(degrees))
	var xl: float = x - LANE_WIDTH * 0.5
	var xr: float = x + LANE_WIDTH * 0.5
	var z0: float = RAMP_FOOT_Z
	var z1: float = RAMP_FOOT_Z + run_length
	# Foot edge (A), bottom back edge (B), top back edge (C), left and right.
	var al := Vector3(xl, 0.0, z0)
	var ar := Vector3(xr, 0.0, z0)
	var bl := Vector3(xl, 0.0, z1)
	var br := Vector3(xr, 0.0, z1)
	var cl := Vector3(xl, RISE, z1)
	var cr := Vector3(xr, RISE, z1)
	if convex:
		var hull := ConvexPolygonShape3D.new()
		hull.points = PackedVector3Array([al, ar, bl, br, cl, cr])
		_add_shape(hull)
	else:
		var faces := PackedVector3Array()
		_tri(faces, al, bl, cl, Vector3.LEFT)
		_tri(faces, ar, br, cr, Vector3.RIGHT)
		_quad(faces, al, ar, br, bl, Vector3.DOWN)
		_quad(faces, bl, br, cr, cl, Vector3.BACK)
		_quad(faces, al, ar, cr, cl, Vector3(0.0, 1.0, -1.0))
		var soup := ConcavePolygonShape3D.new()
		soup.set_faces(faces)
		_add_shape(soup)
	var platform_z: float = z1 + PLATFORM_DEPTH * 0.5
	_add_box(Vector3(x, RISE * 0.5, platform_z), Vector3(LANE_WIDTH, RISE, PLATFORM_DEPTH))
	return Vector3(x, RISE + 0.05, platform_z + 0.5)


## A flat slab on two thin side walls, all one ConcavePolygonShape3D, open
## along Z so the floor runs straight under it.
func _build_table() -> void:
	var outer: float = TABLE_HALF_OPENING + TABLE_WALL
	var faces := PackedVector3Array()
	_box_faces(faces, Vector3(TABLE_X - outer, 0.0, TABLE_Z_MIN),
		Vector3(TABLE_X - TABLE_HALF_OPENING, TABLE_UNDERSIDE, TABLE_Z_MAX))
	_box_faces(faces, Vector3(TABLE_X + TABLE_HALF_OPENING, 0.0, TABLE_Z_MIN),
		Vector3(TABLE_X + outer, TABLE_UNDERSIDE, TABLE_Z_MAX))
	_box_faces(faces, Vector3(TABLE_X - outer, TABLE_UNDERSIDE, TABLE_Z_MIN),
		Vector3(TABLE_X + outer, TABLE_UNDERSIDE + TABLE_SLAB, TABLE_Z_MAX))
	var soup := ConcavePolygonShape3D.new()
	soup.set_faces(faces)
	_add_shape(soup)


## One ConcavePolygonShape3D of two single-sided up-facing quads: open
## ground, and a deck 2.5 m over its middle. The deck must not fill down
## to the ground under it.
func _build_bridge() -> void:
	var faces := PackedVector3Array()
	_quad(faces, Vector3(BRIDGE_X - 3.0, 0.0, -13.0), Vector3(BRIDGE_X + 3.0, 0.0, -13.0),
		Vector3(BRIDGE_X + 3.0, 0.0, -3.0), Vector3(BRIDGE_X - 3.0, 0.0, -3.0), Vector3.UP)
	_quad(faces, Vector3(BRIDGE_X - 2.0, 2.5, -9.0), Vector3(BRIDGE_X + 2.0, 2.5, -9.0),
		Vector3(BRIDGE_X + 2.0, 2.5, -7.0), Vector3(BRIDGE_X - 2.0, 2.5, -7.0), Vector3.UP)
	var soup := ConcavePolygonShape3D.new()
	soup.set_faces(faces)
	_add_shape(soup)


## Appends a triangle wound so Godot's face normal points along `outward`
## (clockwise seen from outside).
func _tri(faces: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, outward: Vector3) -> void:
	if (c - a).cross(b - a).dot(outward) >= 0.0:
		faces.append_array(PackedVector3Array([a, b, c]))
	else:
		faces.append_array(PackedVector3Array([a, c, b]))


## A planar quad a-b-c-d (in order around its edge) as two triangles.
func _quad(faces: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, d: Vector3, outward: Vector3) -> void:
	_tri(faces, a, b, c, outward)
	_tri(faces, a, c, d, outward)


func _box_faces(faces: PackedVector3Array, lo: Vector3, hi: Vector3) -> void:
	var p000 := Vector3(lo.x, lo.y, lo.z)
	var p100 := Vector3(hi.x, lo.y, lo.z)
	var p010 := Vector3(lo.x, hi.y, lo.z)
	var p110 := Vector3(hi.x, hi.y, lo.z)
	var p001 := Vector3(lo.x, lo.y, hi.z)
	var p101 := Vector3(hi.x, lo.y, hi.z)
	var p011 := Vector3(lo.x, hi.y, hi.z)
	var p111 := Vector3(hi.x, hi.y, hi.z)
	_quad(faces, p000, p100, p101, p001, Vector3.DOWN)
	_quad(faces, p010, p110, p111, p011, Vector3.UP)
	_quad(faces, p000, p010, p011, p001, Vector3.LEFT)
	_quad(faces, p100, p110, p111, p101, Vector3.RIGHT)
	_quad(faces, p000, p100, p110, p010, Vector3.FORWARD)
	_quad(faces, p001, p101, p111, p011, Vector3.BACK)


## Shape vertices are world coordinates, so the body stays at the origin.
func _add_shape(shape: Shape3D) -> StaticBody3D:
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	_root.add_child(body)
	body.global_position = Vector3.ZERO
	return body


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
