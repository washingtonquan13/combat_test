class_name AreaHealEffect
extends AbilityEffect
## AoE counterpart to HealEffect, same pairing AreaDamageEffect has with
## DamageEffect — target is a Vector3 (a heal-burst center), radius read
## from ability.targeting.radius (AreaTargeting), same single source of
## truth every other area effect in this project already uses.
##
## Defaults flipped from AreaDamageEffect's (affects_allies=true,
## affects_hostiles=false) — a heal indiscriminately hitting enemies too
## would need a very deliberate reason, unlike an explosion.
##
## Same shared scan as AreaDamageEffect — see that file's header — via
## AbilityTargeting.units_caught.

@export var dice_count: int = 2
@export var dice_sides: int = 6
@export var dice_bonus: int = 0
@export var affects_hostiles: bool = false
@export var affects_allies: bool = true


func apply(attacker: Unit, target, ability: Ability, is_critical: bool) -> Dictionary:
	return commit(attacker, target, ability, is_critical, resolve(attacker, target, ability, is_critical))


## Who the area catches and what each rolls, decided when it is cast.
func resolve(attacker: Unit, target, ability: Ability, _is_critical: bool) -> Dictionary:
	if not target is Vector3:
		return {}

	if not ability.targeting:
		return {}

	var affected: Array = []

	for unit in ability.targeting.units_caught(attacker, target, affects_hostiles, affects_allies):
		affected.append({"unit": unit, "raw_heal": roll_heal()})
	return {"affected": affected}


## Anyone freed before it lands is skipped.
func commit(attacker: Unit, _target, _ability: Ability, _is_critical: bool, plan: Dictionary) -> Dictionary:
	if plan.is_empty():
		return {}

	var affected: Array = []
	var total_healed: int = 0
	for entry in plan.affected:
		if not is_instance_valid(entry.unit):
			continue
		var applied: int = entry.unit.heal(entry.raw_heal)
		affected.append({"unit": entry.unit, "raw_heal": entry.raw_heal, "healed": applied})
		total_healed += applied

	if total_healed > 0:
		SystemLog.print("%s's area heal restores %s HP." % [LogFormat.unit_name(attacker), LogFormat.heal(total_healed)])

	return {"affected": affected, "healed": total_healed}


func roll_heal() -> int:
	var total: int = 0
	for _i in dice_count:
		total += randi_range(1, dice_sides)
	return total + dice_bonus


func describe() -> String:
	return "%dd%d+%d healing (area)" % [dice_count, dice_sides, dice_bonus]
