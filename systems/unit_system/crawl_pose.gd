class_name CrawlPose
extends RefCounted
## Lays a crawler's model against the surface it is on.
##
## Only the model tilts. The Unit stays upright, because everything that
## asks about a unit (facing, reach, the nav column, the collider) reads an
## upright yaw-only body; the tilt never reaches any of them.

## How fast the body turns onto a new surface: most of the way in a quarter
## of a second, so an inside corner reads as a turn and not a snap.
const TURN_RATE: float = 9.0
## A normal this close to straight up is a floor, and on a floor the model
## is left exactly as a walker's would be.
const FLAT: float = 0.995

var _unit: Unit
var _model: Node3D = null
var _rest: Transform3D
var _active: bool = false
## The body's orientation in the world: y the surface it is on, z its heading.
var _frame: Quaternion
var _forward_seen: Vector3 = Vector3.ZERO


func _init(unit: Unit) -> void:
	_unit = unit


## normal: the surface, ZERO with none. travel: the way it is moving, ZERO
## when still.
func update(delta: float, normal: Vector3, travel: Vector3) -> void:
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
		_active = true

	var target: Quaternion = upright if on_floor else _frame_of(_heading(forward, travel), normal)
	_frame = _frame.slerp(target, 1.0 - exp(-TURN_RATE * delta)).normalized()
	_forward_seen = forward
	if on_floor and _frame.angle_to(upright) < deg_to_rad(1.0):
		_model.transform = _rest
		_active = false
		return
	_place(upright)


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
	var feet: Vector3 = (Vector3.UP - _frame * Vector3.UP) * _unit.height * 0.5
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
