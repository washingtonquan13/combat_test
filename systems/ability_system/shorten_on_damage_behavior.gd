class_name ShortenOnDamageBehavior
extends StatusBehavior
## Every hit the owner takes takes one turn off this status — Downed's
## "being attacked while down brings death closer." Running out this way
## is the same as running out on a turn start: the status is removed with
## no turns left, so DieOnExpireBehavior on the same status still fires.

func on_damage_taken(unit: Unit, _amount: int, active: ActiveStatus) -> void:
	active.turns_remaining -= 1
	if active.turns_remaining <= 0:
		unit.remove_status(active.effect)


func describe() -> String:
	return "Each hit takes a turn off"
