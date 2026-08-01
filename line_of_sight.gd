class_name LineOfSight
extends RefCounted
## BG3-style line of sight: a physics raycast between attacker and target
## at roughly eye height, blocked only by walls/terrain (obstruction_mask)
## — not by other units. Units deliberately don't block shots here,
## matching how BG3 itself behaves: an ally or enemy standing between you
## and your target doesn't prevent you from shooting past them, only the
## environment does. If you want units to be able to block shots later,
## that's a mask change (add units' physics layer to obstruction_mask)
## plus excluding only the attacker/target themselves, not a rewrite.

static func has_clear_shot(
	attacker: Unit,
	target: Unit,
	obstruction_mask: int = 1,
	eye_height: float = 1.5
) -> bool:
	var from: Vector3 = attacker.global_position + Vector3(0, eye_height, 0)
	var to: Vector3 = target.global_position + Vector3(0, eye_height, 0)

	var space_state := attacker.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = obstruction_mask
	query.exclude = [attacker.get_rid(), target.get_rid()]

	var result := space_state.intersect_ray(query)
	return result.is_empty()
