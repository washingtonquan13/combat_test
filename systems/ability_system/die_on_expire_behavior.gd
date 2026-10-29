class_name DieOnExpireBehavior
extends StatusBehavior
## Kills the unit when this status runs out — Downed's timer. Only an
## expiry kills: being removed with turns still left (picked up,
## stabilized) is the way out of it, so on_remove checks what was left
## rather than firing on every removal the way DespawnOnExpireBehavior
## does.

func on_remove(unit: Unit, active: ActiveStatus, _voluntary: bool = false) -> void:
	if active.turns_remaining > 0 or not unit.is_alive():
		return
	SystemLog.print("%s was not picked up in time." % LogFormat.unit_name(unit))
	unit.die()


func describe() -> String:
	return "Dies when this runs out"
