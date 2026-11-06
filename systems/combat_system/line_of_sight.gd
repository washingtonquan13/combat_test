class_name LineOfSight
extends RefCounted
## BG3-style line of sight: a physics raycast from the attacker's eye to
## the body or spot aimed at (shot_from / shot_to), blocked only by
## walls/terrain (obstruction_mask) — not by other units. Units
## deliberately don't block shots here, matching how BG3 itself behaves:
## an ally or enemy standing between you and your target doesn't prevent
## you from shooting past them, only the environment does.
##
## Indicators draw shot_from -> shot_to, the segment the rule traces, so a
## line on screen can never disagree with the answer it is coloured by.

## How near the end of the ray a wall may be met and still be the thing
## aimed at rather than cover. A shot at a wall (an arrow loosed into it,
## a Fire Bolt at a wall face) ends ON that wall, so the ray always meets
## it at the very end, and without this every wall the player aimed at
## read as blocking.
const STRUCK_SURFACE_SLACK: float = 0.1

## How far above an aimed point the ray is traced to. An aimed point lies
## ON the floor, and a ray grazing the floor towards it meets every
## centimetre of unevenness on the way; ending it this far up lets a
## bump that small pass while a crate or a pit lip still blocks. Too
## small to see: the indicator line ends at the point itself.
const SURFACE_CLEARANCE: float = 0.1


## Where a shot leaves the attacker: its eye anchor (CharacterModel.Anchor
## .EYE, "where this body sees from, and where its shots originate"). An
## explicit eye_height above the feet wins, for callers that mean a fixed
## one (DetectionManager's EYE_HEIGHT).
static func shot_from(attacker: Unit, eye_height: float = NAN) -> Vector3:
	if is_nan(eye_height):
		return attacker.anchor(CharacterModel.Anchor.EYE)
	return attacker.global_position + Vector3(0, eye_height, 0)


## Where a shot at target lands: a Unit's chest (the body, not its feet
## or a point an eye-height above them), a Vector3 exactly where it was
## aimed. The one answer the rule traces and every indicator draws, so
## the line on screen is the line tested.
static func shot_to(target) -> Vector3:
	if target is Unit:
		return (target as Unit).anchor(CharacterModel.Anchor.CHEST)
	return target


static func has_clear_shot(
	attacker: Unit,
	target: Unit,
	obstruction_mask: int = 1,
	eye_height: float = NAN
) -> bool:
	return _clear(attacker, shot_from(attacker, eye_height), shot_to(target), obstruction_mask, [target.get_rid()])


## Line of sight from the attacker's eye to point itself, not to a point
## an eye-height above it: low cover in front of the spot blocks, and a
## spot under a low overhang that the eye can see is not refused.
static func has_clear_shot_to_point(
	attacker: Unit,
	point: Vector3,
	obstruction_mask: int = 1,
	eye_height: float = NAN,
	extra_exclude: Array = []
) -> bool:
	return _clear(attacker, shot_from(attacker, eye_height), point + Vector3(0, SURFACE_CLEARANCE, 0), obstruction_mask, extra_exclude)


static func _clear(attacker: Unit, from: Vector3, to: Vector3, obstruction_mask: int, extra_exclude: Array) -> bool:
	var space_state := attacker.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = obstruction_mask

	var exclude: Array = [attacker.get_rid()]
	exclude.append_array(extra_exclude)
	query.exclude = exclude

	# Units share layer 1 with the walls, so a body met on the way is
	# stepped past rather than read as cover.
	while true:
		var result := space_state.intersect_ray(query)
		if result.is_empty():
			# Clear of walls; a cloud that blocks sight (Fog) still can.
			return not SurfaceManager.blocks_sight(attacker, from, to)
		if not result.collider is Unit:
			# The surface the shot was aimed at, not something in front of it.
			if result.position.distance_to(to) <= STRUCK_SURFACE_SLACK + SURFACE_CLEARANCE:
				return not SurfaceManager.blocks_sight(attacker, from, to)
			return false
		exclude.append(result.rid)
		query.exclude = exclude
	return true
