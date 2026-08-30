class_name MaintainAltitudeBehavior
extends AiBehavior
## "Stay high" and "hover just above the fray" are the same behavior at
## two different preferred_altitude values — a high-altitude ranged
## skirmisher and a low-hovering melee harasser both just want to hold
## one altitude band rather than sitting on the ground, so one authored
## Resource covers both archetypes (see this species' abilities'
## Category on the roster-authoring pass this shipped with).
##
## Grounded: proposes taking off, same as the old hardcoded
## "target is flying, I'm not, take off" hack this project's AI used to
## have (see combat_ai.gd's own header) — except now that's one candidate
## among many instead of an unconditional reflex, so a unit that can't
## afford it, or for which some other action scores better, correctly
## doesn't bother.
##
## Airborne: proposes landing (when nothing else wants this unit kept
## aloft — see _should_stay_airborne) and this unit's normal attack.
## The attack carries a destination ONLY when the unit can't already
## reach its target from where it floats; if it can shoot from here, it
## shoots and merely nudges its held altitude. See the long comment on
## that branch for the three-way compounding failure that rule fixes.
##
## Every score set here is just the authored bias. What being at
## preferred_altitude is actually WORTH — the threat it avoids, the
## downward-fire bonus it earns — is priced once, for every candidate, by
## AiScorer._apply_positional_value. This file used to compute those
## deltas itself in three places; see AiScorer's own header for why that
## duplication had to go.

@export var preferred_altitude: float = 8.0
## Added on top of whatever the takeoff candidate would otherwise score
## (0.0 — taking off has no inherent damage/heal value of its own, see
## AiScorer._score_plan, which only scores damage/heal candidates) — set
## above 0.0 so a grounded unit with this behavior actually prefers
## taking off over standing still when nothing else stands out, rather
## than the takeoff always tying at 0.0 with a candidate that does
## nothing useful either.
@export var takeoff_score_bonus: float = 1.0
@export var reposition_score_bonus: float = 0.0


