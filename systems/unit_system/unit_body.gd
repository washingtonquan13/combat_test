class_name UnitBody
extends RefCounted
## What a unit's body IS, for every rule that asks whether something
## touches it: reach, area and line hits, cones, clouds and surfaces,
## and line of sight. Before this each of those rebuilt "the body" for
## itself from global_position + radius + height - a sphere here, a disc
## there, a stick from the feet to the eyes somewhere else - and every
## one of them was a human's shape. A dragon's tail was air to all of
## them.
##
## A body is a union of parts:
##
##   - the COLUMN: an upright cylinder of the unit's radius from its feet
##     to its height. The same cylinder the navigation grid keeps clear
##     and the movement collider fits inside, so what a unit is hit as
##     and where it can stand are one shape. Every unit has it.
##   - HIT CAPSULES: CharacterModel.hit_shapes, authored on the model
##     against the mesh, for what sticks out of the column (a tail). Read
##     live from their nodes, so they turn with the body and grow with
##     it. A humanoid has none, which leaves its body exactly the column.
##
## The column alone is a strict superset of what the old checks measured,
## and the capsules only add to it, so nothing a unit could be hit by
## before misses it now.

## Spacing of the points sampled along a capsule's axis (samples()), in
## radii: close enough that a cone's slack covers the gaps between them.
const SAMPLES_PER_RADIUS: float = 1.5
## Fewest points sampled along a capsule, ends included.
const MIN_CAPSULE_SAMPLES: int = 3
## Raised off the floor, the column's lowest sample: a point AT the feet
## sits on the ground every ray towards it grazes.
const FOOT_SAMPLE_LIFT: float = 0.2

var _unit: Unit


func _init(unit: Unit) -> void:
	_unit = unit


## The column's ends: the feet, and the top of the unit's height.
func column_low() -> Vector3:
	return _unit.global_position


func column_high() -> Vector3:
	return _unit.global_position + Vector3.UP * _unit.height


## Every hit capsule as [a: Vector3, b: Vector3, radius: float], the ends
## of its axis in world space. Empty for a body that authored none.
func capsules() -> Array:
	var found: Array = []
	var model := _unit.get_node_or_null("CharacterModel") as CharacterModel
	if model == null:
		return found
	for node in model.hit_shapes:
		if not is_instance_valid(node) or node.shape == null:
			continue
		var xf: Transform3D = node.global_transform
		var size: float = xf.basis.get_scale().x
		var centre: Vector3 = xf.origin
		if node.shape is CapsuleShape3D:
			var capsule := node.shape as CapsuleShape3D
			var half: float = maxf(capsule.height * 0.5 - capsule.radius, 0.0) * size
			var axis: Vector3 = xf.basis.y.normalized() * half
			found.append([centre - axis, centre + axis, capsule.radius * size])
		elif node.shape is SphereShape3D:
			found.append([centre, centre, (node.shape as SphereShape3D).radius * size])
		else:
			push_warning("UnitBody: hit shape %s is a %s; only capsules and spheres are read." % [node.name, node.shape.get_class()])
	return found


## How far point is from the body's surface; 0 inside it.
func distance_to_point(point: Vector3) -> float:
	var best: float = _point_to_column(point)
	for capsule in capsules():
		best = minf(best, _point_to_capsule(point, capsule))
	return best


## How far other's body is from this one's COLUMN - the gap a reach or a
## range is measured across. Only the target's capsules count: a reach
## is taken from where the attacker stands, not from its own tail tip,
## while anything of the target's in reach can be struck.
func gap_to(other: UnitBody) -> float:
	return other.gap_from_column(column_low(), _unit.radius, _unit.height)


## gap_to() asked from a column that isn't where any unit stands yet: one
## of radius and height with its feet at feet, measured to this body. What
## the AI asks of a position it is weighing walking to.
func gap_from_column(feet: Vector3, radius: float, height: float) -> float:
	var low: Vector3 = feet
	var high: Vector3 = feet + Vector3.UP * height
	var best: float = _column_to_column(low, high, radius, column_low(), column_high(), _unit.radius)
	for capsule in capsules():
		var closest: PackedVector3Array = Geometry3D.get_closest_points_between_segments(low, high, capsule[0], capsule[1])
		best = minf(best, maxf(_point_to_column_at(closest[1], feet, radius, height) - capsule[2], 0.0))
	return best


## Points across the body, each with the radius of the part it is the
## middle of (Vector4: xyz, w = radius): what a cone tests against. The
## column gives the three it always gave - just off the floor, the
## chest, the head - and each capsule a row along its axis.
func samples() -> Array[Vector4]:
	var points: Array[Vector4] = []
	var r: float = _unit.radius
	for point: Vector3 in [
		_unit.global_position + Vector3.UP * FOOT_SAMPLE_LIFT,
		_unit.anchor(CharacterModel.Anchor.CHEST),
		_unit.anchor(CharacterModel.Anchor.HEAD),
	]:
		points.append(Vector4(point.x, point.y, point.z, r))
	for capsule in capsules():
		for point in _along(capsule):
			points.append(Vector4(point.x, point.y, point.z, capsule[2]))
	return points


## Where a shot can be aimed at this body, most-wanted first: the chest,
## the head over cover, then down each capsule. LineOfSight takes the
## first one it can see.
func sight_points() -> Array[Vector3]:
	var points: Array[Vector3] = [
		_unit.anchor(CharacterModel.Anchor.CHEST),
		_unit.anchor(CharacterModel.Anchor.HEAD),
	]
	for capsule in capsules():
		points.append_array(_along(capsule))
	return points


