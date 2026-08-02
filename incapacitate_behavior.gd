class_name IncapacitateBehavior
extends StatusBehavior
## Prevents the unit from acting on its own turn at all — used for
## Sleep, Stun, Paralysis, etc. See StatusManager.prevents_turn(), which
## Unit.move_to() and Unit.use_ability() both check directly before
## doing anything, not just as an advisory flag some caller has to
## remember to check.
##
## Doesn't by itself do anything about WHY the unit stops being
## incapacitated (that's the status's normal duration expiring, or
## another behavior on the same StatusEffect like
## RemoveOnDamageBehavior) — this piece only ever says "can't act while
## active."

func prevents_turn() -> bool:
	return true


func describe() -> String:
	return "Cannot act"
