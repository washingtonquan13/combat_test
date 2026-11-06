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
## snapped. The flight itself doesn't yet check for walls on the way, and
## a landing much lower doesn't hurt: both to come, in ArcFlight.
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
## the same spot (no direction to push).
func landing_point(attacker: Unit, target: Unit):
	var from: Vector3 = attacker.global_position
	var to: Vector3 = target.global_position
	var offset: Vector3 = to - from
	offset.y = 0.0
	if offset.length() < 0.001:
		return null
	var raw_destination: Vector3 = to + offset.normalized() * push_distance(attacker)
	if target.is_flying():
		raw_destination.y = to.y
		return raw_destination
	var clearance: float = target.radius + target.avoidance_margin
	var snap: Dictionary = NavigationGrid.nearest_valid_point(target.get_tree(), raw_destination, clearance, false, target)
	return snap.point if snap.found else to


func describe() -> String:
	if distance_from_strength:
		return "Knockback by ST"
	return "Knockback %.1fm" % distance
