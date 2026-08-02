class_name StDamageEffect
extends AbilityEffect
## GURPS ST-based damage, computed from a formula rather than looking up
## the official table — approximates the real (N+1)d-1/+0/+1/+2
## progression ST 10-22 is built on (1d, 1d+1, 1d+2, 2d-1, 2d, ...):
##
##   swing dice  = ((ST - 10) + 4) / 4
##   thrust dice = ((ST - 10) + 4) / 8
##
## That division produces a fractional die count; the fractional part
## becomes an adjustment on the floored whole-die count:
##   fraction == 0            -> no adjustment
##   fraction <= 0.25          -> +1 flat
##   0.25 < fraction <= 0.5     -> +2 flat
##   0.5  < fraction <= 0.75     -> +1 extra die, with a flat -1 ("1d-1")
##   fraction >  0.75             -> +1 extra die, no flat modifier
##                                   ("1d+0") — rolls over to the next
##                                   full die, continuing the same
##                                   -1/+0/+1/+2 cycle.

enum DamageType { SWING, THRUST }

@export var damage_type: DamageType = DamageType.SWING
## Extra flat bonus added ON TOP of the ST-derived result (e.g. a
## weapon's own damage bonus) — kept separate from the bonus the ST
## formula computes internally, so a weapon modifier never gets silently
## absorbed into (or confused with) the ST math's own +1/+2/-1 steps.
@export var bonus: int = 0


func apply(attacker: Unit, target, _ability: Ability) -> Dictionary:
	if not target is Unit:
		return {}

	var raw_damage: int = roll_damage(attacker.strength)
	var applied: int = max(raw_damage - target.damage_reduction, 0)
	target.take_damage(applied)

	return {"raw_damage": raw_damage, "damage": applied}


func roll_damage(strength: int) -> int:
	var divisor: int = 4 if damage_type == DamageType.SWING else 8
	var raw: float = float((strength - 10) + 4) / divisor

	var dice_count: int = int(floor(raw))
	var fraction: float = raw - dice_count
	var flat_bonus: int = 0

	if fraction > 0.75:
		dice_count += 1
	elif fraction > 0.5:
		dice_count += 1
		flat_bonus = -1
	elif fraction > 0.25:
		flat_bonus = 2
	elif fraction > 0.0:
		flat_bonus = 1

	dice_count = max(dice_count, 0)

	var total: int = 0
	for _i in dice_count:
		total += randi_range(1, 6)  # GURPS damage dice are always d6

	return total + flat_bonus + bonus


func describe() -> String:
	var label := "Swing" if damage_type == DamageType.SWING else "Thrust"
	return "%s damage (ST-based)" % label
