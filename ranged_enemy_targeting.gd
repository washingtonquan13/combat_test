class_name RangedEnemyTargeting
extends AbilityTargeting
## Ranged range + line-of-sight check. Same edge-to-edge distance
## convention as MeleeEnemyTargeting, plus an optional raycast (see
## LineOfSight) that melee targeting has no equivalent concept of —
## exactly the kind of field that used to sit unused on every melee
## ability before the component split, and now simply doesn't exist
## anywhere near melee abilities at all.

@export var max_range: float = 8.0
@export var requires_line_of_sight: bool = true
## Physics layer LoS raycasts treat as blocking (walls/terrain — not
## units; see LineOfSight's doc comment for why units don't block shots).
@export var los_obstruction_mask: int = 1


func is_valid_target(attacker: Unit, target) -> bool:
	if not target is Unit:
		return false
	if attacker.edge_distance_to(target) > max_range:
		return false
	if requires_line_of_sight and not LineOfSight.has_clear_shot(attacker, target, los_obstruction_mask):
		return false
	return true


func approach_range() -> float:
	return max_range


func describe() -> String:
	var s := "Ranged, range %.1f" % max_range
	if requires_line_of_sight:
		s += ", requires line of sight"
	return s
