class_name ConeTargeting
extends AbilityTargeting
## A cone breathed or sprayed from the caster: fixed at its origin (the
## caster's mouth, held out along the aim), it can only turn, never move. The target is a Vector3
## that only sets the direction; the cone always reaches its full length.
## A Ctrl height drag pitches it up or down (see resolve_target_point),
## clamped to max_pitch_degrees.
##
## The shape is a round cone with a rounded end: everything within length
## of the origin and within the half-angle of the aim. Walls shadow it,
## checked per target from the origin.
##
## Effects ask units_caught() who it hits, the same scan the preview
## outlines, so the two cannot disagree.

@export var length: float = 9.0
## Width across the far end, at length: sets the half-angle.
@export var end_width: float = 9.0
@export var max_pitch_degrees: float = 60.0
@export var requires_line_of_sight: bool = true
@export var los_obstruction_mask: int = 1


func half_angle() -> float:
	return atan2(end_width * 0.5, length)


## Where the cone comes from for an aim at target: the mouth's height, as
## far out from the body's axis as the mouth is, but on the aim's bearing
## rather than the head's, so it does not swing about as the body turns
## (or the head sways) to face the aim. A long-necked body breathes from
## its snout, not its chest; a body with no mouth declared breathes from
## its chest (CharacterModel.Anchor.MOUTH).
func origin(attacker: Unit, target: Vector3) -> Vector3:
	var axis: Vector3 = _axis(attacker)
	return axis + _bearing(attacker, target - axis) * _reach(attacker)


## The unit direction the cone points for an aim at target, from origin,
## pitch clamped.
func direction(attacker: Unit, target: Vector3) -> Vector3:
	var axis: Vector3 = _axis(attacker)
	var flat: Vector3 = _bearing(attacker, target - axis)
	var to: Vector3 = target - (axis + flat * _reach(attacker))
	var limit: float = deg_to_rad(max_pitch_degrees)
	# An aim inside the snout's reach still breathes forward, steeply.
	var pitch: float = clampf(atan2(to.y, maxf(to.dot(flat), 0.001)), -limit, limit)
	return flat * cos(pitch) + Vector3.UP * sin(pitch)


## The body's own vertical axis at the mouth's height.
func _axis(attacker: Unit) -> Vector3:
	var mouth: Vector3 = attacker.anchor(CharacterModel.Anchor.MOUTH)
	return Vector3(attacker.global_position.x, mouth.y, attacker.global_position.z)


## How far out from the body's axis the mouth is, flat.
func _reach(attacker: Unit) -> float:
	var mouth: Vector3 = attacker.anchor(CharacterModel.Anchor.MOUTH)
	return Vector2(mouth.x - attacker.global_position.x, mouth.z - attacker.global_position.z).length()


## The flat unit bearing of to, or the body's facing when to is straight
## up or down.
func _bearing(attacker: Unit, to: Vector3) -> Vector3:
	var flat := Vector3(to.x, 0.0, to.z)
	if flat.length_squared() < 0.0001:
		flat = Vector3(attacker.visual_forward().x, 0.0, attacker.visual_forward().z)
		if flat.length_squared() < 0.0001:
			flat = Vector3(0.0, 0.0, -1.0)
	return flat.normalized()


func is_valid_target(attacker: Unit, target) -> bool:
	return check(attacker, target) == Reach.OK


## Any point is a direction to breathe in.
func check(_attacker: Unit, target) -> Reach:
	return Reach.OK if target is Vector3 else Reach.INVALID


func expects_point_target() -> bool:
	return true


func takes_aim_height() -> bool:
	return true


## Without a height drag the cone aims level: the point under the cursor
## raised to chest height, so it follows the ground (down a step, up a
## ramp) without nosing into the floor at close range.
func resolve_target_point(click_position: Vector3) -> Vector3:
	if AbilityManager.has_aim_height_override:
		click_position.y = AbilityManager.aim_height_override
	else:
		click_position.y += AIM_LIFT
	return click_position


## Roughly chest height on a human, for the level aim above.
const AIM_LIFT: float = 1.3


## Who a cone aimed at target catches: any of a unit's body points
## (UnitBody.samples: feet, chest, head, and down any tail) inside the
## cone, widened by the radius of the part it lies in, with no wall
## between it and the origin. Never the caster.
func units_caught(attacker: Unit, target, affects_hostiles: bool, affects_allies: bool) -> Array[Unit]:
	var caught: Array[Unit] = []
	if not target is Vector3:
		return caught
	var from: Vector3 = origin(attacker, target)
	var aim: Vector3 = direction(attacker, target)
	var half: float = half_angle()
	for unit in UnitQuery.living_units_near(attacker):
		if unit == attacker:
			continue
		var is_hostile: bool = attacker.is_hostile_to(unit)
		if is_hostile and not affects_hostiles:
			continue
		if not is_hostile and not affects_allies:
			continue
		if _catches(attacker, unit, from, aim, half):
			caught.append(unit)
	return caught


func _catches(attacker: Unit, unit: Unit, from: Vector3, aim: Vector3, half: float) -> bool:
	for sample in unit.body_shape().samples():
		var point := Vector3(sample.x, sample.y, sample.z)
		var to: Vector3 = point - from
		var dist: float = to.length()
		if dist - sample.w > length:
			continue
		if dist > sample.w:
			# The part's radius widens the angle it can be grazed at.
			var slack: float = asin(clampf(sample.w / dist, 0.0, 1.0))
			if aim.angle_to(to) > half + slack:
				continue
		if requires_line_of_sight and not _clear(attacker, unit, from, point):
			continue
		return true
	return false


## Only walls shadow the cone: bodies in the way are breathed past, and a
## cloud that blocks sight does not stop fire.
func _clear(attacker: Unit, unit: Unit, from: Vector3, to: Vector3) -> bool:
	var space := attacker.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = los_obstruction_mask
	var exclude: Array[RID] = [attacker.get_rid(), unit.get_rid()]
	query.exclude = exclude
	while true:
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			return true
		if not hit.collider is Unit:
			return false
		exclude.append(hit.rid)
		query.exclude = exclude
	return true


## Close enough that the cone reaches past the target, not just to it.
func approach_range() -> float:
	return length * 0.7


func indicator_ids() -> Array[StringName]:
	return [&"cone"]


func describe() -> String:
	var s := "Cone, %.0f m long, %.0f m wide at the end" % [length, end_width]
	if requires_line_of_sight:
		s += ", blocked by walls"
	return s
