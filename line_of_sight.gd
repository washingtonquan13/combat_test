class_name LineOfSight
extends RefCounted
## BG3-style line of sight: a physics raycast at roughly eye height,
## blocked only by walls/terrain (obstruction_mask) — not by other
## units. Units deliberately don't block shots here, matching how BG3
## itself behaves: an ally or enemy standing between you and your target
## doesn't prevent you from shooting past them, only the environment
## does. If you want units to be able to block shots later, that's a
## mask change (add units' physics layer to obstruction_mask) plus
## excluding only the relevant units themselves, not a rewrite.
##
## has_clear_shot_to_point is the actual core check; has_clear_shot (unit
## to unit) is a thin wrapper around it. Split this way so a point-
## targeting ability (e.g. an AoE — see AreaTargeting) can check LoS to
## wherever it's aiming without duplicating the raycast setup.

static func has_clear_shot(
	attacker: Unit,
	target: Unit,
	obstruction_mask: int = 1,
	eye_height: float = NAN
) -> bool:
	return has_clear_shot_to_point(attacker, target.global_position, obstruction_mask, eye_height, [target.get_rid()])


static func has_clear_shot_to_point(
	attacker: Unit,
	point: Vector3,
	obstruction_mask: int = 1,
	eye_height: float = NAN,
	extra_exclude: Array = []
) -> bool:
	# NAN means "ask the body where its eyes are" — see
	# CharacterModel.Anchor. An explicit height still wins, because some
	# callers genuinely mean a fixed one (DetectionManager's EYE_HEIGHT, an
	# ability's own AreaTargeting.eye_height) rather than "wherever this
	# creature happens to look from".
	#
	# The lift is applied to BOTH ends, which is what it has always done:
	# the destination of a shot is a point on the ground raised to roughly
	# where a body would be, not a second creature's eye.
	var lift: float = eye_height
	if is_nan(lift):
		lift = attacker.anchor(CharacterModel.Anchor.EYE).y - attacker.global_position.y

	var from: Vector3 = attacker.global_position + Vector3(0, lift, 0)
	var to: Vector3 = point + Vector3(0, lift, 0)

	var space_state := attacker.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = obstruction_mask

	var exclude: Array = [attacker.get_rid()]
	exclude.append_array(extra_exclude)
	query.exclude = exclude

	var result := space_state.intersect_ray(query)
	return result.is_empty()
