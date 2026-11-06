class_name MeleeEnemyTargeting
extends AbilityTargeting
## Melee range check — edge-to-edge distance (Unit.edge_distance_to),
## not center-to-center. This ability's own range, not a shared per-unit
## stat: different melee abilities on the same unit can have different
## reach (a dagger stab and a spear thrust shouldn't have to agree on
## one number) — this is exactly the thing that broke when melee range
## used to defer to a Unit.reach stat, before the component split.

@export var melee_range: float = 1.0


func is_valid_target(attacker: Unit, target) -> bool:
	return check(attacker, target) == Reach.OK


func check(attacker: Unit, target) -> Reach:
	if target is Vector3 and aims_at_ground:
		var reach: float = maxf(attacker.global_position.distance_to(target) - attacker.radius, 0.0)
		return Reach.OK if reach <= melee_range else Reach.OUT_OF_RANGE
	if not target is Unit:
		return Reach.INVALID
	return Reach.OK if attacker.edge_distance_to(target) <= melee_range else Reach.OUT_OF_RANGE


func approach_range() -> float:
	return melee_range


func targets_single_enemy() -> bool:
	return true


func describe() -> String:
	return "Melee, range %.1f" % melee_range
