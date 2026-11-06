class_name FinishDownedBehavior
extends AiBehavior
## How eager this unit is to finish off a Downed hostile, by personality —
## the cruel lean in, the kind leave it to the scorer.
##
## AiScorer already prices a hit on a Downed unit honestly (see its
## _downed_hit_value: progress toward the kill, worth the turns that kill
## denies), so a unit with no bias here still finishes the job when that
## is genuinely its best move, and still does when nothing else is left
## standing. This is only the personality on top: a Scary demon reaching
## past a standing fighter to put a fallen one away.
##
## Positive biases only. A negative one would be a "merciful" plan that
## loses to the identical unbiased baseline candidate and so changes
## nothing; mercy is a personality simply leaving this at 0.

## Bias per UnitDefinition.personality. Unlisted personalities (and units
## with no definition) use default_bias.
@export var bias_by_personality: Dictionary[StringName, float] = {}
@export var default_bias: float = 0.0


func bias_for(unit: Unit) -> float:
	var personality: StringName = unit.definition.personality if unit.definition else &""
	return minf(bias_by_personality.get(personality, default_bias), MAX_AUTHORED_BIAS)


func _propose_candidates(unit: Unit) -> Array[AiPlan]:
	var bias: float = bias_for(unit)
	if bias <= 0.0:
		return []
	var ability: Ability = unit.default_ability()
	if not ability:
		return []

	var plans: Array[AiPlan] = []
	for other in UnitQuery.living_units_near(unit):
		if not unit.is_hostile_to(other) or not other.is_downed():
			continue
		var plan: AiPlan = attack_plan(unit, other, ability, bias)
		plan.reason = "finish downed"
		plans.append(plan)
	return plans
