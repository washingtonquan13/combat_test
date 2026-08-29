class_name UseAbilityOnNearestHostileBehavior
extends AiBehavior
## Proposes a specific ability against the nearest hostile — a caster
## authors this with ability=explosive_fireball.tres, an archer with
## ability=basic_attack_ranged.tres, ... The shared AiScorer already
## enumerates every attack ability a unit owns against every hostile (see
## that file's own baseline enumeration), so this behavior's only real
## job is authoring a PREFERENCE for one specific ability/target pairing
## beyond what that blanket search would arrive at on its own — see
## score_bonus below. Leaving ability unset falls back to
## unit.default_ability() (abilities[0]).

@export var ability: Ability
## Added on top of whatever the shared scorer's own expected-damage
## arithmetic already assigns this candidate (see AiScorer._score_plan)
## — 0.0 (the default) means this candidate competes purely on its own
## merits against every other candidate, baseline or authored. Raise
## this for a boss-type unit that should favor its signature move even
## when a plain damage comparison wouldn't otherwise pick it.
@export var score_bonus: float = 0.0


func propose(unit: Unit) -> Array[AiPlan]:
	var target: Unit = UnitQuery.nearest_hostile(unit.get_tree(), unit)
	if not target:
		return []
	var chosen: Ability = ability if ability else unit.default_ability()
	if not chosen:
		return []
	var plan := AiPlan.new(chosen, target)
	plan.score = score_bonus
	return [plan]
