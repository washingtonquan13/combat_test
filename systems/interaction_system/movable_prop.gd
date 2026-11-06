class_name MovableProp
extends InteractableProp
## A prop the player can pick up and set down somewhere else, BG3-style:
## press on it, drag, release where the ghost shows white (see PropDrag).
##
## Who may move it and how far are GURPS rules, read off the mover's
## strength:
## - Weight: up to a one-handed lift, MAX_LIFT_BL x Basic Lift (B353).
## - Distance: the throwing distance for that weight (B355), ST x the
##   table's multiplier for weight / BL. A light crate goes a long way, a
##   heavy one barely leaves the mover's side. Both the prop and the spot
##   it is set down must be within it.
##
## Still a StaticBody3D, so the navigation grid bakes it as an obstacle
## (and its top as somewhere to stand); moving it re-bakes the grid.
##
## A drop doesn't teleport it: it flies there along arc_point(), the same
## curve PropDrag draws while it is held, so the line shows the path it
## will take.
##
## Where it was put down is saved: save_state() records its transform
## (see AreaState), so a box moved and left stays moved.

## One-handed lift (B353): 2 x BL.
const MAX_LIFT_BL: float = 2.0

## Throwing distance (B355): weight / BL up to the first column, distance
## = ST x the second, in yards.
const THROW_TABLE: Array = [
	[0.05, 3.5], [0.10, 2.5], [0.15, 2.0], [0.20, 1.5], [0.25, 1.2],
	[0.30, 1.1], [0.40, 1.0], [0.50, 0.8], [0.75, 0.7], [1.0, 0.6],
	[1.5, 0.4], [2.0, 0.3], [2.5, 0.25], [3.0, 0.2], [4.0, 0.15],
	[5.0, 0.12], [6.0, 0.1], [7.0, 0.09], [8.0, 0.08], [9.0, 0.07],
	[10.0, 0.06], [12.0, 0.05],
]

const METRES_PER_YARD: float = 0.9144

## The flight's peak above the straight line between its ends: a floor,
## plus a share of the distance, capped so a long toss stays readable.
const ARC_MIN_HEIGHT: float = 0.6
const ARC_HEIGHT_PER_METRE: float = 0.25
const ARC_MAX_HEIGHT: float = 3.0

## Flight time: a floor, plus this much per metre, capped.
const FLIGHT_MIN_TIME: float = 0.3
const FLIGHT_TIME_PER_METRE: float = 0.04
const FLIGHT_MAX_TIME: float = 0.8

## A drop's flight (fly_to) has set it down.
signal landed

@export var weight_lb: float = 10.0

## True while it is in the air after a drop; it can't be picked up
## again until it lands.
var in_flight: bool = false

## Where the flight in progress will set it down (global), so a save taken
## mid-air records where it is going rather than a point in the air.
var _landing: Transform3D


## Why mover can't pick this up, or "" when they can.
func refusal_for(mover: Unit) -> String:
	if mover == null:
		return "No one to move it"
	if in_flight:
		return "Still in the air"
	if weight_lb > mover.basic_lift() * MAX_LIFT_BL:
		return "Too heavy to lift"
	if _horizontal_distance(mover.global_position, global_position) > reach_for(mover):
		return "Too far away"
	return ""


## How far from mover this can be moved, in metres.
func reach_for(mover: Unit) -> float:
	return throw_distance(mover.get_stat_unhalved(StatIds.ST), mover.basic_lift(), weight_lb)


static func throw_distance(st: float, basic_lift: float, weight: float) -> float:
	var ratio: float = weight / maxf(basic_lift, 0.01)
	for row in THROW_TABLE:
		if ratio <= row[0]:
			return st * row[1] * METRES_PER_YARD
	return 0.0


## Whether a spot is within mover's reach.
func in_reach(mover: Unit, point: Vector3) -> bool:
	return _horizontal_distance(mover.global_position, point) <= reach_for(mover)


