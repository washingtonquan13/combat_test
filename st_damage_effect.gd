class_name StDamageEffect
extends AbilityEffect
## GURPS ST-based damage — the dice-progression formula itself lives on
## UnitCombat.roll_damage (this unit's own ST-derived capability, shared
## with GearDamageEffect's weapon bonus and stats_column.gd's character-
## sheet display); this effect just supplies this ability's own bonus.

@export var damage_type: UnitCombat.DamageType = UnitCombat.DamageType.SWING
## Extra flat bonus added ON TOP of the ST-derived result (e.g. a
## weapon's own damage bonus) — kept separate from the bonus the ST
## formula computes internally, so a weapon modifier never gets silently
## absorbed into (or confused with) the ST math's own +1/+2/-1 steps.
@export var bonus: int = 0


func apply(attacker: Unit, target, _ability: Ability) -> Dictionary:
	if not target is Unit:
		return {}

	var raw_damage: int = attacker.roll_damage(damage_type, bonus)
	var applied: int = max(raw_damage - target.get_stat("DR"), 0)
	target.take_damage(applied)

	return {"raw_damage": raw_damage, "damage": applied}


func describe() -> String:
	var label := "Swing" if damage_type == UnitCombat.DamageType.SWING else "Thrust"
	return "%s damage (ST-based)" % label
