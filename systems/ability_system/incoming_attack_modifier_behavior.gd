class_name IncomingAttackModifierBehavior
extends StatusBehavior
## Flat, unconditional modifier to attacks made AGAINST the unit this
## status is attached to — the generic counterpart to ProneBehavior,
## which does the same thing but splits melee vs ranged. Dodge/Defensive
## Stance style buffs (harder to hit, full stop, not "harder to hit by
## melee only") are just this with a negative bonus (roll-under: a lower
## target number is HARDER for the attacker), positive for something that
## makes the unit deliberately easier to hit instead.

@export var bonus: int = 0


func modify_incoming_attack_to_hit(_defender: Unit, _attacker: Unit, _ability: Ability) -> int:
	return bonus


func describe() -> String:
	return "%+d to incoming attacks" % bonus