## The transform this prop would have resting on point: its lowest
## collision point on point, turned to basis (its own rotation if none).
## Turns are about the vertical, so the lowest point stays the lowest.
func resting_transform(point: Vector3, basis = null) -> Transform3D:
	var t: Transform3D = global_transform
	if basis is Basis:
		t.basis = basis
	t.origin = point + Vector3(0, -_local_bottom() * t.basis.get_scale().y, 0)
	return t


## Its rotation turned yaw radians about the vertical.
func turned_basis(yaw: float) -> Basis:
	return Basis(Vector3.UP, yaw) * global_basis


## Puts it down at point (turned to basis, if given) and has the
## navigation grid re-bake.
func place_at(point: Vector3, basis = null) -> void:
	global_transform = resting_transform(point, basis)
	NavigationGrid.invalidate()


## Sends it from where it is to rest on point along arc_point(), turning
## to basis on the way if given, then places it there (place_at, so the
## grid re-bakes on landing, not on takeoff). Emits landed when it
## arrives.
func fly_to(point: Vector3, basis = null) -> void:
	var start: Transform3D = global_transform
	_landing = resting_transform(point, basis)
	var from_turn: Quaternion = start.basis.get_rotation_quaternion()
	var to_turn: Quaternion = _landing.basis.get_rotation_quaternion()
	var scale: Vector3 = start.basis.get_scale()
	in_flight = true
	var tween: Tween = create_tween()
	tween.tween_method(func(t: float) -> void:
		global_transform = Transform3D(
			Basis(from_turn.slerp(to_turn, t)).scaled(scale),
			arc_point(start.origin, _landing.origin, t)),
		0.0, 1.0, flight_time(start.origin, _landing.origin))
	tween.tween_callback(func() -> void:
		in_flight = false
		place_at(point, _landing.basis)
		landed.emit())


## Its transform, local as authored, for AreaState. Mid-flight it is where
## it will land.
func save_state() -> Dictionary:
	var t: Transform3D = transform
	if in_flight:
		var parent := get_parent() as Node3D
		t = parent.global_transform.affine_inverse() * _landing if parent else _landing
	return {"transform": t}


## Runs before the world enters the tree (WorldManager reconciles it
## first), so this sets the local transform the scene authored.
func load_state(state: Dictionary) -> void:
	if state.get("transform") is Transform3D:
		transform = state["transform"]


## Where a flight from `from` to `to` is at t (0..1): a parabola over the
## straight line, peaking at t 0.5 (same shape as MoveCasterEffect's).
static func arc_point(from: Vector3, to: Vector3, t: float) -> Vector3:
	var point: Vector3 = from.lerp(to, t)
	point.y += arc_height(from, to) * 4.0 * t * (1.0 - t)
	return point


static func arc_height(from: Vector3, to: Vector3) -> float:
	return minf(ARC_MIN_HEIGHT + ARC_HEIGHT_PER_METRE * _horizontal_distance(from, to), ARC_MAX_HEIGHT)


static func flight_time(from: Vector3, to: Vector3) -> float:
	return minf(FLIGHT_MIN_TIME + FLIGHT_TIME_PER_METRE * from.distance_to(to), FLIGHT_MAX_TIME)


## The collision shapes this prop occupies, each with its transform
## relative to the prop.
func shapes() -> Array[CollisionShape3D]:
	var out: Array[CollisionShape3D] = []
	for child in get_children():
		if child is CollisionShape3D and child.shape != null and not child.disabled:
			out.append(child)
	return out


## Local height of the lowest point of any collision shape.
func _local_bottom() -> float:
	var bottom: float = INF
	for cs in shapes():
		var aabb: AABB = cs.shape.get_debug_mesh().get_aabb()
		var lowest: float = (cs.transform * aabb).position.y
		bottom = minf(bottom, lowest)
	return 0.0 if bottom == INF else bottom


static func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))
