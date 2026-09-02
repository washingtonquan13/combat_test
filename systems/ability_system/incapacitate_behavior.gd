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
##
## DOES force a flying unit down the instant it applies (on_apply, not
## prevents_turn — this needs to happen once, immediately, not be
## re-derived every turn-start check) — an incapacitated unit can't cast
## Land either (prevents_turn already blocks that), so without this a
## Sleeping/Stunned flyer would just hover, completely unreachable by
## melee, for the rest of the status's duration. Reused by every status
## built from this piece (Sleep, Stun, Paralysis, ...) for free, same as
## every other IncapacitateBehavior rule.

func on_apply(unit: Unit, _active: ActiveStatus) -> void:
	unit.ground_if_flying()


func prevents_turn() -> bool:
	return true


func describe() -> String:
	return "Cannot act"
