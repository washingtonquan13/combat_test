class_name OutgoingAttackModifierBehavior
extends StatusBehavior
## Flat modifier to the AFFLICTED unit's own OUTGOING attacks — the
## Bless-style counterpart to IncomingAttackModifierBehavior, using the
## hook added specifically for this (StatusBehavior.
## modify_outgoing_attack_to_hit — see that method's doc comment for why
## it didn't already exist: every other status hook so far only ever
## needed to reason about the unit as the DEFENDER).

@export var bonus: int = 0


func modify_outgoing_attack_to_hit(_attacker: Unit, _target, _ability: Ability) -> int:
	return bonus


func describe() -> String:
	return "%+d to outgoing attacks" % bonus
