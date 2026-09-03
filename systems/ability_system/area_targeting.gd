class_name AreaTargeting
extends AbilityTargeting
## Targets a ground point for an area-of-effect ability — target here is
## a Vector3, not a Unit. Checks max_range (straight-line from caster)
## and, optionally, line of sight to the target POINT itself — same
## LineOfSight raycast RangedEnemyTargeting uses for a single unit, aimed
## at a location instead (see LineOfSight.has_clear_shot_to_point).
##
## Deliberately doesn't require the point to be on walkable navmesh the
## way GroundPointTargeting (Jump) does — an AoE center is just where the
## blast goes off, not somewhere the caster needs to stand.
##
## radius is the blast's area of effect — the SINGLE source of truth for
## it, read by every area-based AbilityEffect on the same ability (see
## AreaDamageEffect, AreaApplyStatusEffect) via ability.targeting.radius,
## rather than each effect carrying its own separate radius field. That
## used to be two independently-set numbers that had to be manually kept
## equal to guarantee "the status applies to exactly who the damage
## hits" — now there's structurally only one number to set at all.

@export var max_range: float = 10.0
@export var radius: float = 3.0
@export var requires_line_of_sight: bool = true
@export var los_obstruction_mask: int = 1
@export var eye_height: float = 1.5


func is_valid_target(attacker: Unit, target) -> bool:
	if not target is Vector3:
		return false

	var destination: Vector3 = target

	if attacker.global_position.distance_to(destination) > max_range:
		return false

	if requires_line_of_sight and not LineOfSight.has_clear_shot_to_point(attacker, destination, los_obstruction_mask, eye_height):
		return false

	return true


func expects_point_target() -> bool:
	return true


func indicator_ids() -> Array[StringName]:
	return [&"area"]


func describe() -> String:
	var s := "Area target, range %.1f, radius %.1f" % [max_range, radius]
	if requires_line_of_sight:
		s += ", requires line of sight"
	return s
