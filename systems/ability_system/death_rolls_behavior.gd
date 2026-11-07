class_name DeathRollsBehavior
extends StatusBehavior
## Downed's two tracks, after BG3's death saves. Each of the owner's
## turns rolls HT minus the depth penalty (Unit.roll_while_downed): a
## success marks one toward stable, a failure one toward death, and a
## critical either way marks two. Three toward stable and the unit is
## stable — still Downed, but rolling no more. Three toward death and it
## dies.
##
## Every hit on a Downed unit marks a failure, two for a critical hit. A
## hit on a stable unit makes it unstable again: both tracks start over,
## from that failure.
##
## Downed has no timer of its own — these tracks replace it, so the
## status's countdown is stopped from the moment it goes on.

const TO_END: int = 3


func on_apply(_unit: Unit, active: ActiveStatus) -> void:
	active.stopped = true
	_reset(active)


func on_turn_start(unit: Unit, active: ActiveStatus) -> void:
	if is_stable(active) or not unit.is_alive():
		return
	var roll: Dictionary = unit.roll_while_downed()
	var marks: int = 2 if roll["critical_success"] or roll["critical_failure"] else 1
	_mark(unit, active, "stable" if roll["success"] else "death", marks)


func on_damage_taken(unit: Unit, _amount: int, active: ActiveStatus, critical: bool = false) -> void:
	if not unit.is_alive():
		return
	if is_stable(active):
		_reset(active)
		SystemLog.print("%s was stable — the hit puts them back in danger." % LogFormat.unit_name(unit))
	_mark(unit, active, "death", 2 if critical else 1)


static func is_stable(active: ActiveStatus) -> bool:
	return active.tally.get("stable", 0) >= TO_END


## Fight's end: whoever is still down is stable where they lie.
static func make_stable(active: ActiveStatus) -> void:
	active.tally["stable"] = TO_END


func _reset(active: ActiveStatus) -> void:
	active.tally = {"stable": 0, "death": 0}


func _mark(unit: Unit, active: ActiveStatus, track: String, marks: int) -> void:
	active.tally[track] = mini(active.tally.get(track, 0) + marks, TO_END)
	unit.downed_tally_changed.emit(unit)
	SystemLog.print("%s — stable %d/%d, death %d/%d." % [LogFormat.unit_name(unit),
		active.tally["stable"], TO_END, active.tally["death"], TO_END])
	if active.tally["death"] >= TO_END:
		SystemLog.print("%s was not picked up in time." % LogFormat.unit_name(unit))
		unit.die()
	elif is_stable(active):
		SystemLog.print("%s is [b]stable[/b], but still down." % LogFormat.unit_name(unit))


func describe() -> String:
	return "Rolls HT each turn: three successes and stable, three failures and dead; every hit is a failure"