func propose(unit: Unit) -> Array[AiPlan]:
	if not unit.is_flying():
		var flight_ability: Ability = FlightAiUtil.find_flight_ability(unit)
		if not flight_ability:
			return []
		var takeoff := AiPlan.new(flight_ability, unit)
		takeoff.score = takeoff_score_bonus
		takeoff.reason = "takeoff"
		return [takeoff]

	var target: Unit = UnitQuery.nearest_hostile(unit.get_tree(), unit)
	if not target:
		return []

	var plans: Array[AiPlan] = []

	# Coming back down rather than draining FP for no reason (see this
	# file's own header on the mirror problem this was leaving unsolved:
	# nothing ever told a flyer to land before FpDrainBehavior forced it).
	#
	# PROPOSED, not returned. An earlier version returned the landing
	# outright whenever nothing could reach the unit at its current
	# altitude, which is a behavior deciding rather than proposing — and
	# it was wrong in a way testing caught immediately: an Avian hovering
	# two meters above a melee brute is genuinely unreachable up there,
	# so the guard fired, and it landed straight into the brute's reach.
	# Whether descending is a good idea depends on what's waiting at the
	# BOTTOM, which is precisely what AiScorer._apply_positional_value
	# prices (see AiScorer._plan_end_position, which raycasts for the
	# real landing spot). Offering it as one candidate among several lets
	# that arithmetic answer, instead of this branch pre-empting it.
	var land_ability: Ability = FlightAiUtil.find_land_ability(unit)
	if land_ability and unit.maximum_fp > 0 and not _should_stay_airborne(unit):
		var land_plan := AiPlan.new(land_ability, unit)
		land_plan.score = takeoff_score_bonus
		land_plan.reason = "land"
		plans.append(land_plan)

	var ability: Ability = unit.default_ability()
	if not ability:
		return plans

	var plan := AiPlan.new(ability, target)
	# IN RANGE WINS. If this unit can already shoot from where it floats,
	# it shoots — it does not spend the turn perfecting its altitude
	# first. The old condition compared against the standoff GOAL rather
	# than asking whether the attack was possible, and the three effects
	# compounded into a unit that never attacked at all:
	#
	#   - standoff_goal backs a ranged attacker off to its MAXIMUM range,
	#     so for an Avian already close the goal sits behind it — the
	#     "climb" was also a retreat.
	#   - Climbing costs FlightRules.ascend_cost_multiplier (2x) per
	#     meter, so reaching preferred_altitude from a fresh takeoff cost
	#     ~22 movement against a budget of 5. It could never arrive.
	#   - CombatAI re-asks for a plan after every completed move (see
	#     combat_ai._on_movement_finished), so it picked this same
	#     unfinishable climb again and again until the move budget ran
	#     out, and the turn ended with no attack. Every turn. It read as
	#     a bird endlessly fleeing a party it was never in danger from.
	#
	# Position serves attacking, not the reverse — the same priority
	# Solasta's own AI describes for its melee units, which pick spots
	# they can ENGAGE from rather than spots that are merely good.
	if ability.is_in_range(unit, target):
		# Nudge the held altitude anyway, so the next move this unit
		# genuinely needs to make carries it toward preferred_altitude
		# (see AiPlan.flight_altitude's own header: has_destination false
		# means this attacks immediately, same as any other candidate).
		plan.flight_altitude = preferred_altitude
	else:
		var goal_xz: Vector3 = AiScorer.standoff_goal(unit, target, ability)
		plan.with_destination(Vector3(goal_xz.x, preferred_altitude, goal_xz.z), preferred_altitude)

	# Only the authored bias is set here. The reason this climb is worth
	# anything — that holding preferred_altitude is safer than sitting
	# where the standoff math would otherwise leave the unit — is priced
	# by AiScorer._apply_positional_value from the destination set above,
	# for every candidate, rather than being re-derived in each behavior
	# that happens to care. This branch used to compute that delta
	# itself, in a copy of arithmetic MaintainAltitude repeated three
	# times and FleeBehavior twice; the copies competed against each
	# other on an unstated scale, which is what let a wounded flyer
	# ground-flee (see AiScorer.sustained_incoming_threat's own header).
	plan.score = reposition_score_bonus
	if plan.has_destination:
		plan.reason = "climb to %.1fm" % preferred_altitude
	else:
		plan.reason = "hold %.1fm" % preferred_altitude
	plans.append(plan)
	return plans


## Whether some OTHER behavior on this unit has a standing reason to stay
## off the ground, which the voluntary landing above must not fight
## against. Two cases, both discovered the same way — by the landing
## branch undoing another behavior's work on the very next turn:
##
##   FleeBehavior below its hp_threshold — its takeoff climbs
##   specifically to escape incoming threat, and the instant that
##   succeeds the threat reading drops to ~0, which is precisely this
##   behavior's own cue to come straight back down. A unit fleeing for
##   its life should stay up until it recovers, not because anything in
##   the air changed but because landing defeats the point of fleeing.
##
##   PreferFlightBehavior — a species authored to prefer being airborne
##   at all shouldn't spend its turns bobbing down to save FP, which is
##   the only thing the landing branch is for.
##
## Deliberately a read of sibling behaviors rather than a shared flag on
## Unit: it's a question about this unit's AUTHORING, answerable from the
## behavior list itself, and adding runtime state for it would mean
## keeping that state in sync with a resource that already says the same
## thing.
func _should_stay_airborne(unit: Unit) -> bool:
	for behavior in unit.ai_behaviors:
		if behavior is PreferFlightBehavior:
			return true
		if behavior is FleeBehavior:
			if unit.maximum_hp <= 0:
				continue
			var fraction: float = float(unit.current_hp) / float(unit.maximum_hp)
			if fraction <= behavior.hp_threshold:
				return true
	return false
