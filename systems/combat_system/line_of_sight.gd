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
## explicit eye_height above the feet wins, for a caller that means a
## fixed one.
static func shot_from(attacker: Unit, eye_height: float = NAN) -> Vector3:
	if is_nan(eye_height):
		return attacker.anchor(CharacterModel.Anchor.EYE)
	return attacker.global_position + Vector3(0, eye_height, 0)


## Where a shot at target lands. A Vector3 is exactly where it was aimed.
## A Unit is its first point (UnitBody.sight_points: chest, then head,
## then down a tail) the attacker can see - a man behind a low wall is
## shot in the head, a dragon round a corner in the tail - or its chest
## when none is clear or no attacker is given. The one answer the rule
## traces and every indicator and missile follows, so the line on screen
## is the line tested.
static func shot_to(target, attacker: Unit = null, obstruction_mask: int = 1) -> Vector3:
	if not target is Unit:
		return target
	var body := target as Unit
	if attacker:
		var seen = _first_visible(attacker, shot_from(attacker), body, obstruction_mask)
		if seen != null:
			return seen
	return body.anchor(CharacterModel.Anchor.CHEST)


## Whether any part of target can be seen from the attacker's eye (see
## shot_to for the order they are tried in).
static func has_clear_shot(
	attacker: Unit,
	target: Unit,
	obstruction_mask: int = 1,
	eye_height: float = NAN
) -> bool:
	return _first_visible(attacker, shot_from(attacker, eye_height), target, obstruction_mask) != null


## has_clear_shot from an eye already found - for a caller asking about
## many targets from one attacker (a detection sweep), where reading a
## bone-held EYE anchor per pair is the cost.
static func has_clear_shot_from(attacker: Unit, from: Vector3, target: Unit, obstruction_mask: int = 1) -> bool:
	return _first_visible(attacker, from, target, obstruction_mask) != null


## The first of target's sight points with a clear line from from, or null.
## The chest alone first: in the open it is the answer, and detection asks
## this for every observer and subject each sweep - the rest of the body
## is only built when the chest is hidden.
static func _first_visible(attacker: Unit, from: Vector3, target: Unit, obstruction_mask: int):
	var exclude: Array = [target.get_rid()]
	var chest: Vector3 = target.anchor(CharacterModel.Anchor.CHEST)
	if _clear(attacker, from, chest, obstruction_mask, exclude):
		return chest
	var points: Array[Vector3] = target.body_shape().sight_points()
	for i in range(1, points.size()):
		if _clear(attacker, from, points[i], obstruction_mask, exclude):
			return points[i]
	return null


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
