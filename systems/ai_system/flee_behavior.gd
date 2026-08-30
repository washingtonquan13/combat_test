class_name FleeBehavior
extends AiBehavior
## Below hp_threshold, offers retreat as an option: move away from every
## living hostile (direction away from their CENTROID, not just the
## nearest one — so fleeing "away" can't mean stepping straight toward a
## second attacker to escape the first), and, if this unit can fly and
## isn't already airborne, take off instead. Being airborne is the single
## most effective escape this project has, since a grounded pursuer can't
## reach an airborne target at all.
##
## OFFERS, not commits. Both retreats go into the same candidate pool as
## every attack this unit could make, and the arithmetic decides — which
## is what makes a wounded unit turn and fight again the moment running
## stops being worth more than shooting, with no "am I done fleeing yet"
## state to track.
##
## Prices nothing itself (see AiBehavior's contract). Everything that
## makes fleeing valuable lives in AiScorer._apply_positional_value: the
## damage a destination avoids, and the future output this unit forfeits
## by dying there. That used to be a "death_premium" computed here, and
## it was wrong in a way only the delta form fixes — as an absolute it was
## added identically to every flee candidate, so fleeing beat attacking
## even when running changed nothing about the danger, and a cornered
## unit ran in circles forever instead of fighting back.
##
## hp_threshold stays a real gate rather than another scoring term: a
## species either has the self-preservation instinct or it doesn't (a
## mindless brute plausibly shouldn't), and that's an authoring decision,
## not something to be out-argued by a good attack opportunity.

@export_range(0.0, 1.0) var hp_threshold: float = 0.25
@export var flee_distance: float = 10.0
@export var altitude_while_fleeing: float = 8.0
## Small authored nudge, same convention as every other behavior — NOT
## what makes fleeing win. See this file's header.
@export var bias: float = 0.0


func _propose_candidates(unit: Unit) -> Array[AiPlan]:
	if unit.maximum_hp <= 0:
		return []
	if float(unit.current_hp) / float(unit.maximum_hp) > hp_threshold:
		return []

	var hostiles: Array[Unit] = []
	for other in UnitQuery.living_units_near(unit):
		if unit.is_hostile_to(other):
			hostiles.append(other)
	if hostiles.is_empty():
		return []

	var centroid: Vector3 = Vector3.ZERO
	for hostile in hostiles:
		centroid += hostile.global_position
	centroid /= hostiles.size()

	var away: Vector3 = unit.global_position - centroid
	if away.length() < 0.01:
		# Standing exactly on the centroid (degenerate, but not
		# impossible with a single hostile occupying the same point) —
		# pick an arbitrary direction rather than normalizing a zero
		# vector.
		away = Vector3.FORWARD
	away = away.normalized()

	var destination: Vector3 = unit.global_position + away * flee_distance
	var flight_altitude: float = NAN
	if unit.is_flying():
		flight_altitude = altitude_while_fleeing
		destination.y = flight_altitude

	var plans: Array[AiPlan] = []

	# Proposed IN ADDITION to the ground retreat, never instead of it, so
	# a unit that can't afford the takeoff (or has no flight ability) is
	# never left with no escape at all. Which one wins is the scorer's
	# call: both escape a melee pursuer this turn, and only the sustained,
	# multi-turn view distinguishes "gone for now" from "gone for good."
	if not unit.is_flying():
		var flight_ability: Ability = FlightAiUtil.find_flight_ability(unit)
		if flight_ability:
			var takeoff: AiPlan = self_plan(unit, flight_ability, bias)
			takeoff.reason = "flee: takeoff"
			plans.append(takeoff)

	var retreat: AiPlan = reposition_plan(unit, hostiles[0], destination, bias, flight_altitude)
	retreat.reason = "flee: retreat"
	plans.append(retreat)
	return plans
