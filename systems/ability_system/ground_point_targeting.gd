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

## A fixed range, used unless range_from_strength.
@export var max_range: float = 6.0
## Whether the range is the attacker's jump distance by ST (Jump) instead
## of max_range (Summon Spirit, which places something else).
@export var range_from_strength: bool = false
## See ArcFlight.StrengthRule.
@export var strength_rule: ArcFlight.StrengthRule = ArcFlight.StrengthRule.ROUNDED
## The caster flies to the point (Jump) along an ArcFlight curve this high
## at its peak, and a point whose curve hits a wall can't be aimed at
## (PATH_BLOCKED). MoveCasterEffect flies this same height. 0: nothing
## flies there (Summon Spirit), no path check.
@export var flight_arc_height: float = 0.0
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

## How far the curve may rise over its usual height (arc_height_for), for
## clearing something on its own or by the player's Ctrl.
const ARC_RAISE: float = 2.0
## The lowest curve the player may set.
const ARC_MIN: float = 0.25
## How many heights the automatic rise tries between the usual and the
## limit: a fixed count, since it runs every frame while aiming.
const ARC_TRIES: int = 6


func is_valid_target(attacker: Unit, target) -> bool:
	return check(attacker, target) == Reach.OK


func check(attacker: Unit, target) -> Reach:
	if not target is Vector3:
		return Reach.INVALID
	var destination: Vector3 = target
	if attacker.global_position.distance_to(destination) > range_for(attacker):
		return Reach.OUT_OF_RANGE
	if not _can_stand_at(attacker, destination):
		return Reach.INVALID
	if flight_arc_height > 0.0 and ArcFlight.clear_fraction(attacker, attacker.global_position, destination, chosen_arc(attacker, destination)) < 1.0:
		return Reach.PATH_BLOCKED
	return Reach.OK


func _can_stand_at(attacker: Unit, destination: Vector3) -> bool:
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


## Where attacker comes down aiming at point. A caster that flies there
## (flight_arc_height) only goes as far as its move left this turn, so the
## spot is pulled back along the same direction, the "walk as far as you
## can" rule Unit.move_to() uses; anything else lands where aimed. Every
## check (check_click, the indicator) and the jump itself use this point,
## so a shortened jump is checked where it really lands.
func landing_for(attacker: Unit, point: Vector3) -> Vector3:
	if flight_arc_height <= 0.0 or not attacker.in_combat():
		return point
	var from: Vector3 = attacker.global_position
	var distance: float = from.distance_to(point)
	var reach: float = attacker.move_remaining * jump_multiplier(attacker)
	if distance <= reach or distance <= 0.001:
		return point
	return from + (point - from) / distance * reach


func resolve_click(attacker: Unit, click_position: Vector3) -> Variant:
	return landing_for(attacker, resolve_target_point(click_position))


func check_click(attacker: Unit, click_position: Vector3) -> Reach:
	return check(attacker, landing_for(attacker, resolve_target_point(click_position)))


## How far attacker may target, in metres.
func range_for(attacker: Unit) -> float:
	if not range_from_strength:
		return max_range
	return _strength_range(attacker) * jump_multiplier(attacker)


func _strength_range(attacker: Unit) -> float:
	return ArcFlight.strength_distance(attacker.get_stat_unhalved(StatIds.ST), strength_rule)


## How many times over attacker's Super Jump stretches this. 1 for anything
## not ranged by strength. Range, move spent and arc all use it, because a
## longer range alone would still stop at the Move left this turn.
func jump_multiplier(attacker: Unit) -> float:
	return attacker.jump_distance_multiplier() if range_from_strength else 1.0


## The curve's peak for attacker landing at point: flight_arc_height up to
## an ordinary jump's length, then rising with the distance, so a short
## hop under a low ceiling is still a short hop.
func arc_height_for(attacker: Unit, point: Vector3) -> float:
	var multiplier: float = jump_multiplier(attacker)
	if multiplier <= 1.0:
		return flight_arc_height
	var ordinary: float = maxf(_strength_range(attacker), 0.001)
	return flight_arc_height * clampf(attacker.global_position.distance_to(point) / ordinary, 1.0, multiplier)


## The peak attacker's flight to point really takes: what the player set
## with Ctrl if they did, else the usual curve, else the lowest one up to
## the limit that clears what's in the way. Nothing clears: the usual
## curve, which check() then refuses. A height the player set is kept even
## when blocked, so it shows red instead of quietly changing. Leaving a
## ceiling there is nothing to rise into: the curve is a plain drop.
func chosen_arc(attacker: Unit, point: Vector3) -> float:
	if attacker.held_surface_normal().y < 0.0:
		return 0.0
	if _player_set_arc(attacker):
		return clamp_arc(attacker, point, AbilityManager.arc_height_override)
	var from: Vector3 = attacker.global_position
	var usual: float = arc_height_for(attacker, point)
	if ArcFlight.clear_fraction(attacker, from, point, usual) >= 1.0:
		return usual
	var limit: float = usual * ARC_RAISE
	for i in range(1, ARC_TRIES + 1):
		var height: float = lerpf(usual, limit, float(i) / ARC_TRIES)
		if ArcFlight.clear_fraction(attacker, from, point, height) >= 1.0:
			return height
	return usual


## height, kept within what attacker's flight to point allows.
func clamp_arc(attacker: Unit, point: Vector3, height: float) -> float:
	return clampf(height, ARC_MIN, arc_height_for(attacker, point) * ARC_RAISE)


## Only the player's own armed use of this ability: the same Resource in
## an AI's hands flies its own curve.
func _player_set_arc(attacker: Unit) -> bool:
	var armed: Ability = AbilityManager.armed_ability
	return AbilityManager.has_arc_height_override and armed != null \
			and armed.targeting == self and AbilityManager.armed_unit == attacker


func takes_arc_height() -> bool:
	return flight_arc_height > 0.0


func expects_point_target() -> bool:
	return true


func describe() -> String:
	if range_from_strength:
		return "Ground target, range by ST"
	return "Ground target, range %.1f" % max_range
