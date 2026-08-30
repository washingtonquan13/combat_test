class_name SupportAllyBehavior
extends AiBehavior
## The support role: keep allies alive and buffed. Generalizes
## HealWoundedAllyBehavior, which only ever proposed a heal against an
## HP threshold, to the three things this project's support content
## actually does — heal (heal.tres), cure a status (cure.tres), and buff
## (bless.tres, shield.tres).
##
## Each authored ability becomes a candidate against each eligible ally,
## and AiScorer decides. That matters most for the choice this behavior
## exists to get right: a full-HP ally with a debuff on it should be
## cured, not healed, and an ally at half HP with no debuff should be
## healed, not blessed. Enumerating all of them and letting the shared
## heal/damage arithmetic pick beats any ordering this file could hardcode
## — and, per AiBehavior's contract, is the only thing it's allowed to do.
##
## Eligibility is per ability kind rather than one shared threshold:
##   heal  — ally is missing HP (AiScorer clamps heal value to missing HP,
##           so an ally at full HP scores 0 and loses on its own).
##   cure  — ally actually carries a status this ability removes.
##   buff  — ally doesn't already have the status, so a caster doesn't
##           spend every turn re-applying Bless to the same target.
##
## Deliberately does NOT include self-preservation or positioning. A
## support unit that should also stay out of melee gets FleeBehavior and
## HoldRangeBehavior alongside this one, composed by its archetype —
## bundling them here is what made MaintainAltitudeBehavior a three-job
## behavior and three separate bugs.

@export var heal_abilities: Array[Ability] = []
@export var cure_abilities: Array[Ability] = []
@export var buff_abilities: Array[Ability] = []
@export var bias: float = 0.0


func _propose_candidates(unit: Unit) -> Array[AiPlan]:
	var plans: Array[AiPlan] = []
	var allies: Array[Unit] = UnitQuery.living_allies(unit.get_tree(), unit)
	# A support unit can be its own patient — being the last one standing
	# and unable to heal itself is a worse look than the occasional
	# self-buff.
	allies.append(unit)

	for ally in allies:
		for ability in heal_abilities:
			if not ability or ally.maximum_hp <= 0 or ally.current_hp >= ally.maximum_hp:
				continue
			var heal: AiPlan = attack_plan(unit, ally, ability, bias)
			heal.reason = "heal %s" % ally.get_display_name()
			plans.append(heal)

		for ability in cure_abilities:
			if not ability or not _would_remove_a_status(ability, ally):
				continue
			var cure: AiPlan = attack_plan(unit, ally, ability, bias)
			cure.reason = "cure %s" % ally.get_display_name()
			plans.append(cure)

		for ability in buff_abilities:
			if not ability or _already_has_applied_status(ability, ally):
				continue
			var buff: AiPlan = attack_plan(unit, ally, ability, bias)
			buff.reason = "buff %s" % ally.get_display_name()
			plans.append(buff)

	return plans


## Whether ability would actually strip something off ally — otherwise
## curing a perfectly healthy ally is a wasted turn that AiScorer has no
## way to score against, since removing a status has no HP value.
func _would_remove_a_status(ability: Ability, ally: Unit) -> bool:
	for effect in ability.effects:
		if effect is RemoveStatusEffect and effect.status and ally.has_status(effect.status):
			return true
	return false


## Whether ally already carries everything this buff would apply — the
## guard that stops a caster re-Blessing the same target every turn.
func _already_has_applied_status(ability: Ability, ally: Unit) -> bool:
	var applies_anything: bool = false
	for effect in ability.effects:
		if effect is ApplyStatusEffect and effect.status:
			applies_anything = true
			if not ally.has_status(effect.status):
				return false
	return applies_anything
