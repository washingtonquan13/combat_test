class_name CrawlPose
extends RefCounted
## Lays a crawler's model against the surface it is on.
##
## Only the model tilts. The Unit stays upright, because everything that
## asks about a unit (facing, reach, the nav column, the collider) reads an
## upright yaw-only body; the tilt never reaches any of them.
##
## The grid knows surfaces only to the nearest cell, which is right for
## routing and wrong to look at: a wall off the cell boundary would leave the
## body floating, and a slanted one would stair-step its tilt. So the grid
## says which way the surface lies and a ray says exactly where it is. The
## rings ask the same question (surface_at), so they can't disagree with the
## body.

## How fast the body turns onto a new surface: most of the way in a quarter
## of a second, so an inside corner reads as a turn and not a snap.
const TURN_RATE: float = 9.0
## A normal this close to straight up is a floor, and on a floor the model
## is left exactly as a walker's would be.
const FLAT: float = 0.995
## How far past the grid's surface the ray looks: more than a cell's error.
const RAY_REACH: float = 0.5
## A ray normal further than this from the grid's is another face: the grid
## blends the two faces of a corner, and the blend is what turns the body.
const SAME_FACE_DOT: float = 0.8
const SURFACE_COLLISION_MASK: int = 1

var _unit: Unit
var _model: Node3D = null
var _rest: Transform3D
var _active: bool = false
## The body's orientation in the world: y the surface it is on, z its heading.
var _frame: Quaternion
var _forward_seen: Vector3 = Vector3.ZERO
## How much further the real surface is than the grid's, smoothed.
var _gap: float = 0.0


func _init(unit: Unit) -> void:
	_unit = unit


## The surface a crawler standing at origin is on, {} with none: point is
## where its feet meet it, normal which way it faces, gap how much further
## that is than the grid's own surface.
static func surface_at(unit: Unit, origin: Vector3) -> Dictionary:
	if not unit.can_crawl():
		return {}
	return true_surface(unit, origin, NavigationGrid.crawl_normal(unit.get_tree(), origin, unit))


## surface_at for a caller already holding the grid's normal.
static func true_surface(unit: Unit, origin: Vector3, grid_normal: Vector3) -> Dictionary:
	if grid_normal == Vector3.ZERO:
		return {}
	var radius: float = unit.height * 0.5
	var centre: Vector3 = origin + Vector3.UP * radius
	var surface := {"point": centre - grid_normal * radius, "normal": grid_normal, "gap": 0.0}
	if grid_normal.y > FLAT:
		return surface
	var hit: Dictionary = _ray(unit, centre, centre - grid_normal * (radius + RAY_REACH))
	if hit.is_empty() or (hit.normal as Vector3).dot(grid_normal) < SAME_FACE_DOT:
		return surface
	var normal: Vector3 = hit.normal
	surface.point = hit.position
	surface.normal = normal
	surface.gap = (centre - (hit.position as Vector3)).dot(normal) - radius
	return surface


## A basis lying on a surface, y out of it: what a decal needs to paint it.
static func lying_on(normal: Vector3) -> Basis:
	return Basis(_frame_of(Vector3.FORWARD, normal))


## The first thing that isn't a unit between from and to.
static func _ray(unit: Unit, from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to, SURFACE_COLLISION_MASK)
	var exclude: Array[RID] = [unit.get_rid()]
	var space: PhysicsDirectSpaceState3D = unit.get_world_3d().direct_space_state
	for i in 8:
		query.exclude = exclude
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty() or not (hit.collider is Unit):
			return hit
		exclude.append(hit.rid)
	return {}


## normal: the surface, ZERO with none. gap: true_surface's. travel: the way
## it is moving, ZERO when still.
func update(delta: float, normal: Vector3, gap: float, travel: Vector3) -> void:
	var model := _unit.get_node_or_null("CharacterModel") as Node3D
	if model != _model:
		_model = model
		_active = false
	if _model == null:
		return
	var forward: Vector3 = _unit.visual_forward()
	var upright: Quaternion = _frame_of(forward, Vector3.UP)
	var on_floor: bool = normal == Vector3.ZERO or normal.y > FLAT
	if not _active:
		_forward_seen = forward
		if on_floor:
			return
		_rest = _model.transform
		_frame = upright
		_gap = 0.0
		_active = true

	var target: Quaternion = upright if on_floor else _frame_of(_heading(forward, travel), normal)
	var ease_in: float = 1.0 - exp(-TURN_RATE * delta)
	_frame = _frame.slerp(target, ease_in).normalized()
	_gap = lerpf(_gap, 0.0 if on_floor else gap, ease_in)
	_forward_seen = forward
	if on_floor and _frame.angle_to(upright) < deg_to_rad(1.0):
		_model.transform = _rest
		_active = false
		return
	_place(upright)


## Sets the body again for the yaw the Unit has now. update ran before the
## step turned the Unit, and a tilted body carried round by that turn comes
## off the wall for the frame.
func refit() -> void:
	if _active and _model != null:
		_place(_frame_of(_unit.visual_forward(), Vector3.UP))


## Where it is going; else where it was just turned to (an attack facing its
## target); else on as it was, so a spider that stopped halfway up a wall
## doesn't swing round to the yaw it happens to have.
func _heading(forward: Vector3, travel: Vector3) -> Vector3:
	if travel != Vector3.ZERO:
		return travel
	if forward.dot(_forward_seen) < 0.9999:
		return forward
	return _frame * Vector3.BACK


func _place(upright: Quaternion) -> void:
	var unit_basis: Basis = _unit.global_basis.orthonormalized()
	var to_unit: Basis = unit_basis.inverse()
	var turn: Basis = to_unit * Basis(_frame * upright.inverse()) * unit_basis
	_model.basis = turn * _rest.basis
	# The body's centre is a radius straight above the Unit's origin, and the
	# feet are a radius from that centre towards the surface.
	var feet: Vector3 = (Vector3.UP - _frame * Vector3.UP) * _unit.height * 0.5 - _frame * Vector3.UP * _gap
	_model.position = to_unit * feet + turn * _rest.origin


## y along normal, z as near heading as lies in the surface. A heading
## straight into the surface says nothing: then up the wall.
static func _frame_of(heading: Vector3, normal: Vector3) -> Quaternion:
	for wanted: Vector3 in [heading, Vector3.UP, Vector3.RIGHT]:
		var along: Vector3 = wanted - normal * wanted.dot(normal)
		if along.length_squared() > 0.0001:
			var z: Vector3 = along.normalized()
			return Basis(normal.cross(z), normal, z).get_rotation_quaternion()
	return Quaternion.IDENTITY
