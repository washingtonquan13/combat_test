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

@export var weight_lb: float = 10.0


## Why mover can't pick this up, or "" when they can.
func refusal_for(mover: Unit) -> String:
	if mover == null:
		return "No one to move it"
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


## The transform this prop would have resting on point: same rotation,
## its lowest collision point on point.
func resting_transform(point: Vector3) -> Transform3D:
	var t: Transform3D = global_transform
	t.origin = point + Vector3(0, -_local_bottom() * global_basis.get_scale().y, 0)
	return t


## Puts it down at point and has the navigation grid re-bake.
func place_at(point: Vector3) -> void:
	global_transform = resting_transform(point)
	NavigationGrid.invalidate()


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
