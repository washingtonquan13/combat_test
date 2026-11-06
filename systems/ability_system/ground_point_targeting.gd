class_name GroundPointTargeting
extends AbilityTargeting
## Targets a ground point instead of a unit — for abilities like a
## BG3-style Jump, not an attack. target here is a Vector3, not a Unit.
##
## Deliberately does NOT check that a connected walkable path exists
## between attacker and the point — a jump is explicitly supposed to be
## able to cross a gap a normal walk couldn't path through (that's the
## entire point of it being a jump and not just another way to walk).
## What it DOES check: the range (straight-line; see range_for), that the landing spot
## is actually on walkable ground (not floating over a void or inside a
## wall), and that nothing else is already standing there.
##
## Known limitation: CombatAI's targeting is built entirely around
## finding and approaching a hostile UNIT (UnitQuery.nearest_hostile
## returns a Unit, never a point) — an AI unit whose default_ability()
## uses this targeting type would never find a valid target and
## effectively never use it. Making the AI capable of choosing to jump
## somewhere is real follow-up work, not something this pass solved; as
## long as AI units don't have a ground-targeted ability as abilities[0],
## this doesn't cause a problem, just an ability the AI never picks.

## How far the jump's distance is set by the jumper's ST (range_for).
enum StrengthRule {
	## 5e's running long jump, ST in feet at 5e's 5 ft = 1.5 m (so 1 ft
	## = 0.3 m), plus BG3's 1.5 m: 0.3 x ST + 1.5. 4.5 m at ST 10.
	ROUNDED,
	## BG3's own numbers converted exactly: 4.5 m at ST 10, +1 m per 2
	## ST: 0.5 x ST - 0.5. Same at ST 10, steeper either side.
	EXACT,
}

## A fixed range, used unless range_from_strength.
@export var max_range: float = 6.0
## Whether the range is the attacker's jump distance by ST (Jump) instead
## of max_range (Summon Spirit, which places something else).
@export var range_from_strength: bool = false
@export var strength_rule: StrengthRule = StrengthRule.ROUNDED
## How close (meters) the landing point needs to be to an actual valid
## grid cell (see NavigationGrid) to count as "on walkable ground" —
## matches the tolerance pattern used elsewhere for point validation
## (see PathAvoidance).
@export var navmesh_tolerance: float = 0.5
## Whether the landing point's altitude validity follows the ATTACKER's
## own flying state (true — correct for Jump: a flying attacker jumps to
## an airborne point, a grounded one to a ground point, since the
## attacker itself ends up there) or is always validated as ground
## regardless of the attacker's altitude (false — needed for anything
## that places something ELSE at the point, like Summon Spirit: a
## summoned creature is independently grounded, so validating against
## the flying CASTER's altitude was rejecting every ground click while
## airborne — the caster's own state has nothing to do with where the
## summon lands). Defaults true to match this targeting type's original,
## Jump-only behavior; abilities that place something else should set
## this false in their .tres.
@export var validate_as_caster_flying: bool = true


func is_valid_target(attacker: Unit, target) -> bool:
	if not target is Vector3:
		return false

	var destination: Vector3 = target

	if attacker.global_position.distance_to(destination) > range_for(attacker):
		return false

	var flying: bool = attacker.is_flying() if validate_as_caster_flying else false
	var clearance: float = attacker.radius + attacker.avoidance_margin
	var max_radius_cells: int = ceili(navmesh_tolerance / NavigationGrid.CELL_SIZE)
	var snap: Dictionary = NavigationGrid.nearest_valid_point(attacker.get_tree(), destination, clearance, flying, attacker, max_radius_cells)
	if not snap.found or snap.point.distance_to(destination) > navmesh_tolerance:
		return false

	# Deliberately a SECOND, independent check rather than trusting the
	# nearest_valid_point() snap above alone: that one reads
	# NavigationGrid's occupancy grid, which is current to the CELL (it
	# rebuilds whenever a unit changes cell) but not to a unit's exact
	# position inside it. A hard "never let this land literally inside
	# another unit" guarantee needs exact positions, so this re-scans
	# every live unit's ACTUAL current position fresh, right now,
	# instead. Uses attacker's bare radius (no avoidance_margin) against
	# each obstacle's own bare radius — the true no-overlap boundary,
	# stricter than the softer avoidance_margin-padded clearance the
	# snap above already applied.
	var obstacles: Dictionary = PathAvoidance.gather_obstacles(attacker.get_tree(), [attacker])
	for i in obstacles.positions.size():
		var required: float = obstacles.radii[i] + attacker.radius
		if destination.distance_to(obstacles.positions[i]) < required:
			return false

	return true


## How far attacker may target, in metres.
func range_for(attacker: Unit) -> float:
	if not range_from_strength:
		return max_range
	return strength_distance(attacker.get_stat_unhalved(StatIds.ST), strength_rule)


static func strength_distance(st: float, rule: StrengthRule) -> float:
	match rule:
		StrengthRule.EXACT:
			return maxf(0.5 * st - 0.5, 0.0)
		_:
			return 0.3 * st + 1.5


func expects_point_target() -> bool:
	return true


func describe() -> String:
	if range_from_strength:
		return "Ground target, range by ST"
	return "Ground target, range %.1f" % max_range
