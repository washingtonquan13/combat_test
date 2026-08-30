class_name HoldRangeBehavior
extends AiBehavior
## Wants to fight from a particular DISTANCE. An artillery unit hangs
## back and shoots; a skirmisher closes to melee; a high flyer holds an
## altitude band. All three are the same preference at different
## preferred_range values, so one behavior covers them.
##
## Distance is 3D, which is the point. This replaces MaintainAltitude-
## Behavior (altitude only) and SwoopAttackBehavior (dive to melee, which
## is just a small preferred_range with the descent implied), and it adds
## the case neither could express: backing AWAY horizontally from a melee
## attacker that has closed on a ranged unit. Nothing in this project
## kited horizontally before.
##
## Proposes a reposition only when the unit is meaningfully outside its
## preferred band. Inside it, the baseline attack enumeration already has
## the unit shooting from where it stands and there is nothing to add —
## deliberately NOT a candidate that says "stand still," which would just
## be a second copy of a plan AiScorer already generates.
##
## Prices nothing (see AiBehavior's contract). Whether holding range is
## actually worth a turn is AiScorer._apply_positional_value's call: it
## knows what threat the destination avoids, what the altitude does to
## this unit's to-hit, and what dying there would cost. A previous
## version of this idea hand-computed those deltas in three places and
## the copies disagreed with each other.

## How far from its target this unit wants to be, edge to edge. Small
## values make a diving melee harasser, large ones a standoff shooter.
@export var preferred_range: float = 8.0
## Height above the target to hold while repositioning, if this unit can
## fly. NAN leaves altitude alone — the correct setting for a purely
## ground-based brute or skirmisher.
@export var preferred_altitude: float = NAN
## Dead band, edge to edge. Below this much error the unit just fights
## from where it is rather than shuffling every turn to shave off
## centimetres — without it a unit oscillates around its ideal spot and
## never spends a turn attacking.
@export var range_tolerance: float = 2.0
@export var bias: float = 0.0


func _propose_candidates(unit: Unit) -> Array[AiPlan]:
	var target: Unit = UnitQuery.nearest_hostile(unit.get_tree(), unit)
	if not target:
		return []

	var ability: Ability = unit.default_ability()
	if not ability:
		return []

	var current: float = unit.edge_distance_to(target)
	if absf(current - preferred_range) <= range_tolerance:
		return []

	# Straight line between the two, so backing off and closing in are the
	# same computation with a different sign — a unit that has been
	# cornered retreats along the axis it was approached on, which reads
	# as giving ground rather than wandering.
	var to_unit: Vector3 = unit.global_position - target.global_position
	to_unit.y = 0.0
	if to_unit.length() < 0.01:
		to_unit = Vector3.FORWARD
	to_unit = to_unit.normalized()

	var standoff: float = preferred_range + unit.radius + target.radius
	var destination: Vector3 = target.global_position + to_unit * standoff

	var altitude: float = NAN
	if not is_nan(preferred_altitude) and unit.is_flying():
		altitude = clampf(
			target.global_position.y + preferred_altitude,
			NavigationGrid.FLIGHT_MIN_ALTITUDE,
			NavigationGrid.FLIGHT_CEILING_HEIGHT
		)
		destination.y = altitude

	# REQUIRED, via positioned_attack_plan: arriving IS the intent here,
	# so this must survive the "already in range, don't bother moving"
	# rule AiScorer._resolve_reach applies to ordinary attack plans. That
	# rule exists for candidates whose destination is merely a means of
	# getting in range; for this behavior the whole proposition is that
	# the CURRENT distance is wrong even though the unit can shoot from
	# it. Scoring still decides whether the move is worth the turn.
	var plan: AiPlan = positioned_attack_plan(unit, target, ability, destination, bias, altitude)
	if current > preferred_range:
		plan.reason = "close to %.1fm" % preferred_range
	else:
		plan.reason = "withdraw to %.1fm" % preferred_range
	return [plan]
