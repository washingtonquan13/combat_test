class_name HealEffect
extends AbilityEffect
## Restores dice-rolled HP, clamped at target's maximum_hp — the
## positive-direction counterpart to DamageEffect, kept as a separate
## sibling class rather than DamageEffect with a "heal" flag, same
## sibling-class-per-shape reasoning as StDamageEffect existing alongside
## DamageEffect rather than one class trying to cover both directions.

@export var dice_count: int = 2
@export var dice_sides: int = 6
@export var dice_bonus: int = 0


func apply(attacker: Unit, target, _ability: Ability, _is_critical: bool) -> Dictionary:
	if not target is Unit:
		return {}

	var raw_heal: int = roll_heal()
	var applied: int = target.heal(raw_heal)

	if applied > 0:
		SystemLog.print("%s heals %s for %s HP." % [LogFormat.unit_name(attacker), LogFormat.unit_name(target), LogFormat.heal(applied)])

	return {"raw_heal": raw_heal, "healed": applied}


func roll_heal() -> int:
	var total: int = 0
	for _i in dice_count:
		total += randi_range(1, dice_sides)
	return total + dice_bonus


func describe() -> String:
	return "Heals %dd%d+%d" % [dice_count, dice_sides, dice_bonus]


func expected_heal(_attacker: Unit) -> float:
	return float(dice_count) * (float(dice_sides) + 1.0) / 2.0 + float(dice_bonus)
