class_name FleeBehavior
extends AiBehavior
## Below hp_threshold, maximize distance from every living hostile
## (direction away from their CENTROID, not just the nearest one — so
## fleeing "away" can't mean stepping straight toward a second attacker
## to escape the first) rather than committing to any attack — this is
## the self-preservation half of the "Cunning" smartness tier's own
## description (see AiScorer's header), pulled out as its own authored
## behavior rather than baked into the scorer itself, since not every
## unit should be capable of running (a mindless brute plausibly
## shouldn't).
##
## A pure repositioning plan (see AiPlan.pure_reposition) — `ability` on
## the returned plan is never actually used, only a formality AiPlan
## itself requires (see that field's own header); AiScorer skips both
## the ability-economy checks and its own damage/heal scoring for it, so
## an already-spent or unaffordable ability can never wrongly block a
## flee attempt.
##
## Gains altitude while retreating if this unit is already flying — free
## to do (see FlightRules' own "altitude is pure upside" premise) and
## makes the retreat harder for a grounded pursuer to catch. Does NOT
## itself take off to flee (a grounded unit that can't afford or doesn't
## have flight simply runs on the ground) — that's a genuinely separate
## decision (spend a turn's worth of FP JUST to run away) this behavior
## doesn't make on this unit's behalf.

@export_range(0.0, 1.0) var hp_threshold: float = 0.25
@export var flee_distance: float = 10.0
@export var altitude_while_fleeing: float = 8.0
## Deliberately large and positive (unlike every other behavior's default
## 0.0 score_bonus) — once a unit is actually below hp_threshold,
## surviving should dominate every ordinary attack/heal candidate it
## might otherwise be weighing, not merely compete on equal footing with
## them.
@export var score_bonus: float = 100.0


func propose(unit: Unit) -> Array[AiPlan]:
	if unit.maximum_hp <= 0:
		return []
	var fraction: float = float(unit.current_hp) / float(unit.maximum_hp)
	if fraction > hp_threshold:
		return []

	var hostiles: Array[Unit] = []
	for other in UnitQuery.living_units(unit.get_tree()):
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

	var plan := AiPlan.new(unit.default_ability(), hostiles[0])
	plan.mark_pure_reposition()
	plan.with_destination(destination, flight_altitude)
	plan.score = score_bonus
	return [plan]
