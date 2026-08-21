class_name UseAbilityOnNearestHostileBehavior
extends AiBehavior
## Attacks the nearest hostile with a specific ability — a caster
## authors this with ability=explosive_fireball.tres, an archer with
## ability=basic_attack_ranged.tres, ... CombatAI's existing standoff
## logic reads whichever ability gets chosen here, so an AI unit
## authored with a ranged ability automatically stands off at range
## instead of melee-closing — no separate positioning behavior needed.
## Leaving ability unset falls back to unit.default_ability()
## (abilities[0]), making this the literal data-driven equivalent of
## the old hardcoded baseline — the "melee brute" archetype needs no
## ability assigned at all.
@export var ability: Ability


func resolve(unit: Unit) -> Dictionary:
	var target: Unit = UnitQuery.nearest_hostile(unit.get_tree(), unit)
	if not target:
		return {}
	var chosen: Ability = ability if ability else unit.default_ability()
	if not chosen:
		return {}
	return {"ability": chosen, "target": target}
