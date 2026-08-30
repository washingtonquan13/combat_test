class_name LandBeforeExhaustionBehavior
extends AiBehavior
## Come down on purpose while there's still FP to do it with, rather than
## falling out of the sky when the meter empties.
##
## Sustained flight runs on an FP clock (see FpDrainBehavior), and running
## dry is not a soft landing: FpDrainBehavior removes the status with
## voluntary=false, which routes through ForceLandOnExpireBehavior into
## Unit.land(false) and a full fall-damage roll. A voluntary Land, by
## contrast, is explicitly exempt (see LandEffect's own header). So the
## difference between descending one turn early and one turn late is the
## difference between free and a fall from altitude.
##
## This is the only piece of the retired MaintainAltitudeBehavior worth
## carrying forward. Its landing branch was tangled up with two other
## jobs and gated behind conditions that made it almost never fire; the
## FP argument for descending is real, self-contained, and has nothing to
## do with holding an altitude band, which is HoldRangeBehavior's job now.
##
## Deliberately proposes rather than decides — the same rule the rest of
## the suite follows. Landing into a melee brute's reach is worse than
## taking a fall, and AiScorer._apply_positional_value knows that (it
## prices the real landing spot; see AiScorer._plan_end_position, which
## raycasts for it), so a cornered flyer correctly stays up and eats the
## fall instead. An earlier version of this idea DID decide, and landed a
## flyer directly on top of the thing that was trying to kill it.

## Land once FP would cover this many more turns of flight or fewer.
## 1 means "descend on the last turn I could have"; 2 leaves a turn of
## slack for a unit that might want to spend FP on something else.
@export var turns_of_reserve: int = 2
## How far to move when the ground below is too dangerous to land on —
## far enough to leave a melee pursuer's reach, since the whole point is
## that the spot underneath stops being lethal by next turn.
@export var clear_distance: float = 8.0
@export var bias: float = 0.0


func _propose_candidates(unit: Unit) -> Array[AiPlan]:
	if not unit.is_flying():
		return []
	# A unit with no FP economy at all flies for free and never needs to
	# come down for this reason.
	if unit.maximum_fp <= 0:
		return []

	var land_ability: Ability = FlightAiUtil.find_land_ability(unit)
	if not land_ability:
		return []

	var drain: int = FlightAiUtil.flight_upkeep(unit)
	if drain <= 0:
		return []
	if unit.current_fp > drain * turns_of_reserve:
		return []

	var plans: Array[AiPlan] = []

	var descend: AiPlan = self_plan(unit, land_ability, bias)
	descend.reason = "land: %d FP left" % unit.current_fp
	plans.append(descend)

	# AND a way to make landing worth taking. Descending is only the right
	# move if the ground underneath is somewhere worth standing, and when
	# it isn't, offering the descent alone leaves a genuinely bad choice
	# between two deaths: land among the enemies that drove this unit into
	# the air, or stay up and be dropped on them anyway when the FP runs
	# out. AiScorer weighs those honestly and picks whichever loses less,
	# which is the correct answer to the wrong question.
	#
	# The right answer is to get clear first and land next turn, and it
	# was missing entirely — HoldRangeBehavior is satisfied (this unit is
	# at its preferred distance) and FleeBehavior is silent (its HP is
	# fine), so nothing spoke for "move so that coming down stops being
	# suicide." Proposed alongside, never instead: a flyer with safe
	# ground beneath it should just land, and will, because this candidate
	# scores near zero when there's nothing to escape.
	var hostiles: Array[Unit] = []
	for other in UnitQuery.living_units_near(unit):
		if unit.is_hostile_to(other):
			hostiles.append(other)
	if hostiles.is_empty():
		return plans

	var centroid: Vector3 = Vector3.ZERO
	for hostile in hostiles:
		centroid += hostile.global_position
	centroid /= hostiles.size()

	var away: Vector3 = unit.global_position - centroid
	away.y = 0.0
	if away.length() < 0.01:
		away = Vector3.FORWARD
	away = away.normalized()

	# Holds altitude while moving — this is "carry me somewhere I can come
	# down," not a descent, and dropping height mid-retreat would put the
	# unit back in reach of exactly what it's clearing.
	var destination: Vector3 = unit.global_position + away * clear_distance
	destination.y = unit.global_position.y

	var clear_out: AiPlan = reposition_plan(
		unit, hostiles[0], destination, bias, unit.global_position.y)
	clear_out.reason = "clear ground before landing"
	plans.append(clear_out)
	return plans
