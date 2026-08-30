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
## Also suppresses MaintainAltitudeBehavior's voluntary landing (see
## that file's _should_stay_airborne) — a species authored to prefer
## flight shouldn't spend its turns bobbing down to save FP.
##
## Composes with MaintainAltitudeBehavior rather than replacing it: that
## one owns WHICH altitude band to hold, this one owns whether to be off
## the ground at all. Both proposing a takeoff on the same turn is
## harmless and expected — it's the same ability against the same target,
## so whichever scores higher wins and AiScorer._is_better resolves an
## exact tie deterministically. A species can carry either alone: this
## one without MaintainAltitude for "gets airborne, doesn't care how
## high," MaintainAltitude without this for "flies only when it pays."

## Added to the takeoff candidate's score. Sized against the same HP
## currency everything else in AiScorer uses (see that file's header):
## roughly "worth a couple of points of damage to be airborne," which is
## enough to beat a basic attack for a weak-hitting flyer without ever
## overriding a genuinely urgent action like a finishing blow or a flee.
@export var flight_preference: float = 3.0


func propose(unit: Unit) -> Array[AiPlan]:
	if unit.is_flying():
		return []

	var flight_ability: Ability = FlightAiUtil.find_flight_ability(unit)
	if not flight_ability:
		return []

	var takeoff := AiPlan.new(flight_ability, unit)
	takeoff.score = flight_preference
	takeoff.reason = "prefers flight"
	return [takeoff]
