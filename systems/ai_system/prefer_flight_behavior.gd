class_name PreferFlightBehavior
extends AiBehavior
## "This species belongs in the air." A standing, authored preference for
## being airborne, independent of whether flying is tactically justified
## right now — a harpy or a bird demon should take wing because that's
## what it IS, not only when the arithmetic happens to favor it.
##
## Deliberately separate from the scorer's own reasons to fly, which are
## real and already priced: AiScorer.sustained_incoming_threat makes
## altitude categorically safe against grounded melee (see
## AiScorer._can_ever_reach), DISTANT_REACHABLE_CREDIT makes a flyer take
## off preemptively rather than waiting to be cornered, and
## AiScorer._apply_positional_value banks the downward-fire bonus
## AltitudeAdvantageBehavior grants a climbing ranged attacker. A unit
## with a genuine tactical reason to fly does so WITHOUT this behavior.
## This is the flavor knob on top, for when a species should fly even
## when flying buys it nothing — so keep it modest, and reach for it only
## when the arithmetic alone reads as too grounded for the fantasy.
##
## One job: get off the ground. Which altitude to then hold belongs to
## HoldRangeBehavior, and coming back down before the FP runs out belongs
## to LandBeforeExhaustionBehavior — the three compose into an aerial
## archetype (see data/ai_archetypes/) without any of them knowing about
## the others. The behavior these replaced did all three at once, and
## produced a separate bug per job.

## Added to the takeoff candidate's score. Sized against the same HP
## currency everything else in AiScorer uses (see that file's header):
## roughly "worth a couple of points of damage to be airborne," which is
## enough to beat a basic attack for a weak-hitting flyer without ever
## overriding a genuinely urgent action like a finishing blow or a flee.
@export var flight_preference: float = 3.0


func _propose_candidates(unit: Unit) -> Array[AiPlan]:
	if unit.is_flying():
		return []

	var flight_ability: Ability = FlightAiUtil.find_flight_ability(unit)
	if not flight_ability:
		return []

	# A preference for being airborne is not a preference for flight this
	# unit cannot hold. Checked here as a PRECONDITION rather than left to
	# scoring, because that is what this authored bias means: "fly when
	# flying is an option," and it isn't one on an FP bar that empties the
	# turn after takeoff.
	#
	# The distinction matters. AiScorer already prices the takeoff
	# correctly in that state — the fall, and the safety it only rents
	# (see _unsustainable_flight_cost) — and arrives at a small negative.
	# But this behavior's flavor bias sat on top of that verdict and
	# outvoted it, which is precisely the failure AiBehavior's contract
	# warns about: a bias is meant to break ties, never to overrule the
	# arithmetic. Withholding the candidate keeps the knob honest instead
	# of tuning its number down until it happens to lose.
	var upkeep: int = FlightAiUtil.prospective_flight_upkeep(flight_ability)
	if upkeep > 0 and float(unit.current_fp) - flight_ability.fp_cost < float(upkeep):
		return []

	var takeoff: AiPlan = self_plan(unit, flight_ability, flight_preference)
	takeoff.reason = "prefers flight"
	return [takeoff]
