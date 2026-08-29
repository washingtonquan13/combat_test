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
## doesn't bother. Scored by how much incoming threat (see AiScorer.
## incoming_threat) climbing to preferred_altitude would avoid — a
## melee-only battlefield makes this decisive, an all-ranged one
## correctly leaves the unit grounded.
##
## Airborne: proposes landing instead of attacking once nothing can
## reach this unit anymore (mirrors the takeoff decision — no reason left
## to keep paying flight's FP upkeep), otherwise this unit's normal
## attack against the nearest hostile, insisting on preferred_altitude
## rather than whatever altitude the standoff-goal math would otherwise
## leave it at — see AiScorer._resolve_reach's flight_altitude override
## for how a temporarily-adopted altitude gets planned against without
## touching the unit's real state until the plan is actually chosen.

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
		var current_threat: float = AiScorer.incoming_threat(unit, unit.global_position)
		var airborne_position: Vector3 = Vector3(unit.global_position.x, preferred_altitude, unit.global_position.z)
		var airborne_threat: float = AiScorer.incoming_threat(unit, airborne_position)
		var takeoff := AiPlan.new(flight_ability, unit)
		takeoff.score = takeoff_score_bonus + (current_threat - airborne_threat)
		return [takeoff]

	var target: Unit = UnitQuery.nearest_hostile(unit.get_tree(), unit)
	if not target:
		return []

	# Nothing left that can reach this unit up here and FP is finite —
	# come back down rather than draining it for no reason (see this
	# file's own header on the mirror problem this was leaving unsolved:
	# nothing ever told a flyer to land before FpDrainBehavior forced it).
	var land_ability: Ability = FlightAiUtil.find_land_ability(unit)
	if land_ability and unit.maximum_fp > 0:
		var threat_here: float = AiScorer.incoming_threat(unit, unit.global_position)
		if threat_here <= 0.01:
			var land_plan := AiPlan.new(land_ability, unit)
			land_plan.score = takeoff_score_bonus
			return [land_plan]

	var ability: Ability = unit.default_ability()
	if not ability:
		return []

	var plan := AiPlan.new(ability, target)
	var goal_xz: Vector3 = AiScorer.standoff_goal(unit, target, ability)
	var goal: Vector3 = Vector3(goal_xz.x, preferred_altitude, goal_xz.z)
	if unit.global_position.distance_to(goal) > unit.arrival_tolerance:
		plan.with_destination(goal, preferred_altitude)
	else:
		# Already close enough to attack from here — just nudge the
		# unit's held altitude toward preferred_altitude for NEXT time
		# without spending a move this turn (see AiPlan.flight_altitude's
		# own header: has_destination false means this attacks
		# immediately if in range, same as any other candidate).
		plan.flight_altitude = preferred_altitude

	# Without a threat-based bias, this candidate scores IDENTICALLY to
	# the plain baseline-enumerated attack (same ability/target/expected
	# damage — see AiScorer._enumerate_baseline_candidates), and
	# AiScorer.best_plan only replaces its running best on a strict `>`,
	# so a tie always loses to whichever candidate was enumerated first.
	# That silently discarded every climb: a unit could take off (see
	# this file's grounded branch) and then never actually reach
	# preferred_altitude, hovering wherever the takeoff ability happened
	# to leave it. Scoring the same way takeoff does — by how much
	# incoming threat holding preferred_altitude avoids versus the
	# current position — gives an actual reason to climb instead of
	# relying on a tie to break the right way.
	var current_threat: float = AiScorer.incoming_threat(unit, unit.global_position)
	var preferred_threat: float = AiScorer.incoming_threat(unit, Vector3(goal_xz.x, preferred_altitude, goal_xz.z))
	plan.score = reposition_score_bonus + (current_threat - preferred_threat)
	return [plan]
