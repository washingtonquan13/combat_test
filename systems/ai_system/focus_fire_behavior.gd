class_name FocusFireBehavior
extends AiBehavior
## Biases toward the target this unit's allies are already fighting, so a
## group concentrates fire instead of each member independently picking
## whoever happens to be nearest to itself. The classic brute/pack
## behavior, and the thing that makes four weak enemies dangerous rather
## than four separate nuisances.
##
## AiScorer already prefers targets it can KILL (see the kill-value term
## in _score_plan, which prices denying an enemy its remaining turns), so
## this is not "prefer weak targets" — that exists. What's missing is
## COORDINATION: two units that could each finish a different wounded foe
## have no reason to agree on which, and independently correct scoring
## produces a group that spreads damage evenly and kills nobody.
##
## "Already fighting" is approximated as "an ally is within its own reach
## of that target," rather than tracked as remembered intent. The
## approximation is deliberate — real intent would mean AI units
## publishing plans to each other and re-planning when one changes, and
## proximity captures the same thing for a melee line without any of that
## coordination state. It reads slightly differently for a pack of
## archers, who are all "in reach" of everything; that's acceptable,
## since for them the kill-value term is already doing the work.

## Bias applied per ally engaged with that target, capped below by
## AiBehavior.MAX_AUTHORED_BIAS. Small on purpose: this breaks ties
## between targets the scorer already rates similarly, it does not
## override a genuinely better opportunity elsewhere.
@export var bias_per_ally: float = 1.0


func _propose_candidates(unit: Unit) -> Array[AiPlan]:
	var ability: Ability = unit.default_ability()
	if not ability:
		return []

	var allies: Array[Unit] = UnitQuery.living_allies(unit.get_tree(), unit)
	if allies.is_empty():
		return []

	var plans: Array[AiPlan] = []
	for other in UnitQuery.living_units(unit.get_tree()):
		if not unit.is_hostile_to(other):
			continue

		var engaged: int = 0
		for ally in allies:
			var ally_ability: Ability = ally.default_ability()
			if not ally_ability or not ally_ability.targeting:
				continue
			if ally.edge_distance_to(other) <= ally_ability.targeting.approach_range():
				engaged += 1
		if engaged <= 0:
			continue

		var bias: float = minf(bias_per_ally * float(engaged), MAX_AUTHORED_BIAS)
		var plan: AiPlan = attack_plan(unit, other, ability, bias)
		plan.reason = "focus fire (%d ally engaged)" % engaged
		plans.append(plan)

	return plans
