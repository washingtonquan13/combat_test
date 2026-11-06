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
## GURPS damage type (B379): what DR lets through is multiplied by its
## wounding multiplier.
@export var wound_type: DamageResolver.WoundType = DamageResolver.WoundType.CRUSHING
## GURPS armor divisor (B378): the target's DR is divided by it. 1 is
## none; (2), (3), (5), (10) penetrate; (0.5), (0.2), (0.1) are stopped
## more easily than usual.
@export var armor_divisor: float = 1.0


func apply(attacker: Unit, target, ability: Ability, is_critical: bool) -> Dictionary:
	return commit(attacker, target, ability, is_critical, resolve(attacker, target, ability, is_critical))


func resolve(attacker: Unit, target, ability: Ability, is_critical: bool) -> Dictionary:
	if not target is Unit:
		return {}

	# Critical hit: ignores DR entirely and deals guaranteed max damage
	# (see UnitCombat.max_damage) — no second roll, staying consistent
	# with this project's fast/not-roll-heavy combat goal.
	var raw_damage: int = attacker.max_damage(damage_type, bonus) if is_critical \
		else attacker.roll_damage(damage_type, bonus)
	var applied: int = DamageResolver.injury(raw_damage, target, wound_type, armor_divisor, is_critical, false, attacker.hit_location_for(ability))
	return {"raw_damage": raw_damage, "damage": applied}


func commit(_attacker: Unit, target, _ability: Ability, is_critical: bool, plan: Dictionary) -> Dictionary:
	if plan.is_empty():
		return {}
	target.take_damage(plan.damage, is_critical)
	return plan


func describe() -> String:
	var label := "Swing" if damage_type == UnitCombat.DamageType.SWING else "Thrust"
	return "%s %s damage (ST-based)" % [label, DamageResolver.describe(wound_type, armor_divisor)]


func expected_damage(attacker: Unit, target: Unit = null, location: HitLocation = null) -> float:
	return attacker.expected_damage(damage_type, bonus, target, wound_type, armor_divisor, location)


func located_wound_type(_attacker: Unit) -> int:
	return wound_type
