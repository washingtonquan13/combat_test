class_name ProneBehavior
extends StatusBehavior
## Classic tactical-RPG "prone" rule: melee attacks against a prone
## target are EASIER to land (bonus), ranged attacks are HARDER
## (penalty) — a prone target is a bigger melee target but a smaller,
## harder-to-hit ranged one.
##
## Only affects attacks made AGAINST the prone unit, not the prone
## unit's own offense — that's a deliberate scope choice, not an
## oversight; add a second behavior if you also want prone to worsen the
## unit's own attacks.
##
## Doesn't affect movement (e.g. "stand up" costing part of your move
## budget) — that would need a hook into Unit.move_to()'s budget math
## that doesn't exist yet. Worth knowing if you're expecting that half
## of the classic rule too; this behavior only covers the to-hit part.

@export var melee_bonus: int = 4
@export var ranged_penalty: int = -4


func modify_incoming_attack_to_hit(_defender: Unit, _attacker: Unit, ability: Ability) -> int:
	if ability.targeting is MeleeEnemyTargeting:
		return melee_bonus
	elif ability.targeting is RangedEnemyTargeting:
		return ranged_penalty
	return 0


func describe() -> String:
	return "Prone: +%d to melee attacks against, %d to ranged attacks against" % [melee_bonus, ranged_penalty]
