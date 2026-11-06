class_name KnockbackEffect
extends AbilityEffect
## Shove: sends the TARGET flying directly away from the caster, the way
## Jump flies the jumper (ArcFlight: same curve, same bypass of
## move_and_slide() and path-finding). How far is the caster's ST through
## the jump formula (ArcFlight.strength_distance), a placeholder until
## Shove gets its own ST-vs-weight rule. distance_from_strength off falls
## back to the fixed distance.
##
## Where it lands: for a GROUNDED target the spot is snapped onto a valid
## supported cell (NavigationGrid.nearest_valid_point), so it can't land
## inside a wall, in the void or inside another unit; with nowhere valid
## nearby it stays put. A FLYING target keeps its altitude and isn't
## snapped. A wall on the way (ArcFlight.clear_fraction) stops it short
## against the wall, where it drops; landing far below where it was hurts
## (ArcFlight.take_fall).
##
## Doesn't touch anyone's move_remaining: being shoved isn't the target's
## own movement. Area3D overlaps (Grease and the like) still fire, since
## the physics engine sees the shape move whatever moved it.

@export var distance_from_strength: bool = true
## See ArcFlight.StrengthRule.
@export var strength_rule: ArcFlight.StrengthRule = ArcFlight.StrengthRule.ROUNDED
## Used when distance_from_strength is off.
@export var distance: float = 3.0
@export var push_duration: float = 0.5
@export var arc_height: float = 1.0


func push_distance(attacker: Unit) -> float:
	if not distance_from_strength:
		return distance
	return ArcFlight.strength_distance(attacker.get_stat_unhalved(StatIds.ST), strength_rule)


func apply(attacker: Unit, target, _ability: Ability, _is_critical: bool) -> Dictionary:
	if not target is Unit:
		return {}
	var destination = landing_point(attacker, target)
	if destination == null:
		return {}
	var actual_distance: float = target.global_position.distance_to(destination)
	if actual_distance > 0.001:
		ArcFlight.fly(target, destination, arc_height, push_duration)
	return {"knockback_distance": actual_distance}


## Where target would land shoved by attacker, or null when they stand on
## the same spot (no direction to push). A wall on the way stops it short
## (_stop_short).
func landing_point(attacker: Unit, target: Unit):
	var from: Vector3 = attacker.global_position
	var to: Vector3 = target.global_position
	var offset: Vector3 = to - from
	offset.y = 0.0
	if offset.length() < 0.001:
		return null
	var direction: Vector3 = offset.normalized()
	var landing: Vector3 = _land(target, to + direction * push_distance(attacker))
	var clear: float = ArcFlight.clear_fraction(target, to, landing, arc_height)
	if clear >= 1.0:
		return landing
	return _stop_short(target, direction, (landing - to).length() * clear)


## Where target ends up shoved toward a wall `reach` metres away along
## direction: back off it by its radius and land below there (it may
## drop). Stays put when even that path is blocked.
func _stop_short(target: Unit, direction: Vector3, reach: float) -> Vector3:
	var to: Vector3 = target.global_position
	var short: float = reach - target.radius
	if short <= 0.05:
		return to
	var landing: Vector3 = _land(target, to + direction * short)
	if ArcFlight.clear_fraction(target, to, landing, arc_height) < 1.0:
		return to
	return landing


## A flying target stays at its height; a grounded one comes down on the
## nearest valid cell (NavigationGrid), or stays put with none.
func _land(target: Unit, point: Vector3) -> Vector3:
	var to: Vector3 = target.global_position
	if target.is_flying():
		return Vector3(point.x, to.y, point.z)
	var clearance: float = target.radius + target.avoidance_margin
	var snap: Dictionary = NavigationGrid.nearest_valid_point(target.get_tree(), point, clearance, false, target)
	return snap.point if snap.found else to


func describe() -> String:
	if distance_from_strength:
		return "Knockback by ST"
	return "Knockback %.1fm" % distance
