class_name CatfallBehavior
extends StatusBehavior
## Lands like a cat: part of every fall doesn't count, and a DX roll halves
## the damage from what's left.

## 5 yards.
@export var ignored_fall: float = 4.5


func ignored_fall_distance() -> float:
	return ignored_fall


func soften_fall(unit: Unit, damage: int) -> int:
	var roll: Dictionary = unit.roll_vs(floori(unit.get_stat(StatIds.DX)))
	if not roll["success"]:
		return damage
	SystemLog.print("%s lands softly: half damage." % LogFormat.unit_name(unit))
	return ceili(damage / 2.0)


func describe() -> String:
	return "Ignores %s m of a fall; DX roll halves the damage" % String.num(ignored_fall)