## Every part as an upright-or-not segment with a radius ([low, high,
## radius]) - the column feet to top first. What a volume of cubes (a
## cloud) is tested against.
func segments() -> Array:
	var found: Array = [[column_low(), column_high(), _unit.radius]]
	found.append_array(capsules())
	return found


## How far, across the ground (XZ), point is from the body's footprint:
## the column's disc and each capsule's shadow. 0 under the body.
func ground_distance_to(point: Vector2) -> float:
	var feet := Vector2(_unit.global_position.x, _unit.global_position.z)
	var best: float = maxf(point.distance_to(feet) - _unit.radius, 0.0)
	for capsule in capsules():
		var a := Vector2(capsule[0].x, capsule[0].z)
		var b := Vector2(capsule[1].x, capsule[1].z)
		var closest: Vector2 = a if a.is_equal_approx(b) else Geometry2D.get_closest_point_to_segment(point, a, b)
		best = minf(best, maxf(point.distance_to(closest) - capsule[2], 0.0))
	return best


## How far, across the ground, the segment from a to b passes from the
## body's footprint. 0 if it crosses it.
func ground_distance_to_segment(a: Vector2, b: Vector2) -> float:
	var feet := Vector2(_unit.global_position.x, _unit.global_position.z)
	var best: float = maxf(_point_to_segment_2d(feet, a, b) - _unit.radius, 0.0)
	for capsule in capsules():
		var c := Vector2(capsule[0].x, capsule[0].z)
		var d := Vector2(capsule[1].x, capsule[1].z)
		best = minf(best, maxf(_segment_to_segment_2d(a, b, c, d) - capsule[2], 0.0))
	return best


## Whether the footprint reaches into the ground rectangle rect (XZ) -
## a square of a surface grid under the body.
func ground_touches_rect(rect: Rect2) -> bool:
	var feet := Vector2(_unit.global_position.x, _unit.global_position.z)
	if feet.clamp(rect.position, rect.end).distance_to(feet) <= _unit.radius:
		return true
	for capsule in capsules():
		var a := Vector2(capsule[0].x, capsule[0].z)
		var b := Vector2(capsule[1].x, capsule[1].z)
		if _segment_to_rect_2d(a, b, rect) <= capsule[2]:
			return true
	return false


## The XZ box the footprint covers, as [min, max] - for walking a grid.
func ground_bounds() -> Array[Vector2]:
	var r: float = _unit.radius
	var feet := Vector2(_unit.global_position.x, _unit.global_position.z)
	var low: Vector2 = feet - Vector2(r, r)
	var high: Vector2 = feet + Vector2(r, r)
	for capsule in capsules():
		var cr: float = capsule[2]
		for end: Vector3 in [capsule[0], capsule[1]]:
			low = low.min(Vector2(end.x - cr, end.z - cr))
			high = high.max(Vector2(end.x + cr, end.z + cr))
	return [low, high]


func _point_to_column(point: Vector3) -> float:
	return _point_to_column_at(point, _unit.global_position, _unit.radius, _unit.height)


static func _point_to_column_at(point: Vector3, feet: Vector3, radius: float, height: float) -> float:
	var across: float = maxf(Vector2(point.x - feet.x, point.z - feet.z).length() - radius, 0.0)
	var up: float = maxf(maxf(feet.y - point.y, point.y - (feet.y + height)), 0.0)
	return sqrt(across * across + up * up)


static func _point_to_capsule(point: Vector3, capsule: Array) -> float:
	var closest: Vector3 = Geometry3D.get_closest_point_to_segment(point, capsule[0], capsule[1])
	return maxf(point.distance_to(closest) - capsule[2], 0.0)


## Exact gap between two upright cylinders: across and up taken apart.
static func _column_to_column(low_a: Vector3, high_a: Vector3, r_a: float, low_b: Vector3, high_b: Vector3, r_b: float) -> float:
	var across: float = maxf(Vector2(low_a.x - low_b.x, low_a.z - low_b.z).length() - r_a - r_b, 0.0)
	var up: float = maxf(maxf(low_b.y - high_a.y, low_a.y - high_b.y), 0.0)
	return sqrt(across * across + up * up)


static func _along(capsule: Array) -> Array[Vector3]:
	var a: Vector3 = capsule[0]
	var b: Vector3 = capsule[1]
	var spacing: float = maxf(capsule[2] * SAMPLES_PER_RADIUS, 0.01)
	var count: int = maxi(MIN_CAPSULE_SAMPLES, ceili(a.distance_to(b) / spacing) + 1)
	var points: Array[Vector3] = []
	for i in count:
		points.append(a.lerp(b, float(i) / float(count - 1)))
	return points


static func _point_to_segment_2d(p: Vector2, a: Vector2, b: Vector2) -> float:
	var closest: Vector2 = a if a.is_equal_approx(b) else Geometry2D.get_closest_point_to_segment(p, a, b)
	return p.distance_to(closest)


static func _segment_to_rect_2d(a: Vector2, b: Vector2, rect: Rect2) -> float:
	if rect.has_point(a) or rect.has_point(b):
		return 0.0
	var corners: Array[Vector2] = [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]
	var best: float = INF
	for i in 4:
		best = minf(best, _segment_to_segment_2d(a, b, corners[i], corners[(i + 1) % 4]))
	return best


static func _segment_to_segment_2d(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> float:
	if Geometry2D.segment_intersects_segment(a, b, c, d) != null:
		return 0.0
	return minf(minf(_point_to_segment_2d(a, c, d), _point_to_segment_2d(b, c, d)),
			minf(_point_to_segment_2d(c, a, b), _point_to_segment_2d(d, a, b)))
