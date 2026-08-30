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
## makes the retreat harder for a grounded pursuer to catch.
##
## A GROUNDED unit that has flight available takes off as its flee
## action instead of running, spending that turn climbing and retreating
## by air from the next one on. Being airborne is the single most
## effective escape this project has — a grounded pursuer can't reach
## an airborne target at all (see AiScorer.incoming_threat, which scores
## exactly that) — so for a unit already below hp_threshold it dominates
## outrunning anything on foot. The ground retreat is still proposed
## alongside it, so a unit that can't afford the takeoff (or has no
## flight ability at all) falls back to running rather than being left
## with no flee plan; AiScorer._prepare_plan discards the unaffordable
## takeoff on its own via the same ability-economy checks every other
## candidate goes through.
##
## Scored as real survival value rather than a flat constant standing in
## for "should dominate everything else" — see AiScorer.incoming_threat/
## threat_output/KILL_HORIZON_TURNS, which this now shares with the
## kill-value term in AiScorer._score_plan. Each candidate's value is the
## incoming threat it avoids by moving to its own destination, plus a
## death_premium (this unit's own future output, denied if it dies,
## scaled by how likely staying put is to kill it). This is what makes
## air and ground retreats differ HONESTLY instead of by a hand-tuned
## takeoff_preference constant: air genuinely avoids more incoming
## threat than ground does, because a grounded pursuer simply can't
## reach an airborne position at all.

@export_range(0.0, 1.0) var hp_threshold: float = 0.25
@export var flee_distance: float = 10.0
@export var altitude_while_fleeing: float = 8.0
## Small additive bias, same convention as every other behavior's
## score_bonus (0.0 by default) — NOT what makes fleeing dominate an
## attack candidate anymore. That now comes from the computed survival
## value below being genuinely large when incoming threat is real and
## this unit is actually in danger of dying.
@export var score_bonus: float = 0.0


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

	# The one term that is genuinely NOT positional, and so stays here
	# rather than moving to AiScorer.score_position: how much this unit
	# stands to lose by dying is a fact about its own state (current HP
	# versus what's coming at it), identical for every destination it
	# might run to. Position scoring answers "how much safer is over
	# THERE"; this answers "how badly do I need to be anywhere else."
	# Symmetric with the kill-value term in AiScorer._score_plan — dying
	# costs this unit its future output for exactly the reason killing an
	# enemy denies theirs.
	var current_threat: float = AiScorer.sustained_incoming_threat(unit, unit.global_position)
	var probability_of_dying: float = clampf(current_threat / max(float(unit.current_hp), 1.0), 0.0, 1.0)
	var death_premium: float = AiScorer.threat_output(unit) * AiScorer.KILL_HORIZON_TURNS * probability_of_dying

	var plans: Array[AiPlan] = []

	# Grounded with flight available — climbing out of reach beats
	# outrunning anything on foot (see this file's own header). Proposed
	# IN ADDITION to the ground retreat below, never instead of it, so an
	# unaffordable takeoff can't leave this unit with no flee plan at all.
	# Which of the two actually wins is decided by AiScorer's positional
	# scoring, not here: air and ground both escape a melee pursuer THIS
	# turn, and only the sustained view distinguishes them.
	if not unit.is_flying():
		var flight_ability: Ability = FlightAiUtil.find_flight_ability(unit)
		if flight_ability:
			var takeoff := AiPlan.new(flight_ability, unit)
			takeoff.score = score_bonus + death_premium
			takeoff.reason = "flee: takeoff"
			plans.append(takeoff)

	var plan := AiPlan.new(unit.default_ability(), hostiles[0])
	plan.mark_pure_reposition()
	plan.with_destination(destination, flight_altitude)
	plan.score = score_bonus + death_premium
	plan.reason = "flee: retreat"
	plans.append(plan)
	return plans
