class_name DamageEffect
extends AbilityEffect
## Deals dice-rolled damage, minus target's DR. To-hit is
## NOT rolled here — that's Ability/Unit.use_ability()'s job, resolved
## once before ANY of an ability's effects run (see use_ability's doc
## comment for why: a missed attack should skip every effect, not just
## damage specifically — rolling to-hit per-effect would let a multi-
## effect ability apply its OTHER effects even on a miss, which is wrong).

@export var dice_count: int = 1
@export var dice_sides: int = 6
@export var dice_bonus: int = 0


func apply(_attacker: Unit, target, _ability: Ability, _is_critical: bool) -> Dictionary:
	if not target is Unit:
		return {}

	var raw_damage: int = roll_damage()
	var applied: int = DamageResolver.injury(raw_damage, target)
	target.take_damage(applied)

	return {"raw_damage": raw_damage, "damage": applied}


func roll_damage() -> int:
	var total: int = 0
	for _i in dice_count:
		total += randi_range(1, dice_sides)
	return total + dice_bonus


func describe() -> String:
	return "%dd%d+%d damage" % [dice_count, dice_sides, dice_bonus]


func expected_damage(_attacker: Unit, target: Unit = null) -> float:
	return DamageResolver.expected_injury(dice_count, dice_sides, dice_bonus, target)
