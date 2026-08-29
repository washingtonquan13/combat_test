class_name HealWoundedAllyBehavior
extends AiBehavior
## Proposes healing every living ally below hp_threshold — NOT just the
## single most-wounded one anymore (see this class's old resolve()-era
## header, and AiBehavior's own header for the flaw that came from
## first-match-wins picking whichever ally this loop found first
## regardless of how urgently anyone else needed it). Each wounded ally
## becomes its own candidate; AiScorer's shared heal-value arithmetic
## (expected heal clamped to missing HP — see AiScorer._score_plan)
## naturally favors whichever benefits most, and now competes honestly
## against every attack candidate too — including, correctly, losing to
## a lethal hit on a nearly-dead enemy instead of always winning by
## going first.

@export var heal_ability: Ability
@export_range(0.0, 1.0) var hp_threshold: float = 0.5
## Added on top of the shared scorer's own heal-value arithmetic (see
## AiScorer._score_plan) — 0.0 (the default) means healing competes
## purely on how much HP it would actually restore, same footing as
## every other candidate.
@export var score_bonus: float = 0.0


func propose(unit: Unit) -> Array[AiPlan]:
	if not heal_ability:
		return []

	var plans: Array[AiPlan] = []
	for ally in UnitQuery.living_allies(unit.get_tree(), unit):
		if ally.maximum_hp <= 0:
			continue
		var fraction: float = float(ally.current_hp) / float(ally.maximum_hp)
		if fraction >= hp_threshold:
			continue
		var plan := AiPlan.new(heal_ability, ally)
		plan.score = score_bonus
		plans.append(plan)
	return plans
