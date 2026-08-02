class_name RemoveOnDamageBehavior
extends StatusBehavior
## Removes the WHOLE status (every behavior on it, not just this one)
## the instant its owner takes any damage — used for Sleep, where any
## hit wakes you up. Combine with IncapacitateBehavior on the same
## StatusEffect to get an actual Sleep status: neither piece alone IS
## Sleep (Incapacitate alone would be permanent until it just expires;
## this alone wouldn't stop the unit from acting), but together they are.

func on_damage_taken(unit: Unit, _amount: int, active: ActiveStatus) -> void:
	unit.remove_status(active.effect)


func describe() -> String:
	return "Ends on taking damage"
